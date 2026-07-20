//
//  ContentViewController.swift
//  md-preview
//

import Cocoa

/// Where the preview should land after the next document render — a link
/// fragment or a restored history scroll offset.
enum NavigationScrollTarget {
    case anchor(String)
    case position(CGFloat)
}

final class ContentViewController: NSViewController {

    private static let pageZoomDefaultsKey = "MarkdownPreview.pageZoom"

    private var webView: MarkdownWebView!
    private var webViewPageWidthConstraint: NSLayoutConstraint?
    private var webViewCenteredConstraints: [NSLayoutConstraint] = []
    private var webViewFullWidthConstraints: [NSLayoutConstraint] = []
    private var pendingFlashWork: DispatchWorkItem?
    private var pendingPreviewScrollAnchor: SourceScrollAnchor?
    private var shouldApplyPendingAnchorOnHeight = false
    private var pendingNavigationScrollTarget: NavigationScrollTarget?
    private var shouldApplyNavigationTargetOnHeight = false
    /// Early attempts run against the blanked page shown during a file
    /// switch, where the target can't resolve yet — retry on a short timer
    /// (height events accelerate it), giving up after ~2s.
    private var navigationTargetRetriesLeft = 0
    private static let navigationTargetMaxRetries = 25
    private static let navigationTargetRetryInterval: TimeInterval = 0.08

    // Heading top offsets in CSS pixels, indexed by heading id. Compared in
    // CSS units so page zoom doesn't invalidate them.
    private var headingOffsetsCSS: [CGFloat] = []
    private var lastActiveHeadingID: Int?
    private var pendingHeadingOffsetsRefresh: DispatchWorkItem?

    // Sidebar-click pin. Bounds events are ignored until `holdUntil`
    // (covers our own animation), then we measure scroll distance from
    // `anchor` (the click's target scroll position). Tiny moves —
    // rubber-band, small scrolls on near-fitting docs — stay below the
    // release threshold so the pin survives them. A doc that can't scroll
    // at all never even fires bounds events, so the pin sits forever.
    private var sticky: StickyPin?
    private struct StickyPin {
        let headingID: Int
        let holdUntil: DispatchTime
        let anchor: CGFloat
    }
    /// Covers `scrollDocument`'s 0.25s animation plus JS round-trip.
    private static let stickyHoldDuration: DispatchTimeInterval = .milliseconds(350)
    /// Viewport fraction the user must scroll past the pin's anchor to
    /// release it. ⅓ feels sticky enough for incidental moves but lets
    /// genuine page-scrolls take over.
    private static let stickyReleaseFraction: CGFloat = 1.0 / 3.0

    var activeHeadingDidChange: ((Int?) -> Void)?
    var taskCheckboxToggled: ((Int, Bool) -> Void)?
    var tableEditRequested: ((MarkdownTableEditRequest) -> Void)?
    var localMarkdownLinkActivated: ((URL) -> Void)?
    /// Fires once after a pending source scroll anchor (prepared via
    /// `prepareToRestoreSourceScrollAnchor`) has been applied to a fresh
    /// render. The edit-mode overlay uses it to hold its cross-fade until
    /// the preview underneath is positioned.
    var pendingAnchorRestored: (() -> Void)?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        webView = MarkdownWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.heightDidChange = { [weak self] _ in
            guard let self else { return }
            // Image load / font reflow shifted layout — re-measure offsets.
            self.scheduleHeadingOffsetsRefresh()
            self.applyPendingScrollAnchorIfNeeded()
            if self.shouldApplyNavigationTargetOnHeight,
               let target = self.pendingNavigationScrollTarget {
                self.shouldApplyNavigationTargetOnHeight = false
                self.attemptNavigationScrollTarget(target)
            }
        }
        webView.contentDidReplace = { [weak self] in
            // The fresh article is in the DOM; a same-height render never
            // fires heightDidChange, so this is the reliable signal.
            self?.applyPendingScrollAnchorIfNeeded()
        }
        webView.fragmentLinkActivated = { [weak self] fragment in
            self?.scrollToElement(id: fragment)
        }
        webView.localMarkdownLinkActivated = { [weak self] url in
            self?.localMarkdownLinkActivated?(url)
        }
        webView.taskCheckboxToggled = { [weak self] line, checked in
            self?.taskCheckboxToggled?(line, checked)
        }
        webView.tableEditRequested = { [weak self] request in
            self?.tableEditRequested?(request)
        }
        webView.zoomDidChange = { [weak self] zoom in
            self?.webViewPageWidthConstraint?.constant = MarkdownHTML.preferredPageWidth * zoom
        }
        webView.scrollDidChange = { [weak self] in
            self?.evaluateActiveHeading()
        }
        webView.enablePersistentZoom(defaultsKey: Self.pageZoomDefaultsKey)

        container.addSubview(webView)

        // Normal (centered) mode caps the web view at the page width and
        // centers it in AppKit rather than letting CSS auto-margins center
        // the column inside a full-width web view. A sidebar/inspector
        // reveal then only *moves* the web view — applied synchronously
        // with each animation frame — instead of resizing it, which forces
        // the web process to re-run layout asynchronously and made the
        // column jitter for the duration of the animation (#162). The
        // width constant tracks pageZoom (zoomDidChange above) so the
        // column keeps its 820 CSS-px measure at every zoom level.
        let pageWidth = webView.widthAnchor.constraint(
            equalToConstant: MarkdownHTML.preferredPageWidth * webView.pageZoom)
        // Stay below the split items' holding priorities (content 250,
        // sidebar 260) so window resizing breaks this page-width preference
        // before AppKit changes the user's chosen sidebar width.
        pageWidth.priority = .init(249)
        webViewPageWidthConstraint = pageWidth
        webViewCenteredConstraints = [
            webView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            webView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
            pageWidth
        ]
        webViewFullWidthConstraints = [
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ]

        // Keep the WKWebView viewport-sized and let WebKit own vertical
        // scrolling. Expanding it to the full document height creates an
        // enormous backing surface that loses Retina resolution on long docs.
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        applyContentWidthMode()
    }

    func display(markdown: String, assetBaseURL: URL? = nil) {
        if pendingPreviewScrollAnchor != nil {
            shouldApplyPendingAnchorOnHeight = true
        }
        if pendingNavigationScrollTarget != nil {
            shouldApplyNavigationTargetOnHeight = true
            // Height events don't re-fire when the new document lays out at
            // the same height — the timer guarantees an attempt.
            scheduleNavigationTargetAttempt()
        }
        resetScrollspy()
        webView.display(markdown: markdown, assetBaseURL: assetBaseURL)
        scheduleHeadingOffsetsRefresh()
    }

    func clearContent() {
        resetScrollspy()
        webView.clearContent()
    }

    /// Drops scrollspy state before a doc swap so the previous doc's
    /// heading doesn't briefly stay marked.
    private func resetScrollspy() {
        headingOffsetsCSS = []
        sticky = nil
        notifyActiveHeading(nil)
    }

    private func notifyActiveHeading(_ headingID: Int?) {
        guard headingID != lastActiveHeadingID else { return }
        lastActiveHeadingID = headingID
        activeHeadingDidChange?(headingID)
    }

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(query, forType: .string)
        pendingFlashWork?.cancel()
        webView.find(query, backwards: backwards, mode: mode) { [weak self] result in
            guard let self else {
                completion?(result)
                return
            }
            if let top = result.top, let bottom = result.bottom {
                let needsScroll = !self.isMatchVisible(top: top, bottom: bottom)
                if needsScroll {
                    self.scrollDocument(to: top)
                }
                let delay: TimeInterval = needsScroll ? 0.18 : 0
                let work = DispatchWorkItem { [weak self] in
                    self?.webView.flashCurrentMatch()
                }
                self.pendingFlashWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
            completion?(result)
        }
    }

    private func isMatchVisible(top: CGFloat, bottom: CGFloat) -> Bool {
        let metrics = webView.scrollMetrics
        let visibleTop = metrics.position
        let visibleBottom = metrics.position + metrics.viewportHeight
        return top >= visibleTop && bottom <= visibleBottom
    }

    func printDocument() {
        guard let window = view.window else { return }
        webView.printDocument(from: window)
    }

    func zoomIn() { webView.zoomIn() }
    func zoomOut() { webView.zoomOut() }
    func resetZoom() { webView.resetZoom() }
    var pageZoom: CGFloat { webView.pageZoom }

    /// Normalized top-of-viewport position used when handing the document to
    /// the editor, whose content height differs slightly from the preview.
    var scrollProgress: CGFloat {
        let metrics = webView.scrollMetrics
        let maxY = max(metrics.documentHeight - metrics.viewportHeight, 0)
        guard maxY > 0 else { return 0 }
        return min(max(metrics.position / maxY, 0), 1)
    }

    func sourceScrollAnchor(completion: @escaping (SourceScrollAnchor?) -> Void) {
        let visibleTop = webView.scrollMetrics.position
        webView.sourceAnchor(atDocumentY: visibleTop / webView.pageZoom, completion: completion)
    }

    func prepareToRestoreSourceScrollAnchor(_ anchor: SourceScrollAnchor?) {
        pendingPreviewScrollAnchor = anchor
    }

    func restoreSourceScrollAnchor(_ anchor: SourceScrollAnchor,
                                   completion: (() -> Void)? = nil) {
        webView.sourceOffset(forPosition: anchor.sourcePosition) { [weak self] sourceTop in
            guard let self, let sourceTop else {
                completion?()
                return
            }
            // topGap re-creates a viewport that sat inside the page padding
            // above the anchor's rendered top (document-top case).
            let target = max((sourceTop - anchor.topGap) * self.webView.pageZoom, 0)
            // A mode switch is a position hand-off, not a navigation: land
            // instantly. An animated scroll here reads as jitter when the
            // editor overlay fades away.
            self.scrollDocument(to: target, topMargin: 0, duration: 0)
            completion?()
        }
    }

    /// Applies the scroll anchor captured from the editor once the fresh
    /// article is in place, then reports it so the editor overlay can fade.
    private func applyPendingScrollAnchorIfNeeded() {
        guard shouldApplyPendingAnchorOnHeight,
              let anchor = pendingPreviewScrollAnchor else { return }
        shouldApplyPendingAnchorOnHeight = false
        pendingPreviewScrollAnchor = nil
        restoreSourceScrollAnchor(anchor) { [weak self] in
            guard let self else { return }
            self.pendingAnchorRestored?()
            self.pendingAnchorRestored = nil
        }
    }

    func reloadPreviewForSettingChange() {
        applyContentWidthMode()
        webView.reloadPreviewForSettingChange()
    }

    /// Swaps the web view between the AppKit-centered page column and a
    /// full-bleed layout. See the loadView comment for why centering lives
    /// at the constraint layer instead of CSS.
    private func applyContentWidthMode() {
        switch ContentWidthSetting.current {
        case .normal:
            NSLayoutConstraint.deactivate(webViewFullWidthConstraints)
            NSLayoutConstraint.activate(webViewCenteredConstraints)
        case .fullWidth:
            NSLayoutConstraint.deactivate(webViewCenteredConstraints)
            NSLayoutConstraint.activate(webViewFullWidthConstraints)
        }
    }

    func scrollToHeading(index: Int) {
        webView.headingOffset(index: index) { [weak self] offset in
            guard let self, let offset else { return }
            self.scrollDocument(to: offset)
        }
    }

    /// Pin a heading active immediately so even a no-op scroll (last
    /// heading on a short doc) gives feedback. The pin survives small
    /// scroll movements; only a viewport-fraction scroll away from where
    /// the click landed releases it.
    func markHeadingActiveFromClick(_ headingID: Int) {
        let anchor = expectedScrollPosition(forHeading: headingID)
            ?? webView.scrollMetrics.position
        sticky = StickyPin(headingID: headingID,
                           holdUntil: .now() + Self.stickyHoldDuration,
                           anchor: anchor)
        notifyActiveHeading(headingID)
    }

    /// Where `scrollDocument` would land for `headingID` — the same
    /// clamped target the click animation aims at. Used as the pin's
    /// distance reference.
    private func expectedScrollPosition(forHeading headingID: Int) -> CGFloat? {
        guard headingID >= 0,
              headingID < headingOffsetsCSS.count else { return nil }
        let metrics = webView.scrollMetrics
        let zoom = max(webView.pageZoom, 0.001)
        let topMargin: CGFloat = 12
        let y = headingOffsetsCSS[headingID] * zoom
        let maxY = max(metrics.documentHeight - metrics.viewportHeight, 0)
        return max(0, min(y - topMargin, maxY))
    }

    /// Scroll target applied once the next `display()` has rendered;
    /// `nil` drops a stale target.
    func prepareToScrollAfterNavigation(to target: NavigationScrollTarget?) {
        pendingNavigationScrollTarget = target
        shouldApplyNavigationTargetOnHeight = false
        navigationTargetRetriesLeft = target == nil ? 0 : Self.navigationTargetMaxRetries
    }

    /// Immediate fragment scroll within the already-rendered document.
    func scrollToAnchor(_ fragment: String) {
        scrollToElement(id: fragment)
    }

    var currentScrollPosition: CGFloat {
        webView.scrollMetrics.position
    }

    private func attemptNavigationScrollTarget(_ target: NavigationScrollTarget) {
        guard webView.isScrollGeometrySynced else {
            retryNavigationTarget()
            return
        }
        switch target {
        case .anchor(let fragment):
            webView.elementOffset(id: fragment) { [weak self] offset in
                guard let self,
                      self.pendingNavigationScrollTarget != nil else { return }
                guard let offset else {
                    self.retryNavigationTarget()
                    return
                }
                self.pendingNavigationScrollTarget = nil
                self.scrollDocument(to: offset)
            }
        case .position(let y):
            // Synced geometry can still be the blank page — hold out until
            // the offset is reachable, clamping only as a last resort.
            let metrics = webView.scrollMetrics
            let reachable = max(metrics.documentHeight - metrics.viewportHeight, 0)
            guard y <= reachable || navigationTargetRetriesLeft <= 0 else {
                retryNavigationTarget()
                return
            }
            pendingNavigationScrollTarget = nil
            // Exact restore: no top margin, no animation.
            webView.scrollDocument(to: y, topMargin: 0, duration: 0)
        }
    }

    private func retryNavigationTarget() {
        guard navigationTargetRetriesLeft > 0 else {
            pendingNavigationScrollTarget = nil
            return
        }
        navigationTargetRetriesLeft -= 1
        shouldApplyNavigationTargetOnHeight = true
        scheduleNavigationTargetAttempt()
    }

    private func scheduleNavigationTargetAttempt() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigationTargetRetryInterval) { [weak self] in
            guard let self, let target = self.pendingNavigationScrollTarget else { return }
            self.attemptNavigationScrollTarget(target)
        }
    }

    private func scrollToElement(id: String) {
        webView.elementOffset(id: id) { [weak self] offset in
            guard let self, let offset else { return }
            self.scrollDocument(to: offset)
        }
    }

    private func scrollDocument(to y: CGFloat,
                                topMargin: CGFloat = 12,
                                duration: TimeInterval = 0.25) {
        webView.scrollDocument(to: y, topMargin: topMargin, duration: duration)
    }

    // MARK: - Scrollspy

    private static let headingOffsetsRefreshDelay: TimeInterval = 0.05
    /// CSS-px window from the doc top in which a heading counts as the
    /// "lead" — close enough that body padding alone is what kept it
    /// below the activation line at scroll-top. Past this, the heading
    /// must earn its highlight by being scrolled past.
    private static let leadHeadingThreshold: CGFloat = 80

    private func scheduleHeadingOffsetsRefresh() {
        pendingHeadingOffsetsRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshHeadingOffsets()
        }
        pendingHeadingOffsetsRefresh = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.headingOffsetsRefreshDelay, execute: work
        )
    }

    private func refreshHeadingOffsets() {
        webView.collectHeadingOffsets { [weak self] offsets in
            guard let self else { return }
            self.headingOffsetsCSS = offsets
            self.evaluateActiveHeading()
        }
    }

    private func evaluateActiveHeading() {
        if let pin = sticky {
            if DispatchTime.now() < pin.holdUntil { return }
            if !hasMovedFar(from: pin.anchor) { return }
            sticky = nil
        }
        notifyActiveHeading(computeActiveHeadingID())
    }

    private func hasMovedFar(from anchor: CGFloat) -> Bool {
        let metrics = webView.scrollMetrics
        let delta = abs(metrics.position - anchor)
        return delta >= metrics.viewportHeight * Self.stickyReleaseFraction
    }

    /// Last heading whose top has scrolled above the activation line.
    /// Lead-heading bump handles the doc-starts-with-a-heading case;
    /// short-doc-last-heading is handled by `markHeadingActiveFromClick`.
    private func computeActiveHeadingID() -> Int? {
        guard !headingOffsetsCSS.isEmpty else { return nil }
        let metrics = webView.scrollMetrics
        let zoom = max(webView.pageZoom, 0.001)
        let topMargin: CGFloat = 12
        var activationLine = (metrics.position + topMargin + 8) / zoom

        if let firstOffset = headingOffsetsCSS.first,
           firstOffset <= Self.leadHeadingThreshold,
           activationLine < firstOffset + 1 {
            activationLine = firstOffset + 1
        }

        var active: Int?
        for (index, offset) in headingOffsetsCSS.enumerated() {
            if offset <= activationLine { active = index } else { break }
        }
        return active
    }
}
