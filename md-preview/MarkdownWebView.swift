//
//  MarkdownWebView.swift
//  md-preview
//

import Cocoa
import os
import WebKit

extension Logger {
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "doc.md-preview"
    nonisolated static let perf = Logger(subsystem: subsystem, category: "perf")
}

enum SearchMode {
    case contains
    case beginsWith
}

/// User-selectable article layout, persisted across launches. Quick Look
/// always renders the centered column; this setting only drives the app.
/// Lives here (not AppDelegate.swift) because this file is compiled into
/// both targets and the setting is read at render time below.
enum ContentWidthSetting: String, CaseIterable {
    case normal
    case fullWidth

    private static let defaultsKey = "MarkdownPreview.contentWidth"

    static var current: ContentWidthSetting {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(ContentWidthSetting.init(rawValue:)) ?? .normal
        }
        set {
            if newValue == .normal {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .fullWidth: return "Full Width"
        }
    }

    var renderWidth: MarkdownHTML.ContentWidth {
        switch self {
        case .normal: return .centered
        case .fullWidth: return .full
        }
    }
}

struct FindResult {
    let top: CGFloat?
    let bottom: CGFloat?
    let index: Int
    let total: Int

    static let none = FindResult(top: nil, bottom: nil, index: 0, total: 0)
}

final class MarkdownWebView: NSView, WKNavigationDelegate {

    let webView: WKWebView
    var heightDidChange: ((CGFloat) -> Void)?
    var zoomDidChange: ((CGFloat) -> Void)?
    var fragmentLinkActivated: ((String) -> Void)?
    private let assetScheme = MarkdownAssetScheme()
    private var currentAssetBase: URL?
    private let messageBridge = HostBridge()

    private struct RendererFingerprint: Equatable {
        let math: Bool
        let mermaid: Bool
        let code: Bool

        /// True if every renderer the new doc needs is already loaded — the
        /// gate for the fast-path innerHTML swap.
        func covers(_ other: RendererFingerprint) -> Bool {
            (!other.math || math)
                && (!other.mermaid || mermaid)
                && (!other.code || code)
        }
    }
    private var loadedFingerprint: RendererFingerprint?
    private var isPageReady = false
    // Bumped on every display() call so a slower render finishing after a
    // newer one is dropped instead of clobbering the latest article.
    private var renderGeneration: UInt64 = 0
    // Last unzoomed document height reported by the page (CSS pixels). Cached
    // so a pageZoom change can re-fire heightDidChange with the right scale
    // without waiting for JS to post a fresh value (it won't — scrollHeight
    // is invariant under pageZoom).
    private var lastReportedDocumentHeight: CGFloat = 1
    private var zoomDefaultsKey: String?
    private var magnificationStartZoom: CGFloat?
    private var accumulatedMagnification: CGFloat = 0
    private var didMagnifyDuringCurrentGesture = false
    private var isPointerOverMermaidFigure = false
    private var currentMarkdown: String?

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assetScheme, forURLScheme: MarkdownAssetScheme.scheme)
        config.userContentController.addUserScript(Self.disableContextMenuScript)
        config.userContentController.add(messageBridge, name: HostBridge.name)
        webView = NonScrollingWKWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)

        messageBridge.owner = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        DispatchQueue.main.async { [weak self] in
            self?.neutralizeWebKitScrollEdgeInsets()
            self?.warmupVendors()
        }
    }

    private static let disableContextMenuScript = WKUserScript(
        source: """
        document.addEventListener('contextmenu', event => {
            const selection = window.getSelection();
            if (selection && selection.toString().trim().length > 0) return;
            event.preventDefault();
        }, true);
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    /// Synthetic markdown that flips every renderer flag (math + mermaid +
    /// code). Loaded into the WebView at launch so the heavy vendor JS is
    /// parsed and executed before the user picks a real file. Every later
    /// `display()` call then hits the fast-path (innerHTML swap + reapplier
    /// sweep) instead of paying for a full reload.
    private static let warmupMarkdown = """
    $x$

    ```mermaid
    graph TD; A-->B
    ```

    ```typescript
    let x: string = 'warmup';
    ```
    """

    private func warmupVendors() {
        guard !isPageReady, loadedFingerprint == nil else { return }
        let baseHref = "\(MarkdownAssetScheme.scheme):///"
        let markdown = Self.warmupMarkdown
        let contentWidth = ContentWidthSetting.current.renderWidth
        Task { @concurrent [weak self] in
            let rendered = Self.timedRender(label: "warmup",
                                            markdown: markdown,
                                            assetBaseHref: baseHref,
                                            contentWidth: contentWidth,
                                            warmup: true)
            await self?.applyWarmup(rendered)
        }
    }

    private func applyWarmup(_ rendered: MarkdownHTML.RenderedHTML) {
        // Another display() may have arrived during the off-main render and
        // already swapped the page in — don't stomp it with the warmup doc.
        guard !isPageReady, loadedFingerprint == nil else { return }
        loadedFingerprint = RendererFingerprint(
            math: rendered.containsMath,
            mermaid: rendered.containsMermaid,
            code: rendered.containsCode
        )
        webView.loadHTMLString(rendered.html, baseURL: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        neutralizeWebKitScrollEdgeInsets()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        neutralizeWebKitScrollEdgeInsets()
    }

    /// Empties the visible article without unloading the page, so the next
    /// `display()` still hits the fast-path.
    func clearContent() {
        guard isPageReady else { return }
        webView.evaluateJavaScript("window.MdPreview && MdPreview.update('');") { _, _ in }
    }

    func display(markdown: String, assetBaseURL: URL? = nil) {
        currentMarkdown = markdown
        isPointerOverMermaidFigure = false
        assetScheme.setBaseURL(assetBaseURL)
        currentAssetBase = assetBaseURL
        let baseHref = "\(MarkdownAssetScheme.scheme):///"
        renderGeneration &+= 1
        let generation = renderGeneration
        let contentWidth = ContentWidthSetting.current.renderWidth
        Task { @concurrent [weak self] in
            let rendered = Self.timedRender(label: "display",
                                            markdown: markdown,
                                            assetBaseHref: baseHref,
                                            contentWidth: contentWidth)
            await self?.applyDisplay(rendered, generation: generation)
        }
    }

    /// Logs Swift-side render duration alongside the JS-side `MdPreviewPerf`
    /// entries, so a single `log stream --predicate 'subsystem ==
    /// "doc.md-preview"'` shows render → load → first-paint end to end.
    private nonisolated static func timedRender(label: String,
                                                markdown: String,
                                                assetBaseHref: String,
                                                contentWidth: MarkdownHTML.ContentWidth,
                                                warmup: Bool = false) -> MarkdownHTML.RenderedHTML {
        let t0 = DispatchTime.now()
        let rendered = MarkdownHTML.render(markdown: markdown,
                                           assetBaseHref: assetBaseHref,
                                           vendorLoading: .lazy,
                                           contentWidth: contentWidth,
                                           warmup: warmup)
        let elapsedMs = Int(
            (Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds)
             / 1_000_000).rounded()
        )
        Logger.perf.debug(
            "[mdp-perf-swift] \(label, privacy: .public) render +\(elapsedMs, privacy: .public)ms (\(markdown.count, privacy: .public) chars)"
        )
        return rendered
    }

    private func applyDisplay(_ rendered: MarkdownHTML.RenderedHTML,
                              generation: UInt64) {
        // A newer display() bumped the generation while this render was
        // off-main — drop the stale result so the latest article wins.
        guard generation == renderGeneration else { return }
        let fingerprint = RendererFingerprint(
            math: rendered.containsMath,
            mermaid: rendered.containsMermaid,
            code: rendered.containsCode
        )

        // Fast path: the loaded page already has every renderer the new doc
        // needs — swap the article body via JS instead of reloading the
        // WKWebView (which would re-parse and re-execute the multi-MB vendor
        // bundles). The launch-time warmup loads both vendors, so any
        // subsequent file with any subset of renderers fast-paths into it.
        if isPageReady, let loaded = loadedFingerprint, loaded.covers(fingerprint) {
            let payload = javaScriptStringLiteral(rendered.articleHTML)
            webView.evaluateJavaScript("window.MdPreview && MdPreview.update(\(payload));") { _, _ in }
            return
        }

        webView.loadHTMLString(rendered.html, baseURL: nil)
        loadedFingerprint = fingerprint
        isPageReady = false
    }

    func reloadPreview() {
        guard let currentMarkdown else { return }
        display(markdown: currentMarkdown, assetBaseURL: currentAssetBase)
    }

    /// Full reload (no fast-path) so render-time settings — appearance,
    /// content width — are re-evaluated. The fingerprint reset is
    /// unconditional so a warmup-only page rendered under the old settings
    /// can't be fast-pathed into later.
    func reloadPreviewForSettingChange() {
        loadedFingerprint = nil
        isPageReady = false
        reloadPreview()
    }

    fileprivate func didReceiveHostMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String else { return }
        switch kind {
        case "height":
            guard let value = dict["value"] as? NSNumber else { return }
            let raw = ceil(CGFloat(truncating: value))
            lastReportedDocumentHeight = raw
            heightDidChange?(raw * webView.pageZoom)
        case "log":
            // MdPreviewPerf.log() — debug-only; release builds never post.
            // Routed through os.Logger so `log stream --level=debug
            // --predicate 'subsystem == "doc.md-preview"'` surfaces them.
            guard let message = dict["message"] as? String else { return }
            Logger.perf.debug("\(message, privacy: .public)")
        case "mermaidHover":
            guard let value = dict["value"] as? NSNumber else { return }
            isPointerOverMermaidFigure = value.boolValue
        case "copyCode":
            guard let text = dict["value"] as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case "scroll":
            guard let value = dict["value"] as? String else { return }
            switch value {
            case "lineUp":
                performScrollAction(.lineUp)
            case "lineDown":
                performScrollAction(.lineDown)
            case "pageUp":
                performScrollAction(.pageUp)
            case "pageDown":
                performScrollAction(.pageDown)
            default:
                break
            }
        default:
            break
        }
    }

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        highlightMatches(for: query, backwards: backwards, mode: mode, completion: completion)
    }

    /// Flashes the macOS-style "burst" animation over the current match —
    /// a yellow rounded rect that starts large and shrinks down to the match.
    func flashCurrentMatch() {
        let script = """
        (() => {
            const root = document.querySelector('.markdown-body') || document.body;
            const marks = root.querySelectorAll('mark.md-search-highlight');
            const index = window.__mdPreviewSearchIndex;
            if (!Number.isInteger(index) || index < 0 || index >= marks.length) return;
            // Drop any in-flight burst so fast typing doesn't pile elements
            // on the body waiting to fire animationend.
            document.querySelectorAll('.md-search-burst').forEach(b => b.remove());
            const target = marks[index];
            const rect = target.getBoundingClientRect();
            const scrollX = window.scrollX || document.documentElement.scrollLeft || 0;
            const scrollY = window.scrollY || document.documentElement.scrollTop || 0;
            const padX = 6;
            const padY = 4;
            const burst = document.createElement('span');
            burst.className = 'md-search-burst';
            burst.style.left = (rect.left + scrollX - padX) + 'px';
            burst.style.top = (rect.top + scrollY - padY) + 'px';
            burst.style.width = (rect.width + padX * 2) + 'px';
            burst.style.height = (rect.height + padY * 2) + 'px';
            document.body.appendChild(burst);
            burst.addEventListener('animationend', () => burst.remove(), { once: true });
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    // Discrete zoom stops, mirroring Safari's ⌘+/⌘− cadence.
    private static let zoomSteps: [CGFloat] = [
        0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0
    ]

    var pageZoom: CGFloat { webView.pageZoom }

    func zoomIn() { setPageZoom(nextZoomStep(from: webView.pageZoom, increasing: true)) }
    func zoomOut() { setPageZoom(nextZoomStep(from: webView.pageZoom, increasing: false)) }
    func resetZoom() { setPageZoom(1.0) }

    fileprivate func beginMagnificationZoom() {
        magnificationStartZoom = webView.pageZoom
        accumulatedMagnification = 0
        didMagnifyDuringCurrentGesture = false
    }

    fileprivate var shouldForwardMagnificationToContent: Bool {
        isPointerOverMermaidFigure && magnificationStartZoom == nil
    }

    fileprivate func magnifyPreview(by delta: CGFloat) {
        guard delta.isFinite else { return }
        if magnificationStartZoom == nil {
            beginMagnificationZoom()
        }

        didMagnifyDuringCurrentGesture = true
        accumulatedMagnification += delta
        let scale = max(0.1, 1 + accumulatedMagnification)
        setPageZoom((magnificationStartZoom ?? webView.pageZoom) * scale, persist: false)
    }

    fileprivate func endMagnificationZoom() {
        guard magnificationStartZoom != nil else { return }
        let shouldPersistZoom = didMagnifyDuringCurrentGesture
        magnificationStartZoom = nil
        accumulatedMagnification = 0
        didMagnifyDuringCurrentGesture = false
        if shouldPersistZoom {
            persistPageZoom(webView.pageZoom)
        }
    }

    func enablePersistentZoom(defaultsKey: String) {
        zoomDefaultsKey = defaultsKey
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber else { return }
        setPageZoom(CGFloat(truncating: stored), persist: false, notifyHeight: false)
    }

    private func nextZoomStep(from current: CGFloat, increasing: Bool) -> CGFloat {
        let steps = Self.zoomSteps
        if increasing {
            return steps.first(where: { $0 > current + 0.001 }) ?? steps.last!
        } else {
            return steps.last(where: { $0 < current - 0.001 }) ?? steps.first!
        }
    }

    private func setPageZoom(_ value: CGFloat,
                             persist: Bool = true,
                             notifyHeight: Bool = true) {
        let clamped = clampedZoom(value)
        guard abs(webView.pageZoom - clamped) > 0.001 else { return }
        webView.pageZoom = clamped
        zoomDidChange?(clamped)
        if persist {
            persistPageZoom(clamped)
        }
        if notifyHeight {
            heightDidChange?(lastReportedDocumentHeight * clamped)
        }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1.0 }
        return max(Self.zoomSteps.first!, min(Self.zoomSteps.last!, value))
    }

    private func persistPageZoom(_ value: CGFloat) {
        guard let zoomDefaultsKey else { return }
        if abs(value - 1.0) <= 0.001 {
            UserDefaults.standard.removeObject(forKey: zoomDefaultsKey)
        } else {
            UserDefaults.standard.set(Double(value), forKey: zoomDefaultsKey)
        }
    }

    func printDocument(from window: NSWindow) {
        let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

        let operation = webView.printOperation(with: printInfo)
        operation.jobTitle = window.title
        // WKWebView's print view needs an explicit frame, otherwise AppKit
        // asserts in `runModal` when the operation tries to lay out at zero
        // size — Apple's documented pattern.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Top offsets in CSS pixels for every `md-heading-N`, in document
    /// order. Index matches `TOCNode.headingID`.
    func collectHeadingOffsets(completion: @escaping ([CGFloat]) -> Void) {
        webView.evaluateJavaScript(Self.headingOffsetsScript) { result, _ in
            guard let raw = result as? [NSNumber] else {
                completion([])
                return
            }
            completion(raw.map { CGFloat(truncating: $0) })
        }
    }

    private static let headingOffsetsScript = """
    (() => {
        const els = document.querySelectorAll('[id^="md-heading-"]');
        const scroll = window.scrollY || document.documentElement.scrollTop || 0;
        return Array.from(els).map(el => el.getBoundingClientRect().top + scroll);
    })();
    """

    func headingOffset(index: Int, completion: @escaping (CGFloat?) -> Void) {
        let script = """
        (() => {
            const el = document.getElementById('md-heading-\(index)');
            if (!el) return null;
            const rect = el.getBoundingClientRect();
            return rect.top + (window.scrollY || document.documentElement.scrollTop || 0);
        })();
        """
        webView.evaluateJavaScript(script) { result, _ in
            if let number = result as? NSNumber {
                completion(self.scaledDocumentOffset(CGFloat(truncating: number)))
            } else {
                completion(nil)
            }
        }
    }

    func elementOffset(id: String, completion: @escaping (CGFloat?) -> Void) {
        let script = """
        (() => {
            const el = document.getElementById(\(javaScriptStringLiteral(id)));
            if (!el) return null;
            const rect = el.getBoundingClientRect();
            return rect.top + (window.scrollY || document.documentElement.scrollTop || 0);
        })();
        """
        webView.evaluateJavaScript(script) { result, _ in
            if let number = result as? NSNumber {
                completion(self.scaledDocumentOffset(CGFloat(truncating: number)))
            } else {
                completion(nil)
            }
        }
    }

    private func highlightMatches(for query: String,
                                  backwards: Bool,
                                  mode: SearchMode,
                                  completion: ((FindResult) -> Void)?) {
        let beginsWith = mode == .beginsWith
        let script = """
        (() => {
            const root = document.querySelector('.markdown-body') || document.body;
            const previousQuery = window.__mdPreviewSearchQuery || '';
            const previousBeginsWith = window.__mdPreviewSearchBeginsWith === true;
            const beginsWith = \(beginsWith ? "true" : "false");
            const sameQuery = previousQuery === \(javaScriptStringLiteral(query))
                && previousBeginsWith === beginsWith;

            // Tear down prior highlights, but only normalize() the parents we
            // actually touched — root.normalize() is O(N) over the entire
            // document subtree, which is the dominant stall on big docs.
            const priorMarks = root.querySelectorAll('mark.md-search-highlight');
            if (priorMarks.length > 0) {
                const dirty = new Set();
                priorMarks.forEach((mark) => {
                    const parent = mark.parentNode;
                    if (parent) dirty.add(parent);
                    mark.replaceWith(document.createTextNode(mark.textContent));
                });
                dirty.forEach((parent) => parent.normalize());
            }

            const query = \(javaScriptStringLiteral(query));
            window.__mdPreviewSearchQuery = query;
            window.__mdPreviewSearchBeginsWith = beginsWith;
            if (!query) {
                window.__mdPreviewSearchIndex = -1;
                return { top: null, bottom: null, index: 0, total: 0 };
            }
            const isWordChar = (ch) => /[A-Za-z0-9_]/.test(ch);

            const needle = query.toLocaleLowerCase();
            // checkVisibility() forces layout, and KaTeX/Mermaid pages have
            // many text nodes per parent — cache by parent so we hit it once.
            const visibilityCache = new WeakMap();
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                acceptNode(node) {
                    const parent = node.parentElement;
                    if (!parent || parent.closest('script, style, textarea, mark.md-search-highlight')) {
                        return NodeFilter.FILTER_REJECT;
                    }
                    // KaTeX/Mermaid stash hidden MathML / source mirrors with
                    // getBoundingClientRect.top===0 — scrolling to those would
                    // jump the doc to the top with nothing visible.
                    let visible = visibilityCache.get(parent);
                    if (visible === undefined) {
                        visible = typeof parent.checkVisibility !== 'function'
                            || parent.checkVisibility();
                        visibilityCache.set(parent, visible);
                    }
                    if (!visible) return NodeFilter.FILTER_REJECT;
                    // Don't double-lowercase here; the inner loop already does
                    // one .toLocaleLowerCase() per node and an .indexOf, which
                    // short-circuits cheaply on non-matching text.
                    return NodeFilter.FILTER_ACCEPT;
                }
            });

            const nodes = [];
            while (walker.nextNode()) { nodes.push(walker.currentNode); }

            const marks = [];
            for (const node of nodes) {
                const text = node.nodeValue;
                const lower = text.toLocaleLowerCase();
                const fragment = document.createDocumentFragment();
                let offset = 0;
                let searchFrom = 0;
                let matchIndex = lower.indexOf(needle, searchFrom);
                let nodeHasMatch = false;

                while (matchIndex !== -1) {
                    const prevChar = matchIndex === 0 ? '' : text[matchIndex - 1];
                    const isBoundary = matchIndex === 0 || !isWordChar(prevChar);

                    if (!beginsWith || isBoundary) {
                        fragment.append(document.createTextNode(text.slice(offset, matchIndex)));

                        const mark = document.createElement('mark');
                        mark.className = 'md-search-highlight';
                        mark.textContent = text.slice(matchIndex, matchIndex + query.length);
                        fragment.append(mark);
                        marks.push(mark);

                        offset = matchIndex + query.length;
                        searchFrom = offset;
                        nodeHasMatch = true;
                    } else {
                        // Skip this match, but keep scanning the same text node.
                        searchFrom = matchIndex + 1;
                    }
                    matchIndex = lower.indexOf(needle, searchFrom);
                }

                if (nodeHasMatch) {
                    fragment.append(document.createTextNode(text.slice(offset)));
                    node.replaceWith(fragment);
                }
            }

            if (marks.length === 0) {
                window.__mdPreviewSearchIndex = -1;
                return { top: null, bottom: null, index: 0, total: 0 };
            }

            const previousIndex = Number.isInteger(window.__mdPreviewSearchIndex)
                ? window.__mdPreviewSearchIndex
                : -1;
            const backwards = \(backwards ? "true" : "false");
            let index;

            if (!sameQuery || previousIndex < 0) {
                index = backwards ? marks.length - 1 : 0;
            } else if (backwards) {
                index = (previousIndex - 1 + marks.length) % marks.length;
            } else {
                index = (previousIndex + 1) % marks.length;
            }

            window.__mdPreviewSearchIndex = index;
            const current = marks[index];
            current.classList.add('md-search-highlight-current');

            // The WKWebView host disables internal scrolling and forwards it to
            // an outer NSScrollView, so scrollIntoView() is a no-op. Hand the
            // document-space bounds back so AppKit can scroll the clip view —
            // and only when the match isn't already on screen.
            const rect = current.getBoundingClientRect();
            const scrollY = window.scrollY || document.documentElement.scrollTop || 0;
            return {
                top: rect.top + scrollY,
                bottom: rect.bottom + scrollY,
                index: index + 1,
                total: marks.length
            };
        })();
        """
        webView.evaluateJavaScript(script) { result, _ in
            guard let completion else { return }
            let dict = result as? [String: Any]
            let top = (dict?["top"] as? NSNumber).map { self.scaledDocumentOffset(CGFloat(truncating: $0)) }
            let bottom = (dict?["bottom"] as? NSNumber).map { self.scaledDocumentOffset(CGFloat(truncating: $0)) }
            let index = (dict?["index"] as? NSNumber)?.intValue ?? 0
            let total = (dict?["total"] as? NSNumber)?.intValue ?? 0
            completion(FindResult(top: top, bottom: bottom, index: index, total: total))
        }
    }

    private func scaledDocumentOffset(_ cssOffset: CGFloat) -> CGFloat {
        cssOffset * webView.pageZoom
    }

    private func javaScriptStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    enum ScrollAction {
        case lineUp, lineDown, pageUp, pageDown, top, bottom, previousHeading, nextHeading
    }

    /// Returns true when the action was handled (false if there's no outer
    /// scroll view yet, so the keyDown forwarder falls back to super).
    @discardableResult
    func performScrollAction(_ action: ScrollAction) -> Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? clipView.bounds.height
        let topInset = clipView.contentInsets.top
        let bottomInset = clipView.contentInsets.bottom
        let minY = -topInset
        let maxY = max(documentHeight - clipView.bounds.height + bottomInset, minY)
        let pageDelta = max(clipView.bounds.height * 0.9, 40)
        let lineDelta: CGFloat = 40

        if action == .previousHeading {
            scrollToAdjacentHeading(forward: false, in: scrollView)
            return true
        }
        if action == .nextHeading {
            scrollToAdjacentHeading(forward: true, in: scrollView)
            return true
        }

        let target: CGFloat
        let duration: TimeInterval
        switch action {
        case .lineUp:
            target = max(minY, min(clipView.bounds.origin.y - lineDelta, maxY))
            duration = 0.08
        case .lineDown:
            target = max(minY, min(clipView.bounds.origin.y + lineDelta, maxY))
            duration = 0.08
        case .pageUp:
            target = max(minY, min(clipView.bounds.origin.y - pageDelta, maxY))
            duration = 0.08
        case .pageDown:
            target = max(minY, min(clipView.bounds.origin.y + pageDelta, maxY))
            duration = 0.08
        case .top:
            target = minY
            duration = 0.2
        case .bottom:
            target = maxY
            duration = 0.2
        case .previousHeading, .nextHeading:
            return true
        }
        animateOuterScroll(to: target, in: scrollView, duration: duration)
        return true
    }

    private func animateOuterScroll(to y: CGFloat,
                                    in scrollView: NSScrollView,
                                    duration: TimeInterval) {
        let clipView = scrollView.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: y))
        }
        scrollView.reflectScrolledClipView(clipView)
        scrollView.flashScrollers()
    }

    private func scrollToAdjacentHeading(forward: Bool, in scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        let topInset = clipView.contentInsets.top
        let bottomInset = clipView.contentInsets.bottom
        let viewportTop = clipView.bounds.origin.y + topInset

        webView.evaluateJavaScript(Self.headingOffsetsScript) { [weak self, weak scrollView] result, _ in
            guard let self,
                  let scrollView,
                  let raw = result as? [NSNumber] else { return }
            let offsets = raw.map { CGFloat(truncating: $0) }.sorted()
            // Headings we navigate to land at viewportTop + topMargin (12 pt).
            // Forward needs a buffer that clears that parked heading; backward
            // needs to look strictly above the viewport top.
            let zoom = self.webView.pageZoom
            let cssViewportTop = viewportTop / zoom
            let pick: CGFloat? = forward
                ? offsets.first(where: { $0 > cssViewportTop + 16 })
                : offsets.last(where: { $0 < cssViewportTop - 1 })
            guard let headingY = pick else { return }
            let topMargin: CGFloat = 12
            let documentHeight = scrollView.documentView?.bounds.height ?? clipView.bounds.height
            let minY = -topInset
            let maxY = max(documentHeight - clipView.bounds.height + bottomInset, minY)
            let target = max(minY, min((headingY * zoom) - topInset - topMargin, maxY))
            self.animateOuterScroll(to: target, in: scrollView, duration: 0.2)
        }
    }

    override func scrollLineUp(_ sender: Any?)            { performScrollAction(.lineUp) }
    override func scrollLineDown(_ sender: Any?)          { performScrollAction(.lineDown) }
    override func scrollPageUp(_ sender: Any?)            { performScrollAction(.pageUp) }
    override func scrollPageDown(_ sender: Any?)          { performScrollAction(.pageDown) }
    override func pageUp(_ sender: Any?)                  { performScrollAction(.pageUp) }
    override func pageDown(_ sender: Any?)                { performScrollAction(.pageDown) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { performScrollAction(.top) }
    override func scrollToEndOfDocument(_ sender: Any?)   { performScrollAction(.bottom) }
    override func moveToBeginningOfDocument(_ sender: Any?) { performScrollAction(.top) }
    override func moveToEndOfDocument(_ sender: Any?)     { performScrollAction(.bottom) }
    @objc func mdScrollPreviousHeading(_ sender: Any?) { performScrollAction(.previousHeading) }
    @objc func mdScrollNextHeading(_ sender: Any?)     { performScrollAction(.nextHeading) }

    private func neutralizeWebKitScrollEdgeInsets() {
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        for view in webView.descendantViews {
            if let scrollView = view as? NSScrollView {
                scrollView.automaticallyAdjustsContentInsets = false
                scrollView.hasVerticalScroller = false
                scrollView.hasHorizontalScroller = false
                scrollView.autohidesScrollers = true
                scrollView.verticalScrollElasticity = .none
                scrollView.horizontalScrollElasticity = .none
                scrollView.contentInsets = zeroInsets
                scrollView.scrollerInsets = zeroInsets
                scrollView.verticalScroller?.isHidden = true
                scrollView.verticalScroller?.alphaValue = 0
                scrollView.horizontalScroller?.isHidden = true
                scrollView.horizontalScroller?.alphaValue = 0
            }
            if let scroller = view as? NSScroller {
                scroller.isHidden = true
                scroller.alphaValue = 0
            }
            if let clipView = view as? NSClipView {
                clipView.automaticallyAdjustsContentInsets = false
                clipView.contentInsets = zeroInsets
            }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            if let fragment = sameDocumentFragmentID(from: url) {
                fragmentLinkActivated?(fragment)
            } else if url.scheme == MarkdownAssetScheme.scheme,
               let base = currentAssetBase,
               let resolved = MarkdownAssetScheme.resolve(url, against: base) {
                NSWorkspace.shared.open(resolved)
            } else if url.scheme != MarkdownAssetScheme.scheme {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        neutralizeWebKitScrollEdgeInsets()
        isPageReady = true
    }

    private func sameDocumentFragmentID(from url: URL) -> String? {
        guard let fragment = url.fragment?.removingPercentEncoding,
              !fragment.isEmpty,
              url.query == nil else { return nil }

        if url.scheme == nil {
            return fragment
        }
        if url.scheme == "about", url.absoluteString.hasPrefix("about:blank#") {
            return fragment
        }
        if url.scheme == MarkdownAssetScheme.scheme,
           (url.host == nil || url.host == ""),
           (url.path.isEmpty || url.path == "/") {
            return fragment
        }
        return nil
    }
}

private extension NSView {
    var descendantViews: [NSView] {
        subviews + subviews.flatMap(\.descendantViews)
    }
}

private final class NonScrollingWKWebView: WKWebView {
    private enum Axis { case horizontal, vertical }
    private var lockedAxis: Axis?

    override func keyDown(with event: NSEvent) {
        if forwardHeadingKey(event) { return }
        if forwardShiftArrowKey(event) { return }
        if isStandardScrollKey(event) {
            interpretKeyEvents([event])
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if performStandardScrollCommand(selector) { return }
        super.doCommand(by: selector)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        menu?.removeWebKitReloadItems()
        return menu
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeWebKitReloadItems()
        super.willOpenMenu(menu, with: event)
    }

    override func reload(_ sender: Any?) {
        (superview as? MarkdownWebView)?.reloadPreview()
    }

    override func beginGesture(with event: NSEvent) {
        guard let owner = superview as? MarkdownWebView else {
            super.beginGesture(with: event)
            return
        }
        if !owner.shouldForwardMagnificationToContent {
            owner.beginMagnificationZoom()
        }
        super.beginGesture(with: event)
    }

    override func magnify(with event: NSEvent) {
        guard let owner = superview as? MarkdownWebView else {
            super.magnify(with: event)
            return
        }
        if owner.shouldForwardMagnificationToContent {
            super.magnify(with: event)
            return
        }
        owner.magnifyPreview(by: event.magnification)
    }

    override func endGesture(with event: NSEvent) {
        (superview as? MarkdownWebView)?.endMagnificationZoom()
        super.endGesture(with: event)
    }

    override func scrollLineUp(_ sender: Any?)            { forwardScrollAction(.lineUp) }
    override func scrollLineDown(_ sender: Any?)          { forwardScrollAction(.lineDown) }
    override func scrollPageUp(_ sender: Any?)            { forwardScrollAction(.pageUp) }
    override func scrollPageDown(_ sender: Any?)          { forwardScrollAction(.pageDown) }
    override func moveUpAndModifySelection(_ sender: Any?) { forwardScrollAction(.pageUp) }
    override func moveDownAndModifySelection(_ sender: Any?) { forwardScrollAction(.pageDown) }
    override func pageUp(_ sender: Any?)                  { forwardScrollAction(.pageUp) }
    override func pageDown(_ sender: Any?)                { forwardScrollAction(.pageDown) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { forwardScrollAction(.top) }
    override func scrollToEndOfDocument(_ sender: Any?)   { forwardScrollAction(.bottom) }
    override func moveToBeginningOfDocument(_ sender: Any?) { forwardScrollAction(.top) }
    override func moveToEndOfDocument(_ sender: Any?)     { forwardScrollAction(.bottom) }

    /// Option-Up/Down is app-specific heading navigation, so it remains outside
    /// AppKit's standard key-binding commands.
    private func forwardHeadingKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return false }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            return forwardScrollAction(.previousHeading)
        case NSDownArrowFunctionKey:
            return forwardScrollAction(.nextHeading)
        default:
            return false
        }
    }

    private func forwardShiftArrowKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.subtracting([.shift, .capsLock]).isEmpty,
              modifiers.contains(.shift),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey:
            return forwardScrollAction(.pageUp)
        case NSDownArrowFunctionKey:
            return forwardScrollAction(.pageDown)
        default:
            return false
        }
    }

    private func isStandardScrollKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.shift),
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return false }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey, NSDownArrowFunctionKey,
             NSPageUpFunctionKey, NSPageDownFunctionKey,
             NSHomeFunctionKey, NSEndFunctionKey:
            return true
        default:
            return false
        }
    }

    @discardableResult
    private func performStandardScrollCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(scrollLineUp(_:)):
            return forwardScrollAction(.lineUp)
        case #selector(scrollLineDown(_:)):
            return forwardScrollAction(.lineDown)
        case #selector(moveUpAndModifySelection(_:)):
            return forwardScrollAction(.pageUp)
        case #selector(moveDownAndModifySelection(_:)):
            return forwardScrollAction(.pageDown)
        case #selector(scrollPageUp(_:)), #selector(pageUp(_:)):
            return forwardScrollAction(.pageUp)
        case #selector(scrollPageDown(_:)), #selector(pageDown(_:)):
            return forwardScrollAction(.pageDown)
        case #selector(scrollToBeginningOfDocument(_:)),
             #selector(moveToBeginningOfDocument(_:)):
            return forwardScrollAction(.top)
        case #selector(scrollToEndOfDocument(_:)),
             #selector(moveToEndOfDocument(_:)):
            return forwardScrollAction(.bottom)
        default:
            return false
        }
    }

    @discardableResult
    private func forwardScrollAction(_ action: MarkdownWebView.ScrollAction) -> Bool {
        guard let owner = superview as? MarkdownWebView else { return false }
        return owner.performScrollAction(action)
    }

    override func scrollWheel(with event: NSEvent) {
        let axis = decideAxis(for: event)
        if axis == .horizontal {
            // Inner overflow:auto element (wide <pre>, table, math) handles it.
            super.scrollWheel(with: event)
            return
        }
        if let outerScrollView = superview?.enclosingScrollView {
            outerScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    /// Lock routing axis at the start of a trackpad gesture and carry it
    /// through .changed/.ended and any momentum that follows. Without this,
    /// a momentary Y-dominant event mid-horizontal-swipe routes one frame
    /// to the outer page scroller and the user sees a lurch. Mouse-wheel
    /// events (phase empty) clear the lock and decide per-event.
    private func decideAxis(for event: NSEvent) -> Axis {
        let perEvent: Axis = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? .horizontal : .vertical

        if event.phase == .began {
            lockedAxis = perEvent
            return perEvent
        }

        let isTrackpadEvent = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if isTrackpadEvent, let locked = lockedAxis {
            if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                lockedAxis = nil
            }
            return locked
        }

        lockedAxis = nil
        return perEvent
    }
}

private extension NSMenu {
    func removeWebKitReloadItems() {
        for item in items {
            item.submenu?.removeWebKitReloadItems()
        }
        items.removeAll { $0.action == #selector(WKWebView.reload(_:)) }
    }
}

// Receives postMessage() calls from the page's host-bridge script. Held weakly
// by the WKUserContentController via this proxy so the MarkdownWebView itself
// is free to deallocate without a retain cycle through the config.
private final class HostBridge: NSObject, WKScriptMessageHandler {
    static let name = "mdPreviewHost"
    weak var owner: MarkdownWebView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == HostBridge.name else { return }
        owner?.didReceiveHostMessage(message.body)
    }
}
