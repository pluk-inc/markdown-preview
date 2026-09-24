// The production editor page, shared with the WebKit layout tests.
import Foundation

nonisolated enum EditorHTML {
    /// Space reserved for the editable language control above fenced code.
    static let codeLanguageHeaderHeight: CGFloat = 28

    struct Configuration {
        var fullWidth = false
        var lightPageBackground = "transparent"
        var darkPageBackground = "transparent"
        var themeOverrideCSS = ""
        var usesPageScrolling = false
        var bridgeName = "mdEditorHost"
    }

    static func render(markdown: String,
                       editorJavaScript: String,
                       mermaidJavaScript: String? = nil,
                       assetBaseURL: URL? = nil,
                       configuration: Configuration = Configuration()) -> String {
        let columnMaxWidth = configuration.fullWidth ? "none" : "\(MarkdownHTML.contentColumnWidth)px"
        let lightPageBackground = configuration.lightPageBackground
        let darkPageBackground = configuration.darkPageBackground
        let usesPageScrolling = configuration.usesPageScrolling
        let includesMermaid = mermaidJavaScript != nil
        let mermaidJavaScript = mermaidJavaScript ?? ""
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
            \(MarkdownHTML.lightCodePaletteCSS)
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --link: rgb(65, 156, 255);
                --code-bg: #262626;
                --code-border: #323232;
                \(MarkdownHTML.darkCodePaletteCSS)
            }
        }
        html, body {
            margin: 0;
            padding: 0;
            height: 100%;
            overflow: hidden;
            overscroll-behavior-x: none;
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
            overflow-x: hidden;
            overflow-y: auto;
            overscroll-behavior-x: none;
            /* Keep page gutters outside the editable content column. */
            padding-inline: \(MarkdownHTML.pagePaddingHorizontal)px;
            /* Document clearance is outside contenteditable and scrolls
               away naturally; it must not be a fixed interaction shield. */
            padding-top: calc(\(MarkdownHTML.pagePaddingTop + (usesPageScrolling ? MarkdownHTML.appPageTopClearance : 0))px / var(--mdp-chrome-zoom, 1));
            cursor: default;
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
            padding: 0 0 \(MarkdownHTML.pagePaddingBottom)px;
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
        /* Hanging trailing spaces must not push the last word onto a new
           line. Match read-mode wrapping while preserving editable spaces. */
        #editor .cm-content.cm-lineWrapping { white-space: pre-wrap; }
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

        #editor .cm-md-heading-marker,
        #editor .cm-md-heading-marker * {
            color: var(--secondary);
        }

        /* Keep hidden syntax measurable for inactive heading alignment. */
        #editor .cm-md-heading-source-hidden {
            visibility: hidden;
        }
        /* Inactive heading text aligns with the document column;
           active headings show their prefix inline. */
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
        #editor .cm-content > .cm-line.cm-md-quote {
            padding-inline-end: 1em;
            padding-top: var(--cm-md-quote-top);
            padding-bottom: calc(var(--cm-md-quote-bottom) + var(--cm-md-block-gap, 0px));
            color: var(--secondary);
            background-repeat: no-repeat;
            background-size: 4px calc(100% - var(--cm-md-quote-top) - var(--cm-md-quote-bottom) - var(--cm-md-block-gap, 0px));
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
            overflow-wrap: anywhere;
            -webkit-box-decoration-break: clone;
            box-decoration-break: clone;
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
        /* A standalone image fills its line; aligning its top avoids the
           extra text-baseline space below CodeMirror's inline widget. */
        .cm-md-image-line .cm-md-image-preview {
            vertical-align: top;
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
            padding-inline-end: 0.75em;
            box-sizing: border-box;
            /* The glyph keeps its box for alignment but renders transparent;
               the ::after circle below matches the preview's painted bullet. */
            color: transparent;
            position: relative;
        }
        .cm-md-bullet::after {
            content: "";
            position: absolute;
            /* Match the preview's 0.75em gap between the circle and the
               item text. */
            inset-inline-end: 0.75em;
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
            padding-inline-end: 0.75em;
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
        #editor .cm-md-rule-line {
            height: 1px;
            min-height: 0;
            line-height: 0;
        }
        .cm-md-hr {
            display: inline-block;
            width: 100%;
            border-top: 1px solid var(--grid);
            vertical-align: top;
        }
        #editor .cm-md-code-card {
            position: relative;
            container-type: inline-size;
            display: grid;
            grid-template-columns: max-content;
            /* Classic horizontal scrollbars must not stretch the code rows
               or introduce a second scrollbar that shifts the sticky header. */
            grid-auto-rows: max-content;
            align-content: start;
            overflow-x: auto;
            overflow-y: hidden;
            border: 0.5px solid var(--code-border);
            border-radius: 16px;
            background: var(--code-bg);
        }
        #editor .cm-md-codeblock {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 1em;
            line-height: 1.3;
            position: relative;
            padding: 0;
            white-space: pre;
            min-width: 100cqw;
        }
        #editor .cm-md-code-scroll-text {
            display: inline-block;
            padding-inline: 16px;
        }
        #editor .cm-md-codeblock:not(.cm-md-code-wrapped):not(:has(.cm-md-code-scroll-text)) {
            box-sizing: border-box;
            padding-inline-start: 16px;
        }
        #editor .cm-md-codeblock:not(.cm-md-code-wrapped):not(:has(.cm-md-code-scroll-text)) .cm-md-code-language {
            margin-inline-start: -7px;
        }
        #editor .cm-md-codeblock-first { padding-top: 16px; }
        #editor .cm-md-codeblock-last { padding-bottom: 16px; }
        #editor .cm-md-codeblock-first:has(.cm-md-code-language) {
            padding-top: calc(16px + \(codeLanguageHeaderHeight)px);
        }
        #editor .cm-md-code-fence-source-hidden {
            visibility: hidden;
        }
        #editor .cm-md-code-language {
            /* Native sticky positioning keeps controls fixed during async
               scrolling, before JavaScript receives the scroll event. */
            position: sticky;
            /* Text starts at the same 16px inset as the read-only label:
               subtract the input's padding and 1px border. */
            inset-inline-start: 9px;
            margin-inline: 9px 10px;
            margin-top: calc(-8px - \(codeLanguageHeaderHeight)px);
            margin-bottom: 8px;
            width: calc(100cqw - 19px);
            height: 28px;
            display: flex;
            align-items: center;
            gap: 4px;
            cursor: default;
            z-index: 1;
            line-height: 1;
            white-space: nowrap;
        }
        #editor .cm-md-code-language-input {
            display: block;
            width: 14em;
            flex: 0 1 14em;
            margin-inline-end: auto;
            max-width: 100%;
            min-width: 4.5em;
            box-sizing: border-box;
            padding: 2px 6px;
            border: 1px solid transparent;
            border-radius: 5px;
            background: transparent;
            color: var(--secondary);
            font: 11px/14px -apple-system, BlinkMacSystemFont, sans-serif;
            outline: none;
        }
        #editor .cm-md-code-action {
            display: inline-flex; align-items: center; justify-content: center;
            flex: none; width: 28px; height: 28px; padding: 0;
            appearance: none; border: 0; border-radius: 50%;
            color: var(--secondary); background: transparent; cursor: pointer;
        }
        #editor .cm-md-code-action:hover { color: var(--text); background: color-mix(in srgb, var(--text) 10%, transparent); }
        #editor .cm-md-code-action:focus-visible { outline: 2px solid AccentColor; outline-offset: 1px; }
        #editor .cm-md-code-card-wrapped { grid-template-columns: minmax(0, 1fr); }
        #editor .cm-md-code-wrapped { min-width: 0; white-space: pre-wrap; overflow-wrap: anywhere; padding-inline: 16px; }
        #editor .cm-md-code-wrapped .cm-md-code-scroll-text { display: inline; padding-inline: 0; }
        #editor .cm-md-code-wrapped .cm-md-code-language { position: relative; inset-inline-start: auto; margin-inline: -7px; }
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
            position: relative;
            margin: 0 auto;
            width: 100%;
            --mm-max-height: min(70vh, 720px);
            max-width: calc(var(--mm-max-height) * (var(--mm-aspect, 4 / 3)));
            aspect-ratio: var(--mm-aspect, 4 / 3);
            max-height: var(--mm-max-height);
            overflow: hidden;
            border-radius: 15px;
            background: var(--code-bg);
            cursor: text;
            box-sizing: border-box;
        }
        .cm-md-mermaid-stage {
            position: absolute;
            inset: 0;
            padding: 16px;
            box-sizing: border-box;
            display: flex;
            align-items: center;
            justify-content: center;
            color: var(--secondary);
        }
        .cm-md-mermaid-stage svg {
            display: block;
            width: 100%;
            max-width: none !important;
            height: 100%;
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
        html[data-page-scrolling="true"] {
            overflow-x: hidden;
            overflow-y: auto;
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
        .hl-property { color: var(--hl-variable); }
        .hl-attribute { color: var(--hl-attribute); }
        .hl-builtin { color: var(--hl-builtin); }
        .hl-declaration { color: var(--hl-declaration); }
        .hl-meta { color: var(--hl-preprocessor); }
        .hl-plain { color: var(--hl-plain); }
        </style>
        <style id="\(MarkdownHTML.themeStyleElementID)">\(configuration.themeOverrideCSS)</style>
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
                try { window.webkit.messageHandlers.\(configuration.bridgeName).postMessage(m); } catch (e) {}
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
                        onCopyCode: function (text) { post({ kind: "copyCode", value: text }); },
                        onFormattingChange: function (state) {
                            post({ kind: "formattingState", heading: state.heading, commands: state.commands });
                        },
                        onSearchChange: function (result) {
                            post({ kind: "findResult", index: result.index, total: result.total });
                        },
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
                    find: function (query, backwards, beginsWith) {
                        return editor.find(query, backwards, beginsWith);
                    },
                    getMarkdown: function () { return editor.getMarkdown(); },
                    getHeadingLevel: function () { return editor.getHeadingLevel(); },
                    getListStyle: function () { return editor.getListStyle(); },
                    getBlockStyle: function () { return editor.getBlockStyle(); },
                    setBlockStyle: function (style, language) { return editor.setBlockStyle(style, language); },
                    setListStyle: function (style) { return editor.setListStyle(style); },
                    getLinkSelection: function (expandLink) { return editor.getLinkSelection(expandLink); },
                    select: function (anchor, head) { editor.select(anchor, head); },
                    insertLinkFromPopover: function (text, url, from, to) {
                        return editor.insertLinkFromPopover(text, url, from, to);
                    },
                    isSyntaxReady: function () { return editor.isSyntaxReady(); },
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

    /// JSON string literal safe for embedding in an inline <script>:
    /// `<` is escaped so `</script>` inside the document can't close the tag.
    static func jsStringLiteral(_ string: String) -> String {
        let data = (try? JSONEncoder().encode([string])) ?? Data("[\"\"]".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return String(json.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003c")
    }


    private static func htmlAttributeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
