//
//  ContentViewController.swift
//  md-preview
//

import Cocoa

final class ContentViewController: NSViewController {

    private static let pageZoomDefaultsKey = "MarkdownPreview.pageZoom"

    private var webView: MarkdownWebView!
    private var documentHeightConstraint: NSLayoutConstraint!
    private var webViewHeightConstraint: NSLayoutConstraint!
    private var webViewPageWidthConstraint: NSLayoutConstraint?
    private var webViewCenteredConstraints: [NSLayoutConstraint] = []
    private var webViewFullWidthConstraints: [NSLayoutConstraint] = []
    private var measuredDocumentHeight: CGFloat = 1
    private var lastLaidOutSize: NSSize = .zero
    private var pendingFlashWork: DispatchWorkItem?
    private var pendingPreviewScrollAnchor: SourceScrollAnchor?
    private var shouldApplyPendingAnchorOnHeight = false

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
    var localMarkdownLinkActivated: ((URL) -> Void)?

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false

        webView = MarkdownWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.heightDidChange = { [weak self] height in
            guard let self else { return }
            if abs(height - self.measuredDocumentHeight) > 0.5 {
                self.measuredDocumentHeight = height
                self.applyDocumentHeight()
                // Image load / font reflow shifted layout — re-measure offsets.
                self.scheduleHeadingOffsetsRefresh()
            }
            if self.shouldApplyPendingAnchorOnHeight,
               let anchor = self.pendingPreviewScrollAnchor {
                self.shouldApplyPendingAnchorOnHeight = false
                self.pendingPreviewScrollAnchor = nil
                self.restoreSourceScrollAnchor(anchor)
            }
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
        webView.zoomDidChange = { [weak self] zoom in
            self?.webViewPageWidthConstraint?.constant = MarkdownHTML.preferredPageWidth * zoom
        }
        webView.enablePersistentZoom(defaultsKey: Self.pageZoomDefaultsKey)

        documentView.addSubview(webView)
        scrollView.documentView = documentView
        view = scrollView

        // The WKWebView is sized to full document height with internal
        // scrolling disabled — all scroll happens at the clip view. The
        // scrollspy listens for actual position changes (not gesture-begin
        // signals), so a trackpad gesture that can't scroll the doc — short
        // doc — leaves a click pin intact. queue: .main lets `assumeIsolated`
        // hop cleanly under Swift 6.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateActiveHeading() }
        }

        documentHeightConstraint = documentView.heightAnchor.constraint(equalToConstant: 1)
        webViewHeightConstraint = webView.heightAnchor.constraint(equalToConstant: 1)

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
            webView.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            webView.widthAnchor.constraint(lessThanOrEqualTo: documentView.widthAnchor),
            pageWidth
        ]
        webViewFullWidthConstraints = [
            webView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor)
        ]

        // Shared: document view tracks the clip width, web view pinned to
        // the top and sized to the measured content height.
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentHeightConstraint,

            webView.topAnchor.constraint(equalTo: documentView.topAnchor),
            webViewHeightConstraint
        ])
        applyContentWidthMode()
    }

    override func viewDidLayout() {
        super.viewDidLayout()

        let laidOutSize = view.bounds.size
        guard laidOutSize != lastLaidOutSize else { return }

        lastLaidOutSize = laidOutSize
        applyDocumentHeight()
    }

    func display(markdown: String, assetBaseURL: URL? = nil) {
        if pendingPreviewScrollAnchor != nil {
            shouldApplyPendingAnchorOnHeight = true
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
        guard let scrollView = view as? NSScrollView else { return true }
        let clipView = scrollView.contentView
        let visibleTop = clipView.bounds.origin.y + clipView.contentInsets.top
        let visibleBottom = clipView.bounds.origin.y
            + clipView.bounds.height
            - clipView.contentInsets.bottom
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
        guard let scrollView = view as? NSScrollView else { return 0 }
        let clipView = scrollView.contentView
        let minY = -clipView.contentInsets.top
        let maxY = max(documentHeightConstraint.constant - clipView.bounds.height
                       + clipView.contentInsets.bottom, minY)
        guard maxY > minY else { return 0 }
        return min(max((clipView.bounds.origin.y - minY) / (maxY - minY), 0), 1)
    }

    func sourceScrollAnchor(completion: @escaping (SourceScrollAnchor?) -> Void) {
        guard let scrollView = view as? NSScrollView else {
            completion(nil)
            return
        }
        let clipView = scrollView.contentView
        let visibleTop = clipView.bounds.origin.y + clipView.contentInsets.top
        webView.sourceAnchor(atDocumentY: visibleTop / webView.pageZoom, completion: completion)
    }

    func prepareToRestoreSourceScrollAnchor(_ anchor: SourceScrollAnchor?) {
        pendingPreviewScrollAnchor = anchor
    }

    func restoreSourceScrollAnchor(_ anchor: SourceScrollAnchor) {
        webView.sourceOffset(forPosition: anchor.sourcePosition) { [weak self] sourceTop in
            guard let self, let sourceTop else { return }
            let target = sourceTop * self.webView.pageZoom
            self.scrollDocument(to: target, topMargin: 0)
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
            ?? (view as? NSScrollView)?.contentView.bounds.origin.y
            ?? 0
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
              headingID < headingOffsetsCSS.count,
              let scrollView = view as? NSScrollView else { return nil }
        let clipView = scrollView.contentView
        let zoom = max(webView.pageZoom, 0.001)
        let topInset = clipView.contentInsets.top
        let bottomInset = clipView.contentInsets.bottom
        let topMargin: CGFloat = 12
        let y = headingOffsetsCSS[headingID] * zoom
        let minY = -topInset
        let maxY = max(documentHeightConstraint.constant - clipView.bounds.height + bottomInset,
                       minY)
        return max(minY, min(y - topInset - topMargin, maxY))
    }

    private func scrollToElement(id: String) {
        webView.elementOffset(id: id) { [weak self] offset in
            guard let self, let offset else { return }
            self.scrollDocument(to: offset)
        }
    }

    private func scrollDocument(to y: CGFloat, topMargin: CGFloat = 12) {
        guard let scrollView = view as? NSScrollView else { return }
        let clipView = scrollView.contentView
        let topInset = clipView.contentInsets.top
        let bottomInset = clipView.contentInsets.bottom
        let adjusted = y - topInset - topMargin
        let minY = -topInset
        let maxY = max(documentHeightConstraint.constant - clipView.bounds.height + bottomInset, minY)
        let target = max(minY, min(adjusted, maxY))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: target))
        }
        scrollView.reflectScrolledClipView(clipView)
    }

    private func applyDocumentHeight() {
        let resolvedHeight = max(measuredDocumentHeight, view.bounds.height, 1)
        documentHeightConstraint.constant = resolvedHeight
        webViewHeightConstraint.constant = resolvedHeight
        clampScrollPosition(toDocumentHeight: resolvedHeight)
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
        guard let scrollView = view as? NSScrollView else { return true }
        let clipView = scrollView.contentView
        let delta = abs(clipView.bounds.origin.y - anchor)
        return delta >= clipView.bounds.height * Self.stickyReleaseFraction
    }

    /// Last heading whose top has scrolled above the activation line.
    /// Lead-heading bump handles the doc-starts-with-a-heading case;
    /// short-doc-last-heading is handled by `markHeadingActiveFromClick`.
    private func computeActiveHeadingID() -> Int? {
        guard !headingOffsetsCSS.isEmpty,
              let scrollView = view as? NSScrollView else { return nil }
        let clipView = scrollView.contentView
        let zoom = max(webView.pageZoom, 0.001)
        let topMargin: CGFloat = 12
        var activationLine = (clipView.bounds.origin.y
                              + clipView.contentInsets.top
                              + topMargin
                              + 8) / zoom

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

    private func clampScrollPosition(toDocumentHeight documentHeight: CGFloat) {
        guard let scrollView = view as? NSScrollView else { return }

        let clipView = scrollView.contentView
        let maxY = max(documentHeight - clipView.bounds.height, 0)
        guard clipView.bounds.origin.y > maxY else {
            scrollView.reflectScrolledClipView(clipView)
            return
        }

        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maxY))
        scrollView.reflectScrolledClipView(clipView)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
