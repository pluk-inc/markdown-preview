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

    private(set) var hasChanges = false

    private var webView: WKWebView!
    private let bridge = EditorBridge()
    private var hasLoadedEditorPage = false
    private var pageSupportsMermaid = false

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: EditorBridge.name)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        bridge.owner = self
        self.webView = webView
        view = webView
    }

    func load(markdown: String) {
        hasChanges = false
        let needsMermaid = Self.containsMermaidFence(in: markdown)
        if hasLoadedEditorPage, pageSupportsMermaid || !needsMermaid {
            let script = "window.__mdLoadEditor && window.__mdLoadEditor(\(Self.jsStringLiteral(markdown)))"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, error != nil else { return }
                self.loadEditorPage(markdown: markdown, includesMermaid: needsMermaid)
            }
            return
        }
        loadEditorPage(markdown: markdown, includesMermaid: needsMermaid)
    }

    private func loadEditorPage(markdown: String, includesMermaid: Bool) {
        hasLoadedEditorPage = false
        pageSupportsMermaid = includesMermaid
        webView.loadHTMLString(
            Self.editorHTML(markdown: markdown, includesMermaid: includesMermaid),
            baseURL: nil
        )
    }

    /// Mirror the preview's page zoom so the type size and measure don't
    /// jump when toggling edit mode. CSS pixels scale with pageZoom, so
    /// the 900px column and the body gutters track the preview exactly.
    func applyPageZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
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
        ]
        webView.callAsyncJavaScript(
            """
            if (!window.__mdEditor) return false;
            return await window.__mdEditor.setScrollPosition(progress, sourcePosition);
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
            guard let raw = result as? [String: Any],
                  let position = raw["position"] as? NSNumber else {
                completion(nil)
                return
            }
            completion(SourceScrollAnchor(
                sourcePosition: CGFloat(truncating: position)
            ))
        }
    }

    /// Run a formatting command (bold, italic, h1, quote, …) on the
    /// current selection. Command names map to the bundle's exec() table.
    func exec(_ command: String) {
        let name = Self.jsStringLiteral(command)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.exec(\(name))") { _, _ in }
    }

    fileprivate func handle(message: Any) {
        if let message = message as? String {
            switch message {
            case "dirty":
                hasChanges = true
                contentDidChange?()
            case "ready":
                hasLoadedEditorPage = true
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
              payload["kind"] as? String == "tableContextMenu" else { return }
        presentTableContextMenu(payload)
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

    private static func editorHTML(markdown: String, includesMermaid: Bool) -> String {
        // Honor the preview's content-width setting: Normal caps the
        // column at the preview's measure, Full Width spans the window.
        let columnMaxWidth = ContentWidthSetting.current == .fullWidth
            ? "none"
            : "\(MarkdownHTML.contentColumnWidth)px"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <style>
        /* Palette and type scale mirror MarkdownHTML.stylesheet so entering
           edit mode doesn't visually change the document. */
        :root {
            color-scheme: light dark;
            --text: #1d1d1f;
            --secondary: #6e6e73;
            --link: #0066cc;
            --quote-border: #d2d2d7;
            --code-bg: #f5f5f7;
            --grid: #d2d2d7;
            /* GitHub Light — matches the preview's highlight.js theme. */
            --hl-keyword: #d73a49;
            --hl-string: #032f62;
            --hl-comment: #6a737d;
            --hl-number: #005cc5;
            --hl-type: #6f42c1;
            --hl-function: #6f42c1;
            --hl-property: #005cc5;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --text: #f5f5f7;
                --secondary: #86868b;
                --link: #2997ff;
                --quote-border: #6e6e73;
                --code-bg: #2A2828;
                --grid: #424245;
                /* GitHub Dark — matches the preview's highlight.js theme. */
                --hl-keyword: #ff7b72;
                --hl-string: #a5d6ff;
                --hl-comment: #8b949e;
                --hl-number: #79c0ff;
                --hl-type: #d2a8ff;
                --hl-function: #d2a8ff;
                --hl-property: #79c0ff;
            }
        }
        html, body {
            margin: 0;
            padding: 0;
            height: 100%;
            overflow: hidden;
            background: Canvas;
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
        }
        #editor .cm-line {
            padding: 0;
        }
        #editor .cm-line[dir="rtl"] { text-align: right; }
        #editor .cm-line[dir="ltr"] { text-align: left; }
        #editor .cm-selectionBackground,
        #editor .cm-focused .cm-selectionBackground {
            /* Match WebKit's native selection tint in read-only mode. */
            background: Highlight !important;
        }

        /* Headings — preview's scale, padding instead of margin so
           CodeMirror's per-line height measurement stays exact.
           Every line-level rule needs the #editor prefix to outrank
           `#editor .cm-line { padding: 0 }` above. */
        #editor .cm-md-h1, #editor .cm-md-h2, #editor .cm-md-h3,
        #editor .cm-md-h4, #editor .cm-md-h5, #editor .cm-md-h6 {
            font-weight: 600;
            line-height: 1.18;
            padding-top: 1.6em;
            /* Preview pushes the block after a heading down by its
               0.8em margin-top (12px at body size); mirror it here. */
            padding-bottom: \(MarkdownHTML.paragraphSpacing)px;
        }
        #editor .cm-md-h1 { font-size: 2em; padding-top: 0.8em; }
        /* The preview preserves a source blank line before a heading as one
           line box and suppresses the heading margin. Mirror that exact
           height instead of substituting the heading's larger top spacing. */
        #editor .cm-md-heading-after-blank {
            padding-top: \(MarkdownHTML.sourceLineHeight)px;
        }
        /* Mirror the preview's first-child margin reset so the document
           starts at the same height in both modes. */
        #editor .cm-content > .cm-line:first-child { padding-top: 0; }
        #editor .cm-md-h2 { font-size: 1.88em; line-height: 1.06; }
        #editor .cm-md-h3 { font-size: 1.65em; line-height: 1.07; }
        #editor .cm-md-h4 { font-size: 1.41em; line-height: 1.08; }
        #editor .cm-md-h5 { font-size: 1.29em; line-height: 1.09; }
        #editor .cm-md-h6 { font-size: 1em; line-height: 1.24; }
        /* A rendered heading's top margin already represents the blank source
           line before it. Do not count that source line a second time. */
        #editor .cm-md-blank-before-heading {
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
        #editor .cm-md-heading-inactive {
            transform: translateX(calc(-1 * var(--cm-md-heading-prefix-width, 0px)));
        }
        #editor .cm-line[dir="rtl"].cm-md-heading-inactive {
            transform: translateX(var(--cm-md-heading-prefix-width, 0px));
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

        #editor .cm-md-quote {
            border-inline-start: 4px solid var(--quote-border);
            padding-inline-start: 1em;
            color: var(--secondary);
        }
        .cm-md-strong { font-weight: 600; }
        .cm-md-emphasis { font-style: italic; }
        .cm-md-strikethrough { text-decoration: line-through; }
        .cm-md-inline-code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
            background: var(--code-bg);
            border-radius: 6px;
            padding: 0.18em 0.42em;
        }
        .cm-md-link { color: var(--link); }
        .cm-md-url { color: var(--secondary); }
        .cm-md-bullet { color: var(--secondary); }
        .cm-md-hr {
            display: inline-block;
            width: 100%;
            border-top: 1px solid var(--grid);
            vertical-align: middle;
        }
        #editor .cm-md-codeblock {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.88em;
            line-height: 1.45;
            /* CodeMirror paints full-document selection below content. Retain
               the code-card surface while allowing that selection tint to
               remain clearly visible through selected code. */
            background: color-mix(in srgb, var(--code-bg) 50%, transparent);
            padding: 0 14px;
        }
        #editor .cm-md-codeblock-first {
            border-radius: 15px 15px 0 0;
            padding-top: 10px;
        }
        #editor .cm-md-codeblock-last {
            border-radius: 0 0 15px 15px;
            padding-bottom: 10px;
        }
        #editor .cm-md-code-fence-source-hidden {
            visibility: hidden;
        }
        .cm-md-fence-info { color: var(--secondary); }
        .cm-md-mermaid-preview {
            margin: 10px 0;
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
            margin: 10px 0;
            max-width: 100%;
            overflow: visible;
            font-family: (MarkdownHTML.bodyFontFamily);
            font-size: (MarkdownHTML.bodyFontSize)px;
            line-height: (MarkdownHTML.bodyLineHeight);
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
            min-height: calc((MarkdownHTML.bodyFontSize)px * (MarkdownHTML.bodyLineHeight));
            padding: 8px 10px;
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
            outline: 2px solid #007aff;
            outline-offset: -2px;
            background: color-mix(in srgb, #007aff 8%, transparent);
        }
        .cm-md-table-cell.is-table-part-selected {
            --table-selection-top-edge: 0 0 transparent;
            --table-selection-right-edge: 0 0 transparent;
            --table-selection-bottom-edge: 0 0 transparent;
            --table-selection-left-edge: 0 0 transparent;
            background: color-mix(in srgb, #007aff 14%, Canvas);
            box-shadow:
                var(--table-selection-top-edge),
                var(--table-selection-right-edge),
                var(--table-selection-bottom-edge),
                var(--table-selection-left-edge);
        }
        .cm-md-table-cell.is-table-selection-top {
            --table-selection-top-edge: inset 0 1px color-mix(in srgb, #007aff 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-right {
            --table-selection-right-edge: inset -1px 0 color-mix(in srgb, #007aff 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-bottom {
            --table-selection-bottom-edge: inset 0 -1px color-mix(in srgb, #007aff 52%, transparent);
        }
        .cm-md-table-cell.is-table-selection-left {
            --table-selection-left-edge: inset 1px 0 color-mix(in srgb, #007aff 52%, transparent);
        }
        .hl-keyword { color: var(--hl-keyword); }
        .hl-string { color: var(--hl-string); }
        .hl-comment { color: var(--hl-comment); }
        .hl-number { color: var(--hl-number); }
        .hl-type { color: var(--hl-type); }
        .hl-function { color: var(--hl-function); }
        .hl-property { color: var(--hl-property); }
        .hl-meta { color: var(--secondary); }
        </style>
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
            window.onerror = function (message) { post("error: " + message); };
            let editor = null;
            window.__mdLoadEditor = function (markdown) {
                if (editor) editor.destroy();
                editor = window.MDEditor.create(
                    document.getElementById("editor"),
                    markdown,
                    { onDirty: function () { post("dirty"); } }
                );
                window.__mdEditor = {
                    getMarkdown: function () { return editor.getMarkdown(); },
                    getScrollAnchor: function () { return editor.getScrollAnchor(); },
                    focus: function () { editor.focus(); },
                    setScrollPosition: function (progress, sourcePosition) {
                        return editor.setScrollPosition(progress, sourcePosition);
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
            window.__mdLoadEditor(\(jsStringLiteral(markdown)));
        })();
        </script>
        </body>
        </html>
        """
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
