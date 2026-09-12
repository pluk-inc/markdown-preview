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

    func load(markdown: String, assetBaseURL: URL? = nil, containmentRoot: URL? = nil) {
        hasChanges = false
        currentAssetBaseURL = assetBaseURL?.standardizedFileURL
        currentContainmentRoot = containmentRoot?.standardizedFileURL
        assetScheme.setBaseURL(currentAssetBaseURL)
        assetScheme.setContainmentRoot(currentContainmentRoot)
        let needsMermaid = Self.containsMermaidFence(in: markdown)
        if hasLoadedEditorPage, pageSupportsMermaid || !needsMermaid {
            let baseHref = currentAssetBaseURL.map(MarkdownAssetResolution.baseHref(forFolder:)) ?? ""
            let script = "window.__mdLoadEditor && window.__mdLoadEditor(\(Self.jsStringLiteral(markdown)), \(Self.jsStringLiteral(baseHref)))"
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
        let name = Self.jsStringLiteral(command)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.exec(\(name))") { _, _ in }
    }

    func insertMarkdown(_ markdown: String,
                        from: Int,
                        to: Int,
                        completion: ((Bool) -> Void)? = nil) {
        let script = """
        (() => {
            if (!window.__mdEditor) return false;
            window.__mdEditor.insertTextAt(\(Self.jsStringLiteral(markdown)), \(from), \(to));
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
        let script = "window.__mdEditor && window.__mdEditor.replaceMarkdown(\(Self.jsStringLiteral(markdown)))"
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
                let script = "window.__mdEditor && window.__mdEditor.performTableContextAction(\(Self.jsStringLiteral(token)), \(Self.jsStringLiteral(operation)))"
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

    /// JSON string literal safe for embedding in an inline <script>:
    /// `<` is escaped so `</script>` inside the document can't close the tag.
    private static func jsStringLiteral(_ string: String) -> String {
        let data = (try? JSONEncoder().encode([string])) ?? Data("[\"\"]".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003c")
    }

    private static func editorHTML(markdown: String,
                                   includesMermaid: Bool,
                                   assetBaseURL: URL?) -> String {
        // Honor the preview's content-width setting: Normal caps the
        // column at the preview's measure, Full Width spans the window.
        let columnMaxWidth = ContentWidthSetting.current == .fullWidth
            ? "none"
            : "\(MarkdownHTML.contentColumnWidth)px"
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
        return """
        <!DOCTYPE html>
        <html data-page-scrolling="\(usesPageScrolling)">
        <head>
        <meta charset="UTF-8">
        \(assetBaseURL.map { "<base href=\"\(htmlAttributeLiteral(MarkdownAssetResolution.baseHref(forFolder: $0)))\">" } ?? "")
        <style>
        /* Palette and type scale mirror MarkdownHTML.stylesheet so entering
           edit mode doesn't visually change the document. */
        :root {
            color-scheme: light dark;
            /* Semantic system colors resolve per appearance on their own. */
            --text: -apple-system-label;
            --secondary: -apple-system-secondary-label;
            --quote-border: -apple-system-quaternary-label;
            --grid: -apple-system-separator;
            --accent: -apple-system-control-accent;
            --link: rgb(0, 104, 218);
            --code-bg: #f9f9f9;
            --code-border: #f0f0f0;
            /* Same code palette as the preview stylesheet. */
            --hl-keyword: #9b2393;
            --hl-string: #c41a16;
            --hl-comment: #5d6c79;
            --hl-number: #1c00cf;
            --hl-type: #3900a0;
            --hl-function: #326d74;
            --hl-property: #326d74;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --link: rgb(65, 156, 255);
                --code-bg: #262626;
                --code-border: #323232;
                --hl-keyword: #fc5fa3;
                --hl-string: #fc6a5d;
                --hl-comment: #6c7986;
                --hl-number: #d0bf69;
                --hl-type: #d0a8ff;
                --hl-function: #67b7a4;
                --hl-property: #67b7a4;
            }
        }
        html, body {
            margin: 0;
            padding: 0;
            height: 100%;
            overflow: hidden;
            background: \(lightPageBackground);
        }
        @media (prefers-color-scheme: dark) {
            html, body { background: \(darkPageBackground); }
        }
        body {
            font-family: \(MarkdownHTML.bodyFontFamily);
            font-size: \(MarkdownHTML.bodyFontSize)px;
            line-height: \(MarkdownHTML.bodyLineHeight);
            color: var(--text);
            -webkit-font-smoothing: antialiased;
        }
        #editor {
            height: 100%;
            box-sizing: border-box;
        }
        .cm-editor { height: 100%; outline: none; }
        .cm-editor.cm-focused { outline: none; }
        /* CodeMirror injects its base theme into <head> at runtime — after
           this block — and it sets .cm-scroller to monospace. Win on
           specificity (#editor), not on order. */
        #editor .cm-scroller {
            overflow: auto;
            /* Keep page gutters outside the editable content column. */
            padding-inline: \(MarkdownHTML.pagePaddingHorizontal)px;
            box-sizing: border-box;
            font-family: \(MarkdownHTML.bodyFontFamily) !important;
            font-size: \(MarkdownHTML.bodyFontSize)px;
            line-height: \(MarkdownHTML.bodyLineHeight);
        }
        #editor .cm-content {
            width: 100%;
            max-width: \(columnMaxWidth);
            min-height: 100%;
            margin: 0 auto;
            padding: \(MarkdownHTML.pagePaddingTop)px 0 \(MarkdownHTML.pagePaddingBottom)px;
            box-sizing: border-box;
            caret-color: var(--text);
            cursor: text;
            /* A flex column keeps WebKit from painting the native selection
               across the gaps between lines, so a selection follows the text
               like the preview. Lines carry padding, never margins, so the
               layout is unchanged. */
            display: flex;
            flex-direction: column;
            align-items: stretch;
        }
        #editor .cm-line {
            padding: 0;
        }
        #editor .cm-line[dir="rtl"] { text-align: right; }
        #editor .cm-line[dir="ltr"] { text-align: left; }

        /* Headings — preview's scale, padding instead of margin so
           CodeMirror's per-line height measurement stays exact.
           Every line-level rule needs the #editor prefix to outrank
           `#editor .cm-line { padding: 0 }` above. */
        #editor .cm-md-h1, #editor .cm-md-h2, #editor .cm-md-h3,
        #editor .cm-md-h4, #editor .cm-md-h5, #editor .cm-md-h6 {
            font-weight: 600;
            line-height: 1.25;
            padding-top: calc(0.6rem + 0.5em);
        }
        #editor .cm-md-h1 { font-size: 2em; }
        /* Mirror the preview's first-child margin reset so the document
           starts at the same height in both modes. */
        #editor .cm-content > .cm-line:first-child { padding-top: 0; }
        #editor .cm-md-h2 { font-size: 1.692em; }
        #editor .cm-md-h3 { font-size: 1.308em; }
        #editor .cm-md-h4 { font-size: 1.154em; }
        #editor .cm-md-h5 { font-size: 1em; }
        #editor .cm-md-h6 { font-size: 0.846em; }
        /* A visible source blank already owns the gap before the heading;
           retain the preview's small amount of extra breathing room. */
        #editor .cm-md-h1.cm-md-heading-after-blank,
        #editor .cm-md-h2.cm-md-heading-after-blank,
        #editor .cm-md-h3.cm-md-heading-after-blank,
        #editor .cm-md-h4.cm-md-heading-after-blank,
        #editor .cm-md-h5.cm-md-heading-after-blank,
        #editor .cm-md-h6.cm-md-heading-after-blank {
            padding-top: 4px;
        }
        /* A source line whose height another element owns collapses to
           nothing: inactive code fence lines (the card transfers their
           styling to the code lines), and a single blank opening the
           document. Blank separators before other blocks resize instead —
           .cm-md-block-separator lines carry an inline height matching the
           preview margin of the block that follows. Additional blank lines
           keep their natural height in both surfaces. */
        #editor .cm-md-line-collapsed {
            height: 0;
            min-height: 0;
            line-height: 0;
            overflow: hidden;
        }

        /* Hidden heading syntax still occupies its exact inline width.
           Revealing it on the active line therefore cannot rewrap the line. */
        #editor .cm-md-heading-source-hidden {
            visibility: hidden;
        }
        /* Pull only the first line back by the hidden prefix width, so the
           visible text starts at the column edge and wrapped lines start
           there too. A transform would shift every line of a long heading. */
        #editor .cm-md-heading-inactive {
            text-indent: calc(-1 * var(--cm-md-heading-prefix-width, 0px));
        }
        /* Setext underline source remains editable, but Markdown consumes its
           physical line when rendering the heading. Collapse that line and
           paint the marker into the heading's existing bottom spacing so the
           following block starts at the same vertical position as preview. */
        #editor .cm-md-setext-marker-line {
            position: relative;
            height: 0;
            min-height: 0;
            line-height: 0;
            overflow: visible;
        }
        #editor .cm-md-setext-source {
            position: absolute;
            inset-inline-start: 0;
            top: 0;
            font-size: \(MarkdownHTML.bodyFontSize)px;
            line-height: \(MarkdownHTML.bodyLineHeight);
            color: var(--secondary);
            white-space: pre;
        }

        /* The bundle sets the depth-dependent start padding and one 4px
           rule per nesting level as background images (positions inline).
           The rule stops above the block gap the bundle adds when another
           block follows the quotation without a blank line. */
        #editor .cm-md-quote {
            padding-inline-end: 1em;
            color: var(--secondary);
            background-repeat: no-repeat;
            background-size: 4px calc(100% - var(--cm-md-block-gap, 0px));
        }
        .cm-md-strong { font-weight: 600; }
        .cm-md-emphasis { font-style: italic; }
        .cm-md-strikethrough { text-decoration: line-through; }
        .cm-md-highlight {
            background: rgba(255, 216, 77, 0.55);
            border-radius: 2px;
            box-decoration-break: clone;
            -webkit-box-decoration-break: clone;
        }
        .cm-md-inline-code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.9em;
            background: var(--code-bg);
            border: 0.5px solid var(--code-border);
            border-radius: 5px;
            padding: 0.15em 0.3em;
        }
        .cm-md-link { color: var(--link); }
        .cm-md-url { color: var(--secondary); }
        .cm-md-image-preview {
            display: inline-flex;
            max-width: 100%;
            flex-direction: column;
            align-items: flex-start;
            vertical-align: middle;
            cursor: pointer;
        }
        .cm-md-image-preview img {
            display: block;
            max-width: 100%;
            max-height: 70vh;
            object-fit: contain;
            border-radius: 8px;
        }
        .cm-md-image-preview.cm-md-image-error img {
            display: none;
        }
        .cm-md-image-source {
            display: none;
            max-width: 100%;
            margin-top: 4px;
            padding: 3px 6px;
            overflow-wrap: anywhere;
            color: var(--secondary);
            background: color-mix(in srgb, var(--code-bg) 82%, transparent);
            border-radius: 4px;
            cursor: text;
            white-space: pre-wrap;
        }
        .cm-md-image-preview:hover .cm-md-image-source,
        .cm-md-image-preview:focus-within .cm-md-image-source {
            display: block;
        }
        /* Mirror the preview's list geometry. JavaScript adds an inline
           padding value derived from semantic list depth, rather than relying
           on proportional-font source spaces. The marker hangs inside the
           final 2.1em step, so active and inactive item text stays aligned. */
        #editor .cm-md-list-item {
            padding-inline-start: 2.1em;
            text-indent: -2.1em;
        }
        .cm-md-bullet {
            display: inline-block;
            width: 2.1em;
            text-indent: 0;
            text-align: end;
            padding-inline-end: 0.5em;
            box-sizing: border-box;
            /* The glyph keeps its box for alignment but renders transparent;
               the ::after circle below matches the preview's painted bullet. */
            color: transparent;
            position: relative;
        }
        .cm-md-bullet::after {
            content: "";
            position: absolute;
            /* Match the preview's 0.5em gap between the circle and the
               item text. */
            inset-inline-end: 0.5em;
            top: 50%;
            transform: translateY(-50%);
            width: 0;
            height: 0;
            border: 0.2em solid var(--accent);
            border-radius: 50%;
        }
        /* Keep the active raw "- " marker in the same hanging box as the
           inactive bullet widget. Revealing Markdown source must not move the
           item text or make a nested item appear to change indentation. */
        .cm-md-bullet-source {
            display: inline-block;
            width: 2.1em;
            text-indent: 0;
            text-align: end;
            padding-inline-end: 0.5em;
            box-sizing: border-box;
            color: var(--secondary);
        }
        /* Ordered markers share the bullet's hanging box: right-aligned,
           tabular digits, accent color; the active source marker keeps the
           same box so item text never moves. */
        .cm-md-ordered,
        .cm-md-ordered-source {
            display: inline-block;
            width: 2.1em;
            text-indent: 0;
            text-align: end;
            padding-inline-end: 0.5em;
            box-sizing: border-box;
            font-variant-numeric: tabular-nums;
        }
        .cm-md-ordered { color: var(--accent); }
        .cm-md-ordered-source { color: var(--secondary); }
        /* Continuation lines of an item keep the depth padding but no hanging
           indent, so they align with the item text like the preview. */
        #editor .cm-md-list-continuation {
            text-indent: 0 !important;
        }
        /* Preview list items after the first carry a margin-top. */
        #editor .cm-md-list-item-gap {
            padding-top: \(MarkdownHTML.listItemSpacing)px;
        }
        .cm-md-hr {
            display: inline-block;
            width: 100%;
            border-top: 1px solid var(--grid);
            vertical-align: middle;
        }
        #editor .cm-md-codeblock {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 1em;
            line-height: 1.3;
            position: relative;
            padding: 0 16px;
        }
        /* The code card is painted on a z:-2 pseudo instead of the line
           itself, so it matches the preview's opaque --code-bg and never
           covers the native selection or the caret. */
        #editor .cm-md-codeblock::before {
            content: "";
            position: absolute;
            inset: 0;
            z-index: -2;
            background: var(--code-bg);
        }
        #editor .cm-content > .cm-line.cm-md-codeblock-first {
            padding-top: 16px;
            position: relative;
        }
        #editor .cm-md-codeblock-first::before {
            border-radius: 8px 8px 0 0;
        }
        #editor .cm-md-codeblock-last {
            padding-bottom: 16px;
        }
        #editor .cm-md-codeblock-last::before {
            border-radius: 0 0 8px 8px;
        }
        /* A single content line owns both ends of the card. */
        #editor .cm-md-codeblock-first.cm-md-codeblock-last::before {
            border-radius: 8px;
        }
        /* Reserve a header row so the language never competes with code,
           including wrapped lines and blocks at the start of a document. */
        #editor .cm-content > .cm-line.cm-md-codeblock-first:has(.cm-md-code-language) {
            padding-top: 36px;
        }
        #editor .cm-md-code-fence-source-hidden {
            visibility: hidden;
        }
        #editor .cm-md-code-language {
            position: absolute;
            inset-inline-start: 7px;
            max-width: calc(100% - 21px);
            top: 9px;
            z-index: 1;
            line-height: 1;
            white-space: nowrap;
        }
        #editor .cm-md-code-language-input {
            width: 14em;
            max-width: 100%;
            min-width: 4.5em;
            box-sizing: border-box;
            padding: 2px 6px;
            border: 1px solid transparent;
            border-radius: 5px;
            background: transparent;
            color: var(--secondary);
            font-family: system-ui, -apple-system, sans-serif;
            font-size: 0.8em;
            line-height: 1.35;
            outline: none;
        }
        #editor .cm-md-code-language-input::placeholder {
            color: var(--secondary);
            opacity: 0.8;
        }
        #editor .cm-md-code-language-input:hover {
            color: var(--text);
        }
        #editor .cm-md-code-language-input:focus {
            background: color-mix(in srgb, var(--text) 4%, var(--code-bg));
            color: var(--text);
            border-color: var(--grid);
            caret-color: var(--link);
            box-shadow: none;
        }
        /* Frontmatter — a quiet metadata card above the document, echoing
           the preview's properties panel. YAML stays editable; only the
           --- delimiters are dimmed. */
        #editor .cm-md-frontmatter {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.82em;
            line-height: 1.6;
            color: var(--secondary);
            background: color-mix(in srgb, var(--code-bg) 50%, transparent);
            padding: 0 14px;
        }
        /* Outranks the `.cm-line:first-child { padding-top: 0 }` reset so
           the card keeps its inset when it opens the document. */
        #editor .cm-content > .cm-line.cm-md-frontmatter-first {
            border-radius: 15px 15px 0 0;
            padding-top: 8px;
        }
        #editor .cm-md-frontmatter-last {
            border-radius: 0 0 15px 15px;
            padding-bottom: 8px;
        }
        .cm-md-frontmatter-delim {
            opacity: 0.45;
        }
        .cm-md-fence-info { color: var(--secondary); }
        .cm-md-mermaid-preview {
            /* Outer spacing comes from the block separator lines, matching
               the preview's .mermaid-figure margin. */
            margin: 0;
            padding: 20px;
            border-radius: 15px;
            background: var(--code-bg);
            cursor: text;
            box-sizing: border-box;
        }
        .cm-md-mermaid-stage {
            display: flex;
            justify-content: center;
            min-height: 48px;
            color: var(--secondary);
        }
        .cm-md-mermaid-stage svg {
            display: block;
            max-width: 100%;
            height: auto;
        }
        .cm-md-mermaid-error {
            border: 1px solid color-mix(in srgb, #d1242f 45%, transparent);
        }
        .cm-md-table {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
        }
        .cm-md-table-widget {
            position: relative;
            width: fit-content;
            /* Outer spacing comes from the block separator lines, matching
               the preview's .md-table-scroll margin. */
            margin: 0;
            max-width: 100%;
            overflow: visible;
            font-family: \(MarkdownHTML.bodyFontFamily);
            font-size: \(MarkdownHTML.bodyFontSize)px;
            line-height: \(MarkdownHTML.bodyLineHeight);
        }
        .cm-md-table-widget:focus {
            outline: none;
        }
        .cm-md-table-scroll {
            width: fit-content;
            max-width: 100%;
            overflow-x: auto;
        }
        .cm-md-table-grid {
            width: 100%;
            border-collapse: collapse;
            table-layout: auto;
        }
        .cm-md-table-grid th,
        .cm-md-table-grid td {
            min-width: 72px;
            padding: 0;
            border-top: 1px solid var(--grid);
            border-bottom: 1px solid var(--grid);
            text-align: left;
            vertical-align: top;
        }
        .cm-md-table-grid th {
            font-weight: 600;
            background: color-mix(in srgb, Canvas 94%, var(--grid));
        }
        .cm-md-table-cell {
            min-height: calc(\(MarkdownHTML.bodyFontSize)px * \(MarkdownHTML.bodyLineHeight));
            padding: 8px 12px;
            outline: none;
            white-space: pre-wrap;
            overflow-wrap: anywhere;
            cursor: text;
        }
        .cm-md-table-grid th .cm-md-table-cell[data-placeholder]:empty::before {
            content: attr(data-placeholder);
            color: var(--secondary);
            font-weight: 400;
            opacity: 0.72;
            pointer-events: none;
        }
        .cm-md-table-cell:focus {
            outline: 2px solid var(--accent);
            outline-offset: -2px;
            background: color-mix(in srgb, var(--accent) 8%, transparent);
        }
        .cm-md-table-cell.is-table-part-selected {
            --table-selection-top-edge: 0 0 transparent;
            --table-selection-right-edge: 0 0 transparent;
            --table-selection-bottom-edge: 0 0 transparent;
            --table-selection-left-edge: 0 0 transparent;
            background: color-mix(in srgb, var(--accent) 14%, Canvas);
            box-shadow:
                var(--table-selection-top-edge),
                var(--table-selection-right-edge),
                var(--table-selection-bottom-edge),
                var(--table-selection-left-edge);
        }
        .cm-md-table-cell.is-table-selection-top {
            --table-selection-top-edge: inset 0 1px color-mix(in srgb, var(--accent) 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-right {
            --table-selection-right-edge: inset -1px 0 color-mix(in srgb, var(--accent) 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-bottom {
            --table-selection-bottom-edge: inset 0 -1px color-mix(in srgb, var(--accent) 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-left {
            --table-selection-left-edge: inset 1px 0 color-mix(in srgb, var(--accent) 52%, transparent);
        }
        /* Page scrolling lets WebKit own the native toolbar backdrop.
           The macOS 15 editor keeps its internal scroller. */
        html[data-page-scrolling="true"],
        html[data-page-scrolling="true"] body {
            height: auto;
            overflow: visible;
        }
        html[data-page-scrolling="true"] #editor,
        html[data-page-scrolling="true"] .cm-editor { height: auto; }
        html[data-page-scrolling="true"] #editor .cm-scroller { overflow: visible; }
        .hl-keyword { color: var(--hl-keyword); }
        .hl-string { color: var(--hl-string); }
        .hl-comment { color: var(--hl-comment); }
        .hl-number { color: var(--hl-number); }
        .hl-type { color: var(--hl-type); }
        .hl-function { color: var(--hl-function); }
        .hl-property { color: var(--hl-property); }
        .hl-meta { color: var(--secondary); }
        </style>
        <style id="\(MarkdownHTML.themeStyleElementID)">\(ThemeColorsSetting.current.editorOverrideCSS)</style>
        </head>
        <body>
        <div id="editor"></div>
        \(includesMermaid ? "<script>\(mermaidJavaScript)</script>" : "")
        \(includesMermaid ? """
        <script>
        if (window.mermaid) {
            window.mermaid.initialize({
                startOnLoad: false,
                securityLevel: "strict",
                theme: window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default"
            });
        }
        </script>
        """ : "")
        <script>\(editorJavaScript)</script>
        <script>
        (function () {
            const post = function (m) {
                try { window.webkit.messageHandlers.\(EditorBridge.name).postMessage(m); } catch (e) {}
            };
            window.__mdRequestTableContextMenu = function (details) {
                post(Object.assign({ kind: "tableContextMenu" }, details));
            };
            window.__mdRequestImageRename = function (src) {
                post({ kind: "imageClick", src: src });
            };
            window.onerror = function (message) { post("error: " + message); };
            let editor = null;
            window.__mdLoadEditor = function (markdown, baseHref) {
                let base = document.querySelector("head > base");
                if (baseHref) {
                    if (!base) {
                        base = document.createElement("base");
                        document.head.prepend(base);
                    }
                    base.setAttribute("href", baseHref);
                } else if (base) {
                    base.remove();
                }
                if (editor) editor.destroy();
                editor = window.MDEditor.create(
                    document.getElementById("editor"),
                    markdown,
                    {
                        pageScrolling: \(usesPageScrolling),
                        onDirty: function () { post("dirty"); },
                        onPasteImage: function (from, to) {
                            post({ kind: "pasteImage", from: from, to: to });
                        },
                        // Preview block margins (MarkdownHTML design tokens):
                        // the bundle sizes blank-separator lines from these.
                        spacing: {
                            line: \(MarkdownHTML.sourceLineHeight),
                            blankGap: \(MarkdownHTML.blankLineGap),
                            paragraph: \(MarkdownHTML.paragraphSpacing),
                            quote: \(MarkdownHTML.quoteSpacing),
                            alert: \(MarkdownHTML.largeBlockSpacing),
                            table: \(MarkdownHTML.largeBlockSpacing),
                            hr: \(MarkdownHTML.hrSpacing)
                        }
                    }
                );
                window.__mdEditor = {
                    getMarkdown: function () { return editor.getMarkdown(); },
                    replaceMarkdown: function (markdown) { return editor.replaceMarkdown(markdown); },
                    getScrollAnchor: function () { return editor.getScrollAnchor(); },
                    focus: function () { editor.focus(); },
                    setScrollPosition: function (progress, sourcePosition, sourceGap) {
                        return editor.setScrollPosition(progress, sourcePosition, sourceGap);
                    },
                    insertTextAt: function (text, from, to) {
                        return editor.insertTextAt(text, from, to);
                    },
                    performTableContextAction: function (token, action) {
                        return editor.performTableContextAction(token, action);
                    },
                    exec: function (name) { editor.exec(name); }
                };
                requestAnimationFrame(function () { post("ready"); });
            };
            document.addEventListener("keydown", function (e) {
                if (e.key === "Escape" && !e.defaultPrevented) post("cancel");
            });
            window.__mdLoadEditor(\(jsStringLiteral(markdown)), \(jsStringLiteral(assetBaseURL.map { MarkdownAssetResolution.baseHref(forFolder: $0) } ?? "")));
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func htmlAttributeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
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
