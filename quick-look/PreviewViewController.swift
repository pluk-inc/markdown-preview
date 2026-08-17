//
//  PreviewViewController.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Quartz
import WebKit

private final class CursorRegionMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: QuickLookWebView?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame else { return }
        owner?.updateCursorRegions(from: message.body)
    }
}

private final class QuickLookWebView: WKWebView {
    private struct CursorRegion {
        let rect: NSRect
        let cursor: NSCursor
    }

    private static let cursorRegionMessageName = "mdPreviewCursorRegions"
    private static let maximumVisibleCursorRegions = 4_096
    private var cursorRegions: [CursorRegion] = []

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        let messageProxy = CursorRegionMessageProxy()
        configuration.userContentController.add(
            messageProxy,
            name: Self.cursorRegionMessageName
        )
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.cursorRegionReportingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        super.init(frame: frame, configuration: configuration)
        messageProxy.owner = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // The Quick Look host has no Edit menu, so ⌘A/⌘C never arrive as menu
    // key equivalents — claim them here and hand them to WebKit's standard
    // responder actions, which act on the page's DOM selection.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let command = QuickLookEditingCommands.command(
               forCharactersIgnoringModifiers: event.charactersIgnoringModifiers,
               modifierFlags: event.modifierFlags.rawValue
           ) {
            let action: Selector
            switch command {
            case .selectAll:
                action = #selector(NSResponder.selectAll(_:))
            case .copy:
                action = #selector(NSText.copy(_:))
            }
            if NSApp.sendAction(action, to: self, from: nil) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for region in cursorRegions {
            let rect = region.rect.intersection(visibleRect)
            guard !rect.isNull, !rect.isEmpty else { continue }
            addCursorRect(rect, cursor: region.cursor)
        }
    }

    fileprivate func updateCursorRegions(from body: Any) {
        guard let rows = body as? [Any] else { return }

        cursorRegions = rows.prefix(Self.maximumVisibleCursorRegions).compactMap { row in
            guard let values = row as? [Any],
                  values.count == 5,
                  let kind = values[0] as? String,
                  let x = (values[1] as? NSNumber)?.doubleValue,
                  let y = (values[2] as? NSNumber)?.doubleValue,
                  let width = (values[3] as? NSNumber)?.doubleValue,
                  let height = (values[4] as? NSNumber)?.doubleValue,
                  [x, y, width, height].allSatisfy(\.isFinite),
                  width > 0,
                  height > 0 else { return nil }

            let localX = bounds.minX + x
            let localY = isFlipped ? bounds.minY + y : bounds.maxY - y - height
            let rect = NSRect(x: localX, y: localY, width: width, height: height)
                .intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }

            let cursor: NSCursor
            switch kind {
            case "text":
                cursor = .iBeam
            case "pointer":
                cursor = .pointingHand
            default:
                return nil
            }
            return CursorRegion(rect: rect, cursor: cursor)
        }

        window?.invalidateCursorRects(for: self)
    }

    fileprivate func clearCursorRegions() {
        cursorRegions = []
        window?.invalidateCursorRects(for: self)
    }

    // A Quick Look preview is hosted through ViewBridge. WebKit's direct
    // cursor update is not forwarded reliably across that remote-window
    // boundary, while AppKit cursor rects are. Cache DOM layout rectangles
    // when layout changes, then only project that cache while scrolling; no
    // mouse-move listener or per-hover DOM hit testing is involved.
    private static let cursorRegionReportingScript = """
    (() => {
        const handler = window.webkit?.messageHandlers?.mdPreviewCursorRegions;
        if (!handler) return;

        const pointerSelector = [
            'a[href]',
            'button:not([disabled])',
            'summary',
            '[role="button"]',
            'input[type="checkbox"]:not([disabled])',
            'input[type="radio"]:not([disabled])',
            '.md-code-copy'
        ].join(',');
        const textExclusionSelector = [
            'a', 'button', 'input', 'select', 'textarea', 'summary',
            '[role="button"]', '.md-code-copy', '.mermaid-stage'
        ].join(',');

        let cachedRegions = [];
        let layoutFrame = null;
        let viewportFrame = null;
        let resizeObserver = null;
        let observedArticle = null;
        const maximumVisibleRegions = 4096;

        const isRenderable = (element) => {
            const style = getComputedStyle(element);
            return style.display !== 'none'
                && style.visibility !== 'hidden'
                && style.pointerEvents !== 'none';
        };

        const documentRect = (rect, scrollX, scrollY) => [
            rect.left + scrollX,
            rect.top + scrollY,
            rect.width,
            rect.height
        ];

        const clipsOverflow = (value) => [
            'auto', 'scroll', 'hidden', 'clip', 'overlay'
        ].includes(value);

        const clipToAncestors = (rect, startElement, article) => {
            let left = rect.left;
            let top = rect.top;
            let right = rect.right;
            let bottom = rect.bottom;

            for (let element = startElement; element; element = element.parentElement) {
                const style = getComputedStyle(element);
                const clipsX = clipsOverflow(style.overflowX);
                const clipsY = clipsOverflow(style.overflowY);
                if (clipsX || clipsY) {
                    const bounds = element.getBoundingClientRect();
                    const clipLeft = bounds.left + element.clientLeft;
                    const clipTop = bounds.top + element.clientTop;
                    const clipRight = clipLeft + element.clientWidth;
                    const clipBottom = clipTop + element.clientHeight;
                    if (clipsX) {
                        left = Math.max(left, clipLeft);
                        right = Math.min(right, clipRight);
                    }
                    if (clipsY) {
                        top = Math.max(top, clipTop);
                        bottom = Math.min(bottom, clipBottom);
                    }
                    if (right <= left || bottom <= top) return null;
                }
                if (element === article) break;
            }

            return {
                left,
                top,
                right,
                bottom,
                width: right - left,
                height: bottom - top
            };
        };

        const subtractRect = (rect, cut) => {
            const rectRight = rect[0] + rect[2];
            const rectBottom = rect[1] + rect[3];
            const cutRight = cut[0] + cut[2];
            const cutBottom = cut[1] + cut[3];
            const overlapLeft = Math.max(rect[0], cut[0]);
            const overlapTop = Math.max(rect[1], cut[1]);
            const overlapRight = Math.min(rectRight, cutRight);
            const overlapBottom = Math.min(rectBottom, cutBottom);
            if (overlapRight <= overlapLeft || overlapBottom <= overlapTop) {
                return [rect];
            }

            const pieces = [];
            if (overlapTop > rect[1]) {
                pieces.push([rect[0], rect[1], rect[2], overlapTop - rect[1]]);
            }
            if (overlapBottom < rectBottom) {
                pieces.push([rect[0], overlapBottom, rect[2], rectBottom - overlapBottom]);
            }
            if (overlapLeft > rect[0]) {
                pieces.push([
                    rect[0], overlapTop,
                    overlapLeft - rect[0], overlapBottom - overlapTop
                ]);
            }
            if (overlapRight < rectRight) {
                pieces.push([
                    overlapRight, overlapTop,
                    rectRight - overlapRight, overlapBottom - overlapTop
                ]);
            }
            return pieces;
        };

        const subtractRects = (rect, cuts) => {
            let pieces = [rect];
            for (const cut of cuts) {
                pieces = pieces.flatMap((piece) => subtractRect(piece, cut));
                if (pieces.length === 0) break;
            }
            return pieces;
        };

        const postVisibleRegions = () => {
            viewportFrame = null;
            const scrollX = window.scrollX;
            const scrollY = window.scrollY;
            const viewportWidth = document.documentElement.clientWidth;
            const viewportHeight = document.documentElement.clientHeight;
            const visiblePointerRects = [];
            const visibleTextRects = [];

            for (const [kind, documentX, documentY, width, height] of cachedRegions) {
                const x = documentX - scrollX;
                const y = documentY - scrollY;
                if (x + width <= 0 || y + height <= 0
                    || x >= viewportWidth || y >= viewportHeight) continue;

                const rect = [x, y, width, height];
                if (kind === 'pointer') {
                    visiblePointerRects.push(...subtractRects(rect, visiblePointerRects));
                } else {
                    visibleTextRects.push(rect);
                }
            }

            const visible = visiblePointerRects
                .slice(0, maximumVisibleRegions)
                .map((rect) => ['pointer', ...rect]);
            textRegions: for (const rect of visibleTextRects) {
                for (const piece of subtractRects(rect, visiblePointerRects)) {
                    if (visible.length >= maximumVisibleRegions) break textRegions;
                    visible.push(['text', ...piece]);
                }
            }
            handler.postMessage(visible);
        };

        const scheduleViewportProjection = () => {
            if (viewportFrame !== null) return;
            viewportFrame = requestAnimationFrame(postVisibleRegions);
        };

        const rebuildLayoutCache = () => {
            layoutFrame = null;
            if (viewportFrame !== null) {
                cancelAnimationFrame(viewportFrame);
                viewportFrame = null;
            }
            const article = document.querySelector('article.markdown-body');
            cachedRegions = [];
            if (!article) {
                handler.postMessage([]);
                return;
            }

            if (observedArticle !== article && window.ResizeObserver) {
                resizeObserver?.disconnect();
                resizeObserver = new ResizeObserver(scheduleLayoutRebuild);
                resizeObserver.observe(article);
                observedArticle = article;
            }

            const scrollX = window.scrollX;
            const scrollY = window.scrollY;

            for (const element of article.querySelectorAll(pointerSelector)) {
                if (!isRenderable(element) || element.getAttribute('aria-disabled') === 'true') {
                    continue;
                }
                for (const rect of element.getClientRects()) {
                    const clipped = clipToAncestors(rect, element.parentElement, article);
                    if (!clipped) continue;
                    cachedRegions.push([
                        'pointer',
                        ...documentRect(clipped, scrollX, scrollY)
                    ]);
                }
            }

            const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
                if (!node.nodeValue || !node.nodeValue.trim()) continue;
                const parent = node.parentElement;
                if (!parent || parent.closest(textExclusionSelector) || !isRenderable(parent)) {
                    continue;
                }

                const style = getComputedStyle(parent);
                if (style.userSelect === 'none' || style.webkitUserSelect === 'none') continue;

                const range = document.createRange();
                range.selectNodeContents(node);
                for (const rect of range.getClientRects()) {
                    const clipped = clipToAncestors(rect, parent, article);
                    if (!clipped) continue;
                    cachedRegions.push([
                        'text',
                        ...documentRect(clipped, scrollX, scrollY)
                    ]);
                }
            }

            postVisibleRegions();
        };

        function scheduleLayoutRebuild() {
            if (layoutFrame !== null) return;
            layoutFrame = requestAnimationFrame(rebuildLayoutCache);
        }

        const handleScroll = (event) => {
            const target = event.target;
            const rootScroll = target === window
                || target === document
                || target === document.scrollingElement
                || target === document.documentElement
                || target === document.body;
            if (rootScroll) {
                scheduleViewportProjection();
            } else {
                scheduleLayoutRebuild();
            }
        };

        addEventListener('scroll', handleScroll, true);
        addEventListener('resize', scheduleLayoutRebuild);
        document.addEventListener('DOMContentLoaded', scheduleLayoutRebuild, { once: true });
        document.addEventListener('load', scheduleLayoutRebuild, true);
        document.addEventListener('error', scheduleLayoutRebuild, true);
        document.addEventListener('toggle', scheduleLayoutRebuild, true);
        for (const eventName of [
            'md-preview-math-rendered',
            'md-preview-hljs-rendered',
            'md-preview-mermaid-rendered'
        ]) {
            addEventListener(eventName, scheduleLayoutRebuild);
        }
        document.fonts?.ready.then(scheduleLayoutRebuild);
        scheduleLayoutRebuild();
    })();
    """
}

final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private static let copyFeedbackDuration: TimeInterval = 1.0
    private static let floatingButtonMinimumWidth: CGFloat = 70
    private static let floatingButtonHeight: CGFloat = 26
    private static let floatingButtonTrailingInset: CGFloat = 12
    private static let floatingButtonBottomInset: CGFloat = 10
    private static let floatingButtonHorizontalClearance: CGFloat = 90
    private static let floatingButtonVerticalClearance: CGFloat = 44

    private var webView: QuickLookWebView!
    private var copyButton: NSButton!
    private var copyFeedbackWork: DispatchWorkItem?
    private var currentNavigation: WKNavigation?
    private var markdownSource: String?
    private var isPreviewReady = false
    private var isPreviewVisible = false

    override func loadView() {
        let rootView = NSView()

        webView = QuickLookWebView(
            frame: .zero,
            configuration: WKWebViewConfiguration()
        )
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        rootView.addSubview(webView)

        copyButton = makeCopyButton()
        rootView.addSubview(copyButton, positioned: .above, relativeTo: webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            copyButton.trailingAnchor.constraint(
                equalTo: rootView.safeAreaLayoutGuide.trailingAnchor,
                constant: -Self.floatingButtonTrailingInset
            ),
            copyButton.bottomAnchor.constraint(
                equalTo: rootView.safeAreaLayoutGuide.bottomAnchor,
                constant: -Self.floatingButtonBottomInset
            ),
            copyButton.widthAnchor.constraint(
                greaterThanOrEqualToConstant: Self.floatingButtonMinimumWidth
            ),
            copyButton.heightAnchor.constraint(equalToConstant: Self.floatingButtonHeight)
        ])

        view = rootView
        preferredContentSize = NSSize(
            width: MarkdownHTML.preferredPageWidth,
            height: MarkdownHTML.preferredPageWidth
        )
    }

    private func makeCopyButton() -> NSButton {
        let copyTitle = NSLocalizedString("Copy", comment: "Quick Look copy button")
        let button = NSButton(
            image: copyButtonImage(symbolName: "document.on.document", description: copyTitle),
            target: self,
            action: #selector(copyMarkdownSource(_:))
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier("QuickLookCopyMarkdown")
        button.title = copyTitle
        button.imagePosition = .imageLeading
        button.imageHugsTitle = false
        button.imageScaling = .scaleProportionallyDown
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        button.showsBorderOnlyWhileMouseInside = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .capsule
            button.tintProminence = .none
        } else {
            button.bezelStyle = .accessoryBarAction
        }
        button.isEnabled = false
        let copyMarkdownHelp = NSLocalizedString(
            "Copy Markdown source to clipboard",
            comment: "Quick Look copy-all accessibility help"
        )
        button.setAccessibilityLabel(copyTitle)
        button.setAccessibilityHelp(copyMarkdownHelp)

        return button
    }

    private func copyButtonImage(symbolName: String, description: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }

    @objc private func copyMarkdownSource(_ _: NSButton) {
        guard isPreviewVisible, isPreviewReady, let markdownSource else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(markdownSource, forType: .string) else {
            NSSound.beep()
            return
        }
        flashCopyConfirmation()
    }

    private func flashCopyConfirmation() {
        copyFeedbackWork?.cancel()
        let copied = NSLocalizedString("Copied", comment: "Quick Look copy confirmation")
        copyButton.title = copied
        copyButton.displayIfNeeded()
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: copied,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resetCopyButton()
        }
        copyFeedbackWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.copyFeedbackDuration,
            execute: work
        )
    }

    private func resetCopyButton() {
        copyFeedbackWork?.cancel()
        copyFeedbackWork = nil
        let copyTitle = NSLocalizedString("Copy", comment: "Quick Look copy button")
        copyButton.title = copyTitle
        copyButton.setAccessibilityLabel(copyTitle)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        isPreviewVisible = true
        activatePreviewIfReady()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        isPreviewVisible = false
        copyButton.isEnabled = false
        resetCopyButton()
    }

    private func activatePreviewIfReady() {
        guard isPreviewVisible, isPreviewReady else { return }
        copyButton.isEnabled = true
        view.window?.makeFirstResponder(webView)
    }

    private func addingCopyButtonClearance(to html: String) -> String {
        // Vendor scripts can contain `</head>` as data. The document's real
        // closing tag is the final occurrence in MarkdownHTML's output.
        guard let headEnd = html.range(of: "</head>", options: .backwards) else { return html }
        let horizontalClearance = Int(Self.floatingButtonHorizontalClearance)
        let verticalClearance = Int(Self.floatingButtonVerticalClearance)
        let style = """
        <style>
        body {
            padding-right: calc(\(horizontalClearance)px + env(safe-area-inset-right));
            padding-bottom: calc(\(verticalClearance)px + env(safe-area-inset-bottom));
        }
        </style>

        """
        var result = html
        result.insert(contentsOf: style, at: headEnd.lowerBound)
        return result
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let appearanceMode = AppearanceMode.current
        let colorScheme: MarkdownHTML.ColorScheme
        switch appearanceMode {
        case .automatic:
            let appearance = NSApplication.shared.effectiveAppearance
            let systemIsDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            colorScheme = appearanceMode.resolvedColorScheme(systemIsDark: systemIsDark)
        case .light:
            colorScheme = .light
        case .dark:
            colorScheme = .dark
        }

        let renderedHTML = addingCopyButtonClearance(to: MarkdownHTML.makeHTML(
            from: text,
            allowsScroll: true,
            colorScheme: colorScheme
        ))
        let baseDirectory = url.deletingLastPathComponent()
        let rewrite = InlineLocalAssets.rewriteRelativeImages(
            html: renderedHTML,
            baseDirectory: baseDirectory,
            reader: { try Data(contentsOf: $0) }
        )

        loadViewIfNeeded()
        markdownSource = text
        isPreviewReady = false
        resetCopyButton()
        copyButton.isEnabled = false
        webView.clearCursorRegions()
        currentNavigation = webView.loadHTMLString(
            InlineLocalAssets.dataURLHTML(from: rewrite),
            // Admitted local images are already data URLs. A directory base
            // would let WebKit fetch rejected or over-budget relative images.
            baseURL: nil
        )
    }

    // Quick Look opens with keyboard focus in the host (Finder), so ⌘A/⌘C
    // reach the preview only after the user clicks into it. Claiming first
    // responder once the content loads propagates focus across the
    // ViewBridge, making ⌘A/⌘C work immediately. The host still handles
    // arrows (file navigation) and space (close panel) itself — verified
    // against a focused preview.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === currentNavigation else { return }
        currentNavigation = nil
        isPreviewReady = true
        activatePreviewIfReady()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let isPageFragment = url.scheme == "about"
            && url.path == "blank"
            && url.fragment != nil
        if isPageFragment {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
