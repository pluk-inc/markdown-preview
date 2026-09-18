//
//  EditorViewController.swift
//  md-preview
//

import Cocoa
import WebKit

/// Inline Typora-style editor for the current document: a CodeMirror 6
/// page (Vendor/CodeMirror/mdedit.min.js) with live-preview decorations —
/// headings, emphasis, quotes and code style themselves as you type, and
/// syntax marks hide unless the cursor is inside them. The buffer is the
/// markdown source itself, so saving is byte-faithful: nothing is
/// reformatted or normalized. The page is fully self-contained (no
/// network), so edit mode works offline and inside the sandbox.
final class EditorViewController: NSViewController, WKNavigationDelegate {

    /// Fired on every document change — the host debounces for autosave.
    var contentDidChange: (() -> Void)?
    /// Fired after CodeMirror has constructed and painted its initial document.
    /// The split view uses this to avoid replacing the preview with a blank WKWebView.
    var editorDidBecomeReady: (() -> Void)?
    /// Esc pressed in the editor — the host decides whether to confirm
    /// and discard.
    var cancelRequested: (() -> Void)?
    /// A native image was pasted at the editor selection.
    var pasteImageRequested: ((Int, Int) -> Void)?
    /// A rendered local image was clicked in the live editor preview.
    var imageClicked: ((URL) -> Void)?

    private(set) var hasChanges = false

    private var webView: WKWebView!
    private let bridge = EditorBridge()
    private let assetScheme = MarkdownAssetScheme()
    private var hasLoadedEditorPage = false
    private var pageSupportsMermaid = false
    private var currentAssetBaseURL: URL?
    /// Wider than the document's folder only when the reader opened a folder
    /// containing it — see `MarkdownAccessPolicy`.
    private var currentContainmentRoot: URL?
    private var findCompletion: ((FindResult) -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assetScheme, forURLScheme: MarkdownAssetScheme.scheme)
        config.userContentController.add(bridge, name: EditorBridge.name)
        let webView = EditorWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .windowBackgroundColor
        bridge.owner = self
        self.webView = webView
        view = webView
    }

    /// Applies a changed containment boundary to the document already open in
    /// the editor, without touching its content — cursor, selection, scroll
    /// position, and undo history all survive. For when the boundary itself
    /// moved (the reader opened a different folder, or the open document was
    /// renamed or moved to a different folder) but the document's content on
    /// screen didn't change; `load(markdown:assetBaseURL:containmentRoot:)`
    /// is for the document itself changing.
    ///
    /// Also refreshes the live page's `<base>` href, not just the Swift-side
    /// and scheme-handler boundaries — `<base>` is what the browser resolves
    /// a relative `src="../foo.png"` against, so leaving it stale would keep
    /// resolving (or failing to resolve) assets against the folder the
    /// document just left.
    func updateContainmentRoot(_ containmentRoot: URL?, assetBaseURL: URL?) {
        currentContainmentRoot = containmentRoot?.standardizedFileURL
        currentAssetBaseURL = assetBaseURL?.standardizedFileURL
        assetScheme.setContainmentRoot(currentContainmentRoot)
        assetScheme.setBaseURL(currentAssetBaseURL)
        let baseHref = currentAssetBaseURL.map(MarkdownAssetResolution.baseHref(forFolder:)) ?? ""
        webView.evaluateJavaScript(
            "window.__mdSetBaseHref && window.__mdSetBaseHref(\(EditorHTML.jsStringLiteral(baseHref)))"
        )
    }

    func load(markdown: String, assetBaseURL: URL? = nil, containmentRoot: URL? = nil) {
        hasChanges = false
        currentAssetBaseURL = assetBaseURL?.standardizedFileURL
        currentContainmentRoot = containmentRoot?.standardizedFileURL
        assetScheme.setBaseURL(currentAssetBaseURL)
        assetScheme.setContainmentRoot(currentContainmentRoot)
        let needsMermaid = Self.containsMermaidFence(in: markdown)
        if hasLoadedEditorPage, pageSupportsMermaid || !needsMermaid {
            let baseHref = currentAssetBaseURL.map(MarkdownAssetResolution.baseHref(forFolder:)) ?? ""
            let script = "window.__mdLoadEditor && window.__mdLoadEditor(\(EditorHTML.jsStringLiteral(markdown)), \(EditorHTML.jsStringLiteral(baseHref)))"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, error != nil else { return }
                self.loadEditorPage(markdown: markdown,
                                    includesMermaid: needsMermaid,
                                    assetBaseURL: self.currentAssetBaseURL)
            }
            return
        }
        loadEditorPage(markdown: markdown,
                       includesMermaid: needsMermaid,
                       assetBaseURL: currentAssetBaseURL)
    }

    private func loadEditorPage(markdown: String,
                                includesMermaid: Bool,
                                assetBaseURL: URL?) {
        hasLoadedEditorPage = false
        pageSupportsMermaid = includesMermaid
        webView.loadHTMLString(
            Self.editorHTML(markdown: markdown,
                            includesMermaid: includesMermaid,
                            assetBaseURL: assetBaseURL),
            baseURL: nil
        )
    }

    /// Mirror the preview's page zoom so the type size and measure don't
    /// jump when toggling edit mode. CSS pixels scale with pageZoom, so
    /// the 900px column and the body gutters track the preview exactly.
    func applyPageZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
    }

    /// Rewrites the theme override `<style>` so a color edited in Settings
    /// restyles an open editor live. Fresh loads embed the same CSS in
    /// `editorHTML`.
    func applyThemeColors() {
        updateUnderPageBackgroundColor()
        updateObscuredContentInsets()
        let script = ThemeColorsSetting.styleUpdateScript(
            css: ThemeColorsSetting.current.editorOverrideCSS
        )
        webView.evaluateJavaScript(script) { _, _ in }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The under-page color is resolved statically; re-resolve on the
        // first pass and whenever the effective appearance flips.
        let appearanceName = view.effectiveAppearance.name
        if appearanceName != lastUnderPageAppearance {
            lastUnderPageAppearance = appearanceName
            updateUnderPageBackgroundColor()
        }
        updateObscuredContentInsets()
    }

    private var lastUnderPageAppearance: NSAppearance.Name?

    override func viewDidAppear() {
        super.viewDidAppear()
        // The chrome (toolbar, accessories) is final here; layout passes
        // before it attaches see a smaller contentLayoutRect.
        updateObscuredContentInsets()
        observeWindowChrome()
    }

    /// The formatting bar overlaying this editor (a content-view sibling,
    /// not a titlebar accessory — see DocumentWindowController.editBar).
    /// The page padding must clear it like any other chrome.
    weak var formattingBar: NSView? {
        didSet {
            guard formattingBar !== oldValue else { return }
            updateObscuredContentInsets()
        }
    }

    /// The find bar overlay (permanent, toggled by isHidden) — like the
    /// formatting bar, it hangs below the titlebar over this editor.
    weak var findOverlay: NSView?

    /// Reapplies the page padding; the window controller calls this when
    /// the find overlay is shown or hidden.
    func chromeOverlaysDidChange() {
        updateObscuredContentInsets()
    }

    private var contentLayoutObservation: NSKeyValueObservation?

    /// Titlebar chrome can change without this view getting a layout pass —
    /// the native tab bar appears when another document joins the window's
    /// tab group — so the padding follows contentLayoutRect directly. The
    /// observation only reads state and reapplies the page padding: forcing
    /// layout from here re-enters the layout pass that changed the rect and
    /// breaks the edit-mode reveal machinery.
    private func observeWindowChrome() {
        guard let window = view.window else {
            contentLayoutObservation = nil
            return
        }
        guard contentLayoutObservation == nil else { return }
        contentLayoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateObscuredContentInsets()
            }
        }
    }

    /// The whole obscured strip — titlebar, toolbar, tab bar, visible
    /// bottom accessories, and the formatting bar overlay.
    /// contentLayoutRect already excludes the titlebar chrome, so the gap
    /// alone is that chrome's height; adding accessory heights on top
    /// double-counted them and left a blank band below the formatting bar.
    private var fullChromeTopInset: CGFloat {
        guard let window = view.window, let contentView = window.contentView else {
            return view.safeAreaInsets.top
        }
        // Whether contentLayoutRect excludes a bottom accessory depends on
        // its scroll-edge style: .hard reserves layout, .automatic floats
        // over the content. Measure the real bottom edge of every visible
        // accessory instead of assuming either, so the buffer always lays
        // out below the lowest piece of chrome.
        var gap = contentView.bounds.height - window.contentLayoutRect.maxY
        if MainSplitViewController.usesNativeChromeAccessories {
            // See ContentViewController.fullChromeTopInset: the safe area
            // lags accessory changes by a layout pass, so measure the bars.
            gap += MainSplitViewController.nativeAccessoryHeight(findOverlay, in: window)
            gap += MainSplitViewController.nativeAccessoryHeight(formattingBar, in: window)
            return max(0, gap)
        }
        for accessory in window.titlebarAccessoryViewControllers
        where accessory.layoutAttribute == .bottom && !accessory.isHidden
            && accessory.view.window === window {
            let rect = contentView.convert(accessory.view.bounds, from: accessory.view)
            gap = max(gap, contentView.bounds.height - rect.minY)
        }
        // The formatting bar and find overlay are content-view chrome
        // hanging directly below the titlebar, so contentLayoutRect never
        // accounts for them. fittingSize instead of the frame: the frame is
        // unresolved between install and the next layout pass, and forcing
        // layout from here would re-enter the pass that called us. With a
        // visible tab bar the stack tucks up into the tab bar's margin
        // (MainSplitViewController.formattingBarTabBarOverlap), so that
        // amount comes back off once.
        var overlays: CGFloat = 0
        if let bar = formattingBar, bar.window === window, !bar.isHidden {
            overlays += bar.fittingSize.height
        }
        if let find = findOverlay, find.window === window, !find.isHidden {
            overlays += find.fittingSize.height
        }
        if overlays > 0 {
            gap += overlays
            gap -= MainSplitViewController.tabBarOverlap(for: window)
        }
        return max(0, gap)
    }

    /// On macOS 26 and later, page scrolling lets WebKit supply the native
    /// backdrop across the toolbar and visible chrome rows.
    private func updateObscuredContentInsets() {
        guard #available(macOS 26.0, *), view.window != nil else { return }
        let inset = fullChromeTopInset
        if webView.obscuredContentInsets.top != inset {
            webView.obscuredContentInsets = NSEdgeInsets(
                top: inset, left: 0, bottom: 0, right: 0
            )
        }
    }

    /// See ContentViewController.updateUnderPageBackgroundColor — set on
    /// theme changes only, never per layout pass.
    private func updateUnderPageBackgroundColor() {
        guard #available(macOS 26.0, *) else { return }
        // Resolved statically: WebKit serializes this color to the web
        // process, and a dynamic provider resolved there loses the theme
        // values — the toolbar strip then falls back to the stock editor
        // dark. applyThemeColors and appearance changes re-run this.
        let isDark = view.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme: ThemeColorScheme = isDark ? .dark : .light
        let colors = ThemeColorsSetting.current
        webView.underPageBackgroundColor = colors.color(.editorBackground, scheme)
            ?? colors.color(.windowBackground, scheme)
            ?? ThemeColorsSetting.defaultColor(.editorBackground, scheme)
    }

    /// Current buffer contents, or nil if the editor isn't ready.
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor ? window.__mdEditor.getMarkdown() : null") { value, _ in
            completion(value as? String)
        }
    }

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        findCompletion = completion
        let script = "window.__mdEditor?.find(\(EditorHTML.jsStringLiteral(query)), \(backwards), \(mode == .beginsWith))"
        webView.evaluateJavaScript(script) { result, _ in
            guard let result = result as? [String: Any],
                  let index = result["index"] as? Int,
                  let total = result["total"] as? Int else {
                completion?(.none)
                return
            }
            completion?(FindResult(top: nil, bottom: nil, index: index, total: total))
        }
    }

    func focusEditor() {
        view.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.focus()") { _, _ in }
    }

    /// Applies a normalized preview scroll position after CodeMirror has
    /// measured its own scrollable document. The JS promise resolves after a
    /// paint frame so the editor can be revealed at the final position.
    func applyScrollProgress(_ progress: CGFloat,
                             sourceAnchor: SourceScrollAnchor?,
                             completion: @escaping () -> Void) {
        let clamped = min(max(progress, 0), 1)
        let arguments: [String: Any] = [
            "progress": Double(clamped),
            "sourcePosition": sourceAnchor.map { Double($0.sourcePosition) } ?? NSNull(),
            "sourceGap": sourceAnchor.map { Double($0.topGap) } ?? 0,
        ]
        webView.callAsyncJavaScript(
            """
            if (!window.__mdEditor) return false;
            return await window.__mdEditor.setScrollPosition(progress, sourcePosition, sourceGap);
            """,
            arguments: arguments,
            in: nil,
            in: .page
        ) { _ in
            completion()
        }
    }

    func fetchScrollAnchor(_ completion: @escaping (SourceScrollAnchor?) -> Void) {
        webView.evaluateJavaScript(
            "window.__mdEditor && window.__mdEditor.getScrollAnchor()"
        ) { result, _ in
            completion(SourceScrollAnchor(scriptResult: result))
        }
    }

    /// Run a formatting command (bold, italic, h1, quote, …) on the
    /// current selection. Command names map to the bundle's exec() table.
    func exec(_ command: String) {
        let name = EditorHTML.jsStringLiteral(command)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.exec(\(name))") { _, _ in }
    }

    func insertMarkdown(_ markdown: String,
                        from: Int,
                        to: Int,
                        completion: ((Bool) -> Void)? = nil) {
        let script = """
        (() => {
            if (!window.__mdEditor) return false;
            window.__mdEditor.insertTextAt(\(EditorHTML.jsStringLiteral(markdown)), \(from), \(to));
            return true;
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            completion?(error == nil && (result as? Bool) == true)
        }
    }

    /// Replaces the source after an image rename without rebuilding the page,
    /// preserving the editor's selection and scroll position.
    func replaceMarkdown(_ markdown: String) {
        let script = "window.__mdEditor && window.__mdEditor.replaceMarkdown(\(EditorHTML.jsStringLiteral(markdown)))"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    fileprivate func handle(message: Any) {
        if let message = message as? String {
            switch message {
            case "dirty":
                hasChanges = true
                contentDidChange?()
            case "ready":
                hasLoadedEditorPage = true
                // Fresh page — the bar padding lives in the DOM and must be
                // re-applied even when the tracked value hasn't changed,
                // and WebKit re-derives the under-page color from the new
                // page, clobbering the themed value.
                updateUnderPageBackgroundColor()
                updateObscuredContentInsets()
                editorDidBecomeReady?()
            case "cancel":
                cancelRequested?()
            case let error where error.hasPrefix("error:"):
                NSLog("Markdown editor JavaScript error: %@", error)
            default:
                break
            }
            return
        }

        guard let payload = message as? [String: Any],
              let kind = payload["kind"] as? String else { return }
        switch kind {
        case "findResult":
            guard let index = payload["index"] as? Int,
                  let total = payload["total"] as? Int else { return }
            findCompletion?(FindResult(top: nil, bottom: nil, index: index, total: total))
        case "pasteImage":
            guard let from = payload["from"] as? NSNumber,
                  let to = payload["to"] as? NSNumber else { return }
            pasteImageRequested?(from.intValue, to.intValue)
        case "imageClick":
            guard let source = payload["src"] as? String,
                  let url = URL(string: source),
                  let boundary = currentContainmentRoot ?? currentAssetBaseURL,
                  let fileURL = MarkdownAssetResolution.fileURL(
                      for: url,
                      containedIn: boundary
                  ) else { return }
            imageClicked?(fileURL)
        case "tableContextMenu":
            presentTableContextMenu(payload)
        default:
            break
        }
    }

    private func presentTableContextMenu(_ payload: [String: Any]) {
        guard let token = payload["token"] as? String else { return }
        let context = TableContextMenuPresenter.Context(
            canInsertRowAbove: (payload["canInsertRowAbove"] as? NSNumber)?.boolValue ?? false,
            canDuplicateRow: (payload["canDuplicateRow"] as? NSNumber)?.boolValue ?? false,
            canDeleteRow: (payload["canDeleteRow"] as? NSNumber)?.boolValue ?? false,
            canDeleteColumn: (payload["canDeleteColumn"] as? NSNumber)?.boolValue ?? false,
            showsDuplicateRow: (payload["showsDuplicateRow"] as? NSNumber)?.boolValue ?? false
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let presenter = TableContextMenuPresenter(context: context) { [weak self] operation in
                guard let self else { return }
                let script = "window.__mdEditor && window.__mdEditor.performTableContextAction(\(EditorHTML.jsStringLiteral(token)), \(EditorHTML.jsStringLiteral(operation)))"
                self.webView.evaluateJavaScript(script) { _, _ in }
            }
            presenter.present(in: self.webView)
        }
    }

    // MARK: - Page assembly

    private static func vendorResource(_ name: String, ext: String, subdir: String) -> String? {
        // Synced-folder resources are copied flat into Resources/, so try
        // the subdirectory first and fall back to the bundle root — same
        // lookup MarkdownHTML uses for its vendor files.
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static let editorJavaScript =
        vendorResource("mdedit.min", ext: "js", subdir: "Vendor/CodeMirror") ?? ""
    private static let mermaidJavaScript =
        vendorResource("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") ?? ""

    private static func containsMermaidFence(in markdown: String) -> Bool {
        markdown.range(
            of: #"(?im)^[ \t]{0,3}(?:`{3,}|~{3,})[ \t]*mermaid(?:[ \t]|$)"#,
            options: .regularExpression
        ) != nil
    }

    private static func editorHTML(markdown: String,
                                   includesMermaid: Bool,
                                   assetBaseURL: URL?) -> String {
        // Baked into the base stylesheet, not only the override element:
        // WebKit derives the obscured-inset fill from the base stylesheet's
        // html/body background, so a theme color only present in the later
        // override <style> leaves the toolbar strip on stock Canvas (dark
        // #1e1e1e) in edit mode.
        let colors = ThemeColorsSetting.current
        func pageBackground(_ scheme: ThemeColorScheme) -> String {
            let hex = colors.hexValue(.editorBackground, scheme)
                ?? colors.hexValue(.windowBackground, scheme)
            return MarkdownHTML.ThemeOverrides.sanitizedHexColor(hex) ?? "Canvas"
        }
        let lightPageBackground = pageBackground(.light)
        let darkPageBackground = pageBackground(.dark)
        let usesPageScrolling: Bool
        if #available(macOS 26.0, *) {
            usesPageScrolling = true
        } else {
            usesPageScrolling = false
        }
        return EditorHTML.render(
            markdown: markdown,
            editorJavaScript: editorJavaScript,
            mermaidJavaScript: includesMermaid ? mermaidJavaScript : nil,
            assetBaseURL: assetBaseURL,
            configuration: .init(
                fullWidth: ContentWidthSetting.current == .fullWidth,
                lightPageBackground: lightPageBackground,
                darkPageBackground: darkPageBackground,
                themeOverrideCSS: colors.editorOverrideCSS,
                usesPageScrolling: usesPageScrolling,
                bridgeName: EditorBridge.name
            )
        )
    }
}

private final class EditorBridge: NSObject, WKScriptMessageHandler {
    static let name = "mdEditorHost"
    weak var owner: EditorViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == EditorBridge.name else { return }
        owner?.handle(message: message.body)
    }
}

private final class EditorWKWebView: WKWebView {
    // Left clicks in the transparent titlebar strip stay native (window
    // drag) instead of being consumed by WebKit — see ChromeStripClickThrough.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if declinesChromeStripClick(at: point) { return nil }
        return super.hitTest(point)
    }
}
