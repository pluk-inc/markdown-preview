//
//  MarkdownHTML.swift
//  md-preview
//

import CoreGraphics
import Foundation
import Markdown

// Pure string transforms — no UI state — so the whole namespace runs off
// the main actor. This lets MarkdownWebView.display dispatch the render
// to a concurrent task instead of stalling the main thread on large docs.
nonisolated enum MarkdownHTML {
    /// How the heavy KaTeX/Mermaid bundles are delivered.
    /// - inline: bundles are embedded as `<script>…</script>` blocks in the
    ///   HTML. Self-contained, used by Quick Look (which delivers HTML as a
    ///   single QLPreviewReply payload). The heavy scripts sit at body-end
    ///   behind an early populate call (see `VendorEmission`) so document
    ///   text paints before the bundles parse.
    /// - lazy: only small init stubs are inline; the heavy vendor JS is
    ///   fetched via `md-asset:///__vendor/<file>` after first paint, so the
    ///   document text is visible while the bundles are still parsing.
    enum VendorLoading {
        case inline
        case lazy
    }

    /// A vendor renderer's contribution to the document, split by insertion
    /// point. In `.inline` mode only the CSS stays in `head` (so layout is
    /// stable from the first paint — no FOUC when the renderer decorates the
    /// article later) while the multi-megabyte `<script>` bundles move to
    /// `body`, after the article and an early populate call. That lets the
    /// parser paint the document text before it grinds through the vendor
    /// JS — `.inline`'s answer to `.lazy`'s deferred fetch. `.lazy` emissions
    /// keep everything in `head`, byte-identical to the pre-split output.
    struct VendorEmission {
        var head: String = ""
        var body: String = ""
    }

    /// Layout of the rendered article column.
    /// - centered: capped at `contentColumnWidth` and centered by CSS auto
    ///   margins, so wide windows read like a paged document. Quick Look,
    ///   whose full-bleed panel minus the body gutters is exactly one
    ///   column.
    /// - hostCentered: capped at `contentColumnWidth` but anchored to the
    ///   leading gutter; the app centers the column by *positioning* the
    ///   web view (see ContentViewController.loadView). Anchoring keeps the
    ///   column glued to the web view's leading edge so host-driven width
    ///   changes never re-center it asynchronously (#162), while the web
    ///   view's trailing edge reaches the window for the native scrollbar.
    /// - full: span the whole window.
    enum ContentWidth {
        case centered
        case hostCentered
        case full
    }

    /// Native appearance supplied by hosts whose WebKit media-query result
    /// can disagree with the surface they render into (notably Quick Look).
    enum ColorScheme: String {
        case light
        case dark
    }

    /// id of the `<style>` element carrying user theme overrides. Emitted at
    /// render time and rewritten in place by the host when the user edits a
    /// color, so a live page restyles without a reload.
    static let themeStyleElementID = "mdp-theme-overrides"

    /// User color overrides injected after the stylesheet. Values are
    /// sanitized hex colors — anything else is dropped, never emitted —
    /// so stored strings can't break out of the style element.
    struct ThemeOverrides: Equatable, Sendable {
        var lightCodeBackground: String?
        var darkCodeBackground: String?
        /// Page (window background) overrides. Painted by the page itself —
        /// not only the native view behind it — so WebKit's scroll-edge
        /// pocket under a transparent titlebar frosts with the theme color.
        var lightPageBackground: String?
        var darkPageBackground: String?
        /// Body text (`--text`) overrides.
        var lightText: String?
        var darkText: String?
        /// Link (`--link`) overrides — the theme's primary accent.
        var lightLink: String?
        var darkLink: String?

        /// "#RRGGBB" (or #RRGGBBAA), or nil for anything else.
        static func sanitizedHexColor(_ value: String?) -> String? {
            guard let value,
                  value.range(
                    of: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",
                    options: .regularExpression
                  ) != nil else { return nil }
            return value
        }

        /// Override rules mirroring the stylesheet's three palette buckets:
        /// bare `:root` (light), the host color-scheme attribute (Quick
        /// Look), and the media query (app windows following the system).
        var css: String {
            var rules: [String] = []
            if let light = Self.sanitizedHexColor(lightCodeBackground) {
                rules.append(":root { --code-bg: \(light); }")
            }
            if let dark = Self.sanitizedHexColor(darkCodeBackground) {
                rules.append(":root[data-mdp-color-scheme=\"dark\"] { --code-bg: \(dark); }")
                rules.append("""
                @media (prefers-color-scheme: dark) {
                    :root:not([data-mdp-color-scheme="light"]) { --code-bg: \(dark); }
                }
                """)
            }
            if let light = Self.sanitizedHexColor(lightText) {
                rules.append(":root { --text: \(light); }")
            }
            if let dark = Self.sanitizedHexColor(darkText) {
                rules.append(":root[data-mdp-color-scheme=\"dark\"] { --text: \(dark); }")
                rules.append("""
                @media (prefers-color-scheme: dark) {
                    :root:not([data-mdp-color-scheme="light"]) { --text: \(dark); }
                }
                """)
            }
            if let light = Self.sanitizedHexColor(lightLink) {
                rules.append(":root { --link: \(light); }")
            }
            if let dark = Self.sanitizedHexColor(darkLink) {
                rules.append(":root[data-mdp-color-scheme=\"dark\"] { --link: \(dark); }")
                rules.append("""
                @media (prefers-color-scheme: dark) {
                    :root:not([data-mdp-color-scheme="light"]) { --link: \(dark); }
                }
                """)
            }
            if let light = Self.sanitizedHexColor(lightPageBackground) {
                rules.append("html { background: \(light); }")
            }
            if let dark = Self.sanitizedHexColor(darkPageBackground) {
                rules.append(":root[data-mdp-color-scheme=\"dark\"] { background: \(dark); }")
                rules.append("""
                @media (prefers-color-scheme: dark) {
                    html:not([data-mdp-color-scheme="light"]) { background: \(dark); }
                }
                """)
            }
            guard !rules.isEmpty else { return "" }
            // Scoped to screen so the print stylesheet's forced-light
            // palette is never overridden — dark theme text on white paper
            // printed nearly invisible otherwise.
            return "@media screen {\n" + rules.joined(separator: "\n") + "\n}"
        }
    }

    /// Width the Quick Look panel requests for its preview window.
    static let preferredPageWidth: CGFloat = 900
    /// The centered article measure: `preferredPageWidth` minus the 40px
    /// body gutter on either side, so the app's centered column and the
    /// Quick Look panel wrap lines identically.
    static let contentColumnWidth = Int(preferredPageWidth) - 80

    // Shared reading/editing design tokens. The two surfaces intentionally
    // keep different renderers, but their page geometry and base typography
    // must come from one source of truth.
    static let bodyFontFamily = "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, sans-serif"
    static let codeFontFamily = "ui-monospace, \"SF Mono\", Menlo, monospace"
    static let bodyFontSize: CGFloat = 15
    static let bodyLineHeight: CGFloat = 1.52
    static let pagePaddingTop: CGFloat = 32
    static let pagePaddingHorizontal: CGFloat = 40
    static let pagePaddingBottom: CGFloat = 48
    static let sourceLineHeight = bodyFontSize * bodyLineHeight

    /// Exported PDFs opt out of the paper-specific restyling below so the
    /// print pipeline paginates the same read-only page shown on screen.
    static let previewPrintClass = "md-preview-print-fidelity"

    /// The only export-specific print adjustments are mechanical: move the
    /// read-only page padding into a real page margin so every PDF page gets
    /// the same gutters, retain the same content measure, and paint the
    /// otherwise-transparent WebKit page with the active Canvas color. The
    /// print operation then fits that complete column to the selected paper
    /// instead of reflowing it at the narrower print viewport.
    static let previewPrintOverrideCSS = """
    @media print {
        @page {
            margin: \(Int(pagePaddingTop))px \(Int(pagePaddingHorizontal))px \(Int(pagePaddingBottom))px;
        }
        html.\(previewPrintClass),
        html.\(previewPrintClass) body {
            background: Canvas;
        }
        html.\(previewPrintClass) body {
            box-sizing: border-box;
            width: \(contentColumnWidth)px;
            padding: 0;
        }
        /* The figure clips an absolutely-positioned stage, so a page break
           through it discards everything past the break. */
        html.\(previewPrintClass) .mermaid-figure {
            break-inside: avoid;
        }
    }
    """

    /// Body size, in points, used by the print stylesheet when the app hasn't
    /// injected an explicit choice. CSS `pt` reaches paper 1:1, so this is the
    /// literal printed size. The on-screen 15px body prints at 15 × 0.75 =
    /// 11.25pt, so 12pt keeps the default output close to what it was before
    /// the size became selectable.
    static let defaultPrintPointSize = 12

    /// Printed page box. WKWebView ignores `NSPrintInfo`'s margins and falls
    /// back to its own 1in default, so these are the only knob. The top is
    /// deliberately smaller than the sides: the first line of every page adds
    /// roughly 20pt of its own leading above the glyphs, so equal margins make
    /// the top read as a much deeper gap than the sides.
    static let printPageMarginTop = "0.5in"
    static let printPageMarginSide = "0.75in"
    static let printPageMarginBottom = "0.6in"

    // Block margin-top tokens. The editor bundle receives these through
    // MDEditor.create's `spacing` option so both surfaces space blocks
    // identically — change them here, never in entry-cm.js.
    static let paragraphSpacing = bodyFontSize * 0.8
    /// Height of the final blank line in a run of authored blanks. A single
    /// blank between paragraphs then reads as blankLineGap + paragraphSpacing
    /// (≈16px), matching the paragraph rhythm of other Markdown renderers,
    /// while every additional authored blank still grows the gap by a full
    /// source line.
    static let blankLineGap: CGFloat = 4
    static let quoteSpacing = bodyFontSize * 1.2
    static let largeBlockSpacing = bodyFontSize * 1.6  // alerts, tables, mermaid
    /// hr margin-top only. The rule carries no margin-bottom: the following
    /// block's own margin-top provides the space below, so the gaps above and
    /// below a rule both equal the paragraph gap (blankLineGap + this).
    static let hrSpacing = bodyFontSize * 0.8
    static let listItemSpacing = bodyFontSize * 0.4

    struct RenderedHTML: Sendable {
        let html: String
        let articleHTML: String
        let containsMath: Bool
        let containsMermaid: Bool
        let containsCode: Bool
    }

    static func makeHTML(from markdown: String,
                         allowsScroll: Bool = false,
                         assetBaseHref: String? = nil,
                         vendorLoading: VendorLoading = .inline,
                         colorScheme: ColorScheme? = nil,
                         documentFont: DocumentFontSetting = .current) -> String {
        render(markdown: markdown,
               allowsScroll: allowsScroll,
               assetBaseHref: assetBaseHref,
               vendorLoading: vendorLoading,
               colorScheme: colorScheme,
               documentFont: documentFont).html
    }

    static func render(markdown: String,
                       allowsScroll: Bool = false,
                       assetBaseHref: String? = nil,
                       vendorLoading: VendorLoading = .inline,
                       contentWidth: ContentWidth = .centered,
                       colorScheme: ColorScheme? = nil,
                       themeOverrides: ThemeOverrides? = nil,
                       documentFont: DocumentFontSetting = .current,
                       warmup: Bool = false) -> RenderedHTML {
        let frontmatter = MarkdownFrontmatter.split(markdown)
        let body = frontmatter.body
        let sourceLineOffset: Int
        if frontmatter.raw != nil,
           let bodyRange = markdown.range(of: body, options: .backwards) {
            sourceLineOffset = markdown[..<bodyRange.lowerBound].count(where: \.isNewline)
        } else {
            sourceLineOffset = 0
        }
        let footnotes = extractFootnotes(from: body)
        let math = extractMath(from: footnotes.markdown)
        let formatted = EscapingHTMLFormatter.format(
            math.processedMarkdown,
            sourceLineOffset: sourceLineOffset,
            sourceMarkdown: body
        )
        let mermaidResult = renderMermaidBlocks(in: formatted)
        let mathResult = renderMathBlocks(in: mermaidResult.html, with: math)
        let footnoteReferenceHTML = renderFootnoteReferences(in: mathResult.html, with: footnotes)
        let footnoteDefinitions = renderFootnoteDefinitions(
            footnotes,
            sourceLineOffset: sourceLineOffset
        )
        let headingsHTML = injectHeadingIDs(in: footnoteReferenceHTML + footnoteDefinitions.html)
        // Direction inference scans every rendered block. Most documents
        // contain no RTL text, so avoid walking the much larger generated
        // HTML unless the Markdown could produce an RTL first character.
        let renderedBodyHTML = sourceMayNeedRTLDirection(body)
            ? injectRTLDirection(in: headingsHTML)
            : headingsHTML
        let frontmatterHTML: String
        if let raw = frontmatter.raw,
           let format = frontmatter.format {
            frontmatterHTML = renderFrontmatter(
                raw,
                format: format,
                sourceEndLine: sourceLineOffset
            )
        } else {
            frontmatterHTML = ""
        }
        let bodyHTML = frontmatterHTML + renderedBodyHTML
        let containsMath = mathResult.containsMath || footnoteDefinitions.containsMath
        let containsMermaid = mermaidResult.containsMermaid || footnoteDefinitions.containsMermaid
        let containsCode = detectHighlightableCode(in: bodyHTML)
        let scrollOverride = allowsScroll ? """
        <style>
        html { overflow: auto !important; }
        body { overflow: visible !important; }
        </style>
        """ : ""
        let contentWidthOverride: String
        switch contentWidth {
        case .centered:
            contentWidthOverride = ""
        case .hostCentered:
            contentWidthOverride = """
            <style>
            article.markdown-body { margin-left: 0; }
            </style>
            """
        case .full:
            contentWidthOverride = """
            <style>
            article.markdown-body { max-width: none; }
            </style>
            """
        }
        // Headings inherit the family deliberately: the heading scale is a
        // ratio off the body em, tuned against one x-height, so keeping system
        // headings over a serif body would silently change how big each step
        // looks. Code keeps its own face and takes only a size correction.
        let documentFontOverride = """
        <style>
        :root {
            --mdp-doc-font: \(documentFont.fontFamily);
            --mdp-code-font-size: \(documentFont.codeFontSize);
        }
        </style>
        """

        // The href may carry a real folder path (percent-encoded, but `&`
        // and `'` survive URL path encoding) — escape it for the attribute.
        let baseTag = assetBaseHref.map {
            let escaped = $0
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            return "<base href=\"\(escaped)\">"
        } ?? ""
        let sanitizerBlock = dompurifyBlock
        let morphBlock = morphdomBlock
        let mathBlock = containsMath ? katexHead(mode: vendorLoading) : VendorEmission()
        let mermaidBlock = containsMermaid ? mermaidScript(mode: vendorLoading) : VendorEmission()
        let highlightBlock = containsCode ? highlightHead(mode: vendorLoading) : VendorEmission()
        // Inline documents populate the article as soon as its <template> has
        // parsed — before the body-end vendor bundles below it — so the text
        // is paintable while the parser is still working through the JS. The
        // vendor init IIFEs still see readyState 'loading' at body-end and
        // keep their DOMContentLoaded wiring; `populateFromTemplate` removes
        // the template, so the later `start()` populate is a no-op. Under
        // `.lazy` every emission's body is empty and the populate hook is
        // skipped, keeping the app-path body unchanged.
        let earlyPopulate = vendorLoading == .inline
            ? "<script>window.MdPreview && MdPreview.populateNow && MdPreview.populateNow();</script>"
            : ""
        let bodyParts = [earlyPopulate, mathBlock.body, mermaidBlock.body, highlightBlock.body]
            .filter { !$0.isEmpty }
        let bodyScripts = bodyParts.isEmpty ? "" : "\n" + bodyParts.joined(separator: "\n")
        // Warmup keeps the article in layout (so Mermaid's IntersectionObserver
        // still fires and the renderer actually executes) but invisible —
        // otherwise the synthetic diagram flashes on screen before the first
        // real document arrives. `MdPreview.update` clears the inline style.
        let articleStyle = warmup
            ? " style=\"opacity:0;pointer-events:none\""
            : ""
        let warmupAttr = warmup ? " data-warmup=\"1\"" : ""
        // Article body is delivered inside an inert <template> element rather
        // than inlined into <article>. WebKit parses <template> contents into
        // a DocumentFragment with a separate owner document — scripts don't
        // execute, images don't fetch, and event-handler attributes never fire.
        // The bootstrap then reads template.innerHTML, runs it through
        // DOMPurify, and assigns the sanitized result to article.innerHTML.
        let safeBody = bodyHTML.replacingOccurrences(of: "</template", with: "<\\/template")
        let colorSchemeAttribute = colorScheme.map {
            " data-mdp-color-scheme=\"\($0.rawValue)\""
        } ?? ""
        // Always emitted (possibly empty) so a live theme edit has a stable
        // element to rewrite instead of creating one per page variant.
        let themeStyleBlock =
            "<style id=\"\(themeStyleElementID)\">\(themeOverrides?.css ?? "")</style>"
        let html = """
        <!DOCTYPE html>
        <html\(colorSchemeAttribute)>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(baseTag)
        <style>\(stylesheet)</style>
        \(themeStyleBlock)
        \(scrollOverride)
        \(contentWidthOverride)
        \(documentFontOverride)
        \(sanitizerBlock)
        \(morphBlock)
        \(hostBridgeScript)
        \(mathBlock.head)
        \(mermaidBlock.head)
        \(highlightBlock.head)
        </head>
        <body>
        <article class="markdown-body"\(warmupAttr)\(articleStyle)></article>
        <template id="md-article-source">\(safeBody)</template>\(bodyScripts)
        </body>
        </html>
        """
        return RenderedHTML(
            html: html,
            articleHTML: bodyHTML,
            containsMath: containsMath,
            containsMermaid: containsMermaid,
            containsCode: containsCode
        )
    }

    private static let headingTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "<h([1-6])([^>]*)>")
    }()

    private static func injectHeadingIDs(in html: String) -> String {
        let nsHtml = html as NSString
        let matches = headingTagRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return html }

        var result = ""
        result.reserveCapacity(html.count + matches.count * 24)
        var cursor = 0

        for (index, match) in matches.enumerated() {
            let level = nsHtml.substring(with: match.range(at: 1))
            let attributes = nsHtml.substring(with: match.range(at: 2))
            let prefix = nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            result += prefix
            result += "<h\(level)\(attributes) id=\"md-heading-\(index)\">"
            cursor = match.range.location + match.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }


}
