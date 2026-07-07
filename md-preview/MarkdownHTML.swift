//
//  MarkdownHTML.swift
//  md-preview
//

import Foundation
import Markdown

// Pure string transforms — no UI state — so the whole namespace runs off
// the main actor. This lets MarkdownWebView.display dispatch the render
// to a concurrent task instead of stalling the main thread on large docs.
nonisolated enum MarkdownHTML {
    /// How the heavy KaTeX/Mermaid bundles are delivered.
    /// - inline: bundles are embedded as `<script>…</script>` blocks in the
    ///   HTML head. Self-contained, slow first-paint, used by Quick Look
    ///   (which delivers HTML as a single QLPreviewReply payload).
    /// - lazy: only small init stubs are inline; the heavy vendor JS is
    ///   fetched via `md-asset:///__vendor/<file>` after first paint, so the
    ///   document text is visible while the bundles are still parsing.
    enum VendorLoading {
        case inline
        case lazy
    }

    /// Layout of the rendered article column.
    /// - centered: capped at `contentColumnWidth` and centered, so wide
    ///   windows read like a paged document. Matches Quick Look, whose
    ///   `preferredPageWidth` panel minus the body gutters is exactly one
    ///   column.
    /// - full: span the whole window.
    enum ContentWidth {
        case centered
        case full
    }

    /// Width the Quick Look panel requests for its preview window.
    static let preferredPageWidth: CGFloat = 900
    /// The centered article measure: `preferredPageWidth` minus the 40px
    /// body gutter on either side, so the app's centered column and the
    /// Quick Look panel wrap lines identically.
    static let contentColumnWidth = Int(preferredPageWidth) - 80

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
                         vendorLoading: VendorLoading = .inline) -> String {
        render(markdown: markdown,
               allowsScroll: allowsScroll,
               assetBaseHref: assetBaseHref,
               vendorLoading: vendorLoading).html
    }

    static func render(markdown: String,
                       allowsScroll: Bool = false,
                       assetBaseHref: String? = nil,
                       vendorLoading: VendorLoading = .inline,
                       contentWidth: ContentWidth = .centered,
                       warmup: Bool = false) -> RenderedHTML {
        let body = MarkdownFrontmatter.split(markdown).body
        let footnotes = extractFootnotes(from: body)
        let math = extractMath(from: footnotes.markdown)
        let formatted = EscapingHTMLFormatter.format(math.processedMarkdown)
        let mermaidResult = renderMermaidBlocks(in: formatted)
        let mathResult = renderMathBlocks(in: mermaidResult.html, with: math)
        let footnoteReferenceHTML = renderFootnoteReferences(in: mathResult.html, with: footnotes)
        let footnoteDefinitions = renderFootnoteDefinitions(footnotes)
        let headingsHTML = injectHeadingIDs(in: footnoteReferenceHTML + footnoteDefinitions.html)
        let bodyHTML = injectRTLDirection(in: headingsHTML)
        let containsMath = mathResult.containsMath || footnoteDefinitions.containsMath
        let containsMermaid = mermaidResult.containsMermaid || footnoteDefinitions.containsMermaid
        let containsCode = detectHighlightableCode(in: bodyHTML)
        let scrollOverride = allowsScroll ? """
        <style>
        html, body { overflow: auto !important; }
        </style>
        """ : ""
        let contentWidthOverride = contentWidth == .full ? """
        <style>
        article.markdown-body { max-width: none; }
        </style>
        """ : ""
        let baseTag = assetBaseHref.map { "<base href=\"\($0)\">" } ?? ""
        let sanitizerBlock = dompurifyHead()
        let mathBlock = containsMath ? katexHead(mode: vendorLoading) : ""
        let mermaidBlock = containsMermaid ? mermaidScript(mode: vendorLoading) : ""
        let highlightBlock = containsCode ? highlightHead(mode: vendorLoading) : ""
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
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(baseTag)
        <style>\(stylesheet)</style>
        \(scrollOverride)
        \(contentWidthOverride)
        \(sanitizerBlock)
        \(hostBridgeScript)
        \(mathBlock)
        \(mermaidBlock)
        \(highlightBlock)
        </head>
        <body>
        <article class="markdown-body"\(warmupAttr)\(articleStyle)></article>
        <template id="md-article-source">\(safeBody)</template>
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
        try! NSRegularExpression(pattern: "<h([1-6])>")
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
            let prefix = nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            result += prefix
            result += "<h\(level) id=\"md-heading-\(index)\">"
            cursor = match.range.location + match.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }

    // MARK: - RTL Direction

    // Matches opening <p>, <li>, or <h1>-<h6> tags
    private static let rtlTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"<(p|li|h[1-6])(\s[^>]*)?>"#, options: [.caseInsensitive])
    }()

    private static let htmlTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"<[^>]+>"#)
    }()

    // RTL Unicode ranges: Hebrew, Arabic (+ supplements), Syriac, Thaana, N'Ko, Samaritan, Mandaic
    private static let rtlRanges: [ClosedRange<UInt32>] = [
        0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F,
        0x0780...0x07BF, 0x07C0...0x07FF, 0x0800...0x083F, 0x0840...0x085F,
        0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF
    ]

    private static func injectRTLDirection(in html: String) -> String {
        let nsHtml = html as NSString
        let matches = rtlTagRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        result.reserveCapacity(html.count + matches.count * 12)
        var cursor = 0

        for match in matches {
            result += nsHtml.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let tag = nsHtml.substring(with: match.range(at: 1))
            let attrs = match.range(at: 2).location != NSNotFound ? nsHtml.substring(with: match.range(at: 2)) : ""

            if attrs.lowercased().contains("dir=") {
                result += nsHtml.substring(with: match.range)
            } else {
                let contentStart = match.range.location + match.range.length
                let maxLookahead = min(300, nsHtml.length - contentStart)
                let contentPreview = nsHtml.substring(with: NSRange(location: contentStart, length: maxLookahead))
                let plainText = stripHTMLTags(contentPreview)

                if let first = firstStrongCharacter(in: plainText), isRTL(first) {
                    result += "<\(tag)\(attrs) dir=\"rtl\">"
                } else {
                    result += nsHtml.substring(with: match.range)
                }
            }
            cursor = match.range.location + match.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }

    private static func stripHTMLTags(_ html: String) -> String {
        let nsStr = html as NSString
        return htmlTagRegex.stringByReplacingMatches(
            in: html, range: NSRange(location: 0, length: nsStr.length), withTemplate: ""
        )
    }

    private static func firstStrongCharacter(in text: String) -> Character? {
        text.first { char in
            guard let scalar = char.unicodeScalars.first else { return false }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return false
            }
        }
    }

    private static func isRTL(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        return rtlRanges.contains { $0.contains(scalar.value) }
    }

    // MARK: - Footnotes

    private struct FootnoteExtraction {
        let markdown: String
        let definitions: [FootnoteDefinition]
        let references: [FootnoteReference]
    }

    private struct FootnoteDefinition {
        let key: String
        let label: String
        let content: String
        let number: Int
    }

    private struct FootnoteReference {
        let token: String
        let number: Int
        let ordinal: Int
    }

    private struct FootnoteDefinitionRenderResult {
        let html: String
        let containsMath: Bool
        let containsMermaid: Bool
    }

    private static let footnoteDefinitionRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^[ \t]{0,3}\[\^([^\]\n]+)\]:[ \t]*(.*)$"#)
    }()

    private static let footnoteReferenceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#)
    }()

    private static func extractFootnotes(from markdown: String) -> FootnoteExtraction {
        let split = splitFootnoteDefinitions(from: markdown)
        var protected: [String] = []

        let afterFences = replaceFullMatches(of: codeFenceRegex, in: split.markdown) { full in
            protected.append(full)
            return "MdPreviewFootnoteProtect\(protected.count - 1)Token"
        }
        let afterInlineCode = replaceFullMatches(of: inlineCodeRegex, in: afterFences) { full in
            protected.append(full)
            return "MdPreviewFootnoteProtect\(protected.count - 1)Token"
        }

        var orderedDefinitions: [FootnoteDefinition] = []
        var referenceOrdinalsByNumber: [Int: Int] = [:]
        var references: [FootnoteReference] = []

        let replacedReferences = replaceFootnoteReferenceMatches(in: afterInlineCode) { label, full in
            let key = normalizeFootnoteKey(label)
            guard let stored = split.definitions[key] else { return full }

            let definition: FootnoteDefinition
            if let existing = orderedDefinitions.first(where: { $0.key == key }) {
                definition = existing
            } else {
                definition = FootnoteDefinition(
                    key: key,
                    label: stored.label,
                    content: stored.content,
                    number: orderedDefinitions.count + 1
                )
                orderedDefinitions.append(definition)
            }

            let ordinal = (referenceOrdinalsByNumber[definition.number] ?? 0) + 1
            referenceOrdinalsByNumber[definition.number] = ordinal
            let token = "MdPreviewFootnoteRef\(references.count)Token"
            references.append(FootnoteReference(token: token, number: definition.number, ordinal: ordinal))
            return token
        }

        var restored = replacedReferences
        for (i, original) in protected.enumerated() {
            restored = restored.replacingOccurrences(
                of: "MdPreviewFootnoteProtect\(i)Token",
                with: original
            )
        }

        return FootnoteExtraction(
            markdown: restored,
            definitions: orderedDefinitions,
            references: references
        )
    }

    private static func splitFootnoteDefinitions(from markdown: String) -> (
        markdown: String,
        definitions: [String: (label: String, content: String)]
    ) {
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var definitions: [String: (label: String, content: String)] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if let match = firstMatch(of: footnoteDefinitionRegex, in: line) {
                let nsLine = line as NSString
                let label = nsLine.substring(with: match.range(at: 1))
                var contentLines = [nsLine.substring(with: match.range(at: 2))]
                index += 1

                while index < lines.count {
                    let continuation = lines[index]
                    if continuation.trimmingCharacters(in: .whitespaces).isEmpty {
                        if index + 1 < lines.count, isIndentedFootnoteContinuation(lines[index + 1]) {
                            contentLines.append("")
                            index += 1
                            continue
                        }
                        break
                    }
                    guard isIndentedFootnoteContinuation(continuation) else { break }
                    contentLines.append(stripFootnoteContinuationIndent(from: continuation))
                    index += 1
                }

                definitions[normalizeFootnoteKey(label)] = (
                    label: label,
                    content: contentLines.joined(separator: "\n")
                )
            } else {
                output.append(line)
                index += 1
            }
        }

        return (output.joined(separator: "\n"), definitions)
    }

    private static func firstMatch(of regex: NSRegularExpression,
                                   in source: String) -> NSTextCheckingResult? {
        let nsSource = source as NSString
        return regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
    }

    private static func isIndentedFootnoteContinuation(_ line: String) -> Bool {
        if line.hasPrefix("\t") { return true }
        return line.count >= 4 && line.prefix(4).allSatisfy { $0 == " " }
    }

    private static func stripFootnoteContinuationIndent(from line: String) -> String {
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        if line.count >= 4 && line.prefix(4).allSatisfy({ $0 == " " }) {
            return String(line.dropFirst(4))
        }
        return line
    }

    private static func normalizeFootnoteKey(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func replaceFootnoteReferenceMatches(in source: String,
                                                        transform: (String, String) -> String) -> String {
        let nsSource = source as NSString
        let matches = footnoteReferenceRegex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        guard !matches.isEmpty else { return source }

        var result = ""
        result.reserveCapacity(source.count)
        var cursor = 0
        for match in matches {
            result += nsSource.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let full = nsSource.substring(with: match.range)
            let label = nsSource.substring(with: match.range(at: 1))
            result += transform(label, full)
            cursor = match.range.location + match.range.length
        }
        result += nsSource.substring(from: cursor)
        return result
    }

    private static func renderFootnoteReferences(in html: String,
                                                 with footnotes: FootnoteExtraction) -> String {
        guard !footnotes.references.isEmpty else { return html }
        var rendered = html
        for reference in footnotes.references {
            let refID = footnoteReferenceID(number: reference.number, ordinal: reference.ordinal)
            let footnoteID = footnoteDefinitionID(number: reference.number)
            let replacement = """
            <sup class="footnote-ref"><a id="\(refID)" href="#\(footnoteID)" aria-label="Footnote \(reference.number)">\(reference.number)</a></sup>
            """
            rendered = rendered.replacingOccurrences(of: reference.token, with: replacement)
        }
        return rendered
    }

    private static func renderFootnoteDefinitions(_ footnotes: FootnoteExtraction) -> FootnoteDefinitionRenderResult {
        guard !footnotes.definitions.isEmpty else {
            return FootnoteDefinitionRenderResult(
                html: "",
                containsMath: false,
                containsMermaid: false
            )
        }

        var containsMath = false
        var containsMermaid = false
        let referencesByNumber = Dictionary(grouping: footnotes.references, by: { $0.number })
        let items = footnotes.definitions.map { definition -> String in
            let renderedContent = renderFootnoteDefinitionContent(definition.content)
            containsMath = containsMath || renderedContent.containsMath
            containsMermaid = containsMermaid || renderedContent.containsMermaid
            let backrefs = (referencesByNumber[definition.number] ?? []).map { reference in
                """
                <a href="#\(footnoteReferenceID(number: reference.number, ordinal: reference.ordinal))" class="footnote-backref" aria-label="Back to reference \(reference.number)">&#8617;</a>
                """
            }.joined(separator: " ")
            let contentHTML = appendFootnoteBackrefs(backrefs, to: renderedContent.html)

            return """
            <li id="\(footnoteDefinitionID(number: definition.number))">
            \(contentHTML)
            </li>
            """
        }.joined(separator: "\n")

        return FootnoteDefinitionRenderResult(
            html: """

            <section class="footnotes" role="doc-endnotes">
            <hr />
            <ol>
            \(items)
            </ol>
            </section>
            """,
            containsMath: containsMath,
            containsMermaid: containsMermaid
        )
    }

    private static func appendFootnoteBackrefs(_ backrefs: String, to html: String) -> String {
        guard !backrefs.isEmpty else { return html }
        let inlineBackrefs = "<span class=\"footnote-backrefs\">\(backrefs)</span>"
        if let range = html.range(of: "</p>", options: .backwards) {
            var updated = html
            updated.replaceSubrange(range, with: " \(inlineBackrefs)</p>")
            return updated
        }
        return html + inlineBackrefs
    }

    private static func renderFootnoteDefinitionContent(_ markdown: String) -> FootnoteDefinitionRenderResult {
        let math = extractMath(from: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        let formatted = EscapingHTMLFormatter.format(math.processedMarkdown)
        let mermaidResult = renderMermaidBlocks(in: formatted)
        let mathResult = renderMathBlocks(in: mermaidResult.html, with: math)
        return FootnoteDefinitionRenderResult(
            html: mathResult.html,
            containsMath: mathResult.containsMath,
            containsMermaid: mermaidResult.containsMermaid
        )
    }

    private static func footnoteDefinitionID(number: Int) -> String {
        "fn-\(number)"
    }

    private static func footnoteReferenceID(number: Int, ordinal: Int) -> String {
        ordinal == 1 ? "fnref-\(number)" : "fnref-\(number)-\(ordinal)"
    }

    // MARK: - Math (KaTeX)

    private struct MathExtraction {
        let processedMarkdown: String
        let blocks: [String]
        let inlines: [String]
    }

    private struct MathRenderResult {
        let html: String
        let containsMath: Bool
    }

    private static let blockMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$"#)
    }()

    // Reject leading `\$` (escaped) and require non-whitespace adjacent to
    // delimiters so prose like "$5 and $10" doesn't match.
    private static let inlineMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\$(?=\S)([^\$\n]+?)(?<=\S)\$"#)
    }()

    // Fenced code block. Group 1 = backtick run, group 2 = info string, group 3 = body.
    private static let codeFenceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?m)^(`{3,})[ \t]*([^\n`]*)\n([\s\S]*?)\n\1[ \t]*$"#
        )
    }()

    // Inline code span: matched-length backtick runs that are not adjacent to other
    // backticks. Mirrors CommonMark so spans like `` ` ```math ` `` (single-backtick
    // delimiters around three inner backticks) tokenize correctly.
    private static let inlineCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)([^\n]*?)(?<!`)\1(?!`)"#)
    }()

    // First alternative captures kind+index for a paragraph-wrapped block token
    // (the common case after swift-markdown wraps the standalone token); the
    // second captures a bare token. The wrapper is stripped in either case for
    // block kind to keep the resulting `<div>` out of an enclosing `<p>`.
    private static let mathTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<p>MdPreviewMath(Block|Inline)(\d+)Token</p>|MdPreviewMath(Block|Inline)(\d+)Token"#
        )
    }()

    private static func extractMath(from markdown: String) -> MathExtraction {
        var blocks: [String] = []
        var inlines: [String] = []
        var protected: [String] = []

        let nsMarkdown = markdown as NSString
        let fenceMatches = codeFenceRegex.matches(
            in: markdown,
            range: NSRange(location: 0, length: nsMarkdown.length)
        )
        var afterFences = ""
        afterFences.reserveCapacity(markdown.count)
        var fenceCursor = 0
        for match in fenceMatches {
            afterFences += nsMarkdown.substring(with: NSRange(
                location: fenceCursor,
                length: match.range.location - fenceCursor
            ))
            let info = CodeFenceInfo(
                rawInfoString: nsMarkdown.substring(with: match.range(at: 2))
            )
            if info.language == "math" {
                let body = nsMarkdown.substring(with: match.range(at: 3))
                blocks.append(body)
                // Surround with blank lines so swift-markdown wraps the standalone
                // token in its own <p>, which mathTokenRegex then strips.
                afterFences += "\n\nMdPreviewMathBlock\(blocks.count - 1)Token\n\n"
            } else {
                protected.append(nsMarkdown.substring(with: match.range))
                afterFences += "MdPreviewProtect\(protected.count - 1)Token"
            }
            fenceCursor = match.range.location + match.range.length
        }
        afterFences += nsMarkdown.substring(from: fenceCursor)

        // Inline code spans next, so $..$ inside `` `$x$` `` is not extracted.
        let afterInlineCode = replaceFullMatches(of: inlineCodeRegex, in: afterFences) { full in
            protected.append(full)
            return "MdPreviewProtect\(protected.count - 1)Token"
        }

        let afterBlockMath = replaceMatches(of: blockMathRegex, in: afterInlineCode) { capture in
            defer { blocks.append(capture) }
            return "MdPreviewMathBlock\(blocks.count)Token"
        }
        let afterInlineMath = replaceMatches(of: inlineMathRegex, in: afterBlockMath) { capture in
            defer { inlines.append(capture) }
            return "MdPreviewMathInline\(inlines.count)Token"
        }

        var processed = afterInlineMath
        for (i, original) in protected.enumerated() {
            processed = processed.replacingOccurrences(
                of: "MdPreviewProtect\(i)Token",
                with: original
            )
        }

        return MathExtraction(processedMarkdown: processed, blocks: blocks, inlines: inlines)
    }

    private static func renderMathBlocks(in html: String,
                                         with math: MathExtraction) -> MathRenderResult {
        guard !math.blocks.isEmpty || !math.inlines.isEmpty else {
            return MathRenderResult(html: html, containsMath: false)
        }

        let nsHtml = html as NSString
        let matches = mathTokenRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        var rebuilt = ""
        rebuilt.reserveCapacity(html.count)
        var cursor = 0
        for match in matches {
            rebuilt += nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let kindRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1) : match.range(at: 3)
            let indexRange = match.range(at: 2).location != NSNotFound
                ? match.range(at: 2) : match.range(at: 4)
            let isBlock = nsHtml.substring(with: kindRange) == "Block"
            let index = Int(nsHtml.substring(with: indexRange)) ?? 0
            let latex = isBlock ? math.blocks[index] : math.inlines[index]
            let escaped = htmlEscape(latex)
            rebuilt += isBlock
                ? "<div class=\"math math-display\">\(escaped)</div>"
                : "<span class=\"math math-inline\">\(escaped)</span>"
            cursor = match.range.location + match.range.length
        }
        rebuilt += nsHtml.substring(from: cursor)
        return MathRenderResult(html: rebuilt, containsMath: true)
    }

    // Debug-only perf instrumentation. Routes labelled timings through the
    // host bridge so `[mdp-perf +Xms]` entries land in Xcode's console while
    // diagnosing load-phase regressions. Compiled out of release builds —
    // no-op shims keep call sites unchanged.
    #if DEBUG
    private static let perfBridgeScript = """
    const perfT0 = (typeof performance !== 'undefined' && performance.now)
        ? performance.now() : 0;
    function perfNow() {
        return (typeof performance !== 'undefined' && performance.now)
            ? performance.now() - perfT0 : 0;
    }
    function perfLog(label, detail) {
        const dt = perfNow().toFixed(1);
        const msg = '[mdp-perf +' + dt + 'ms] ' + label
            + (detail !== undefined ? ' ' + detail : '');
        try { post({ kind: 'log', message: msg }); } catch (e) {}
    }
    window.MdPreviewPerf = { now: perfNow, log: perfLog, t0: perfT0 };
    perfLog('script eval');

    if (typeof PerformanceObserver === 'function') {
        try {
            // Disconnect after FCP — paint emits at most two entries
            // (first-paint, first-contentful-paint), no need to keep the
            // observer pinned for the WebView's lifetime.
            const seen = new Set();
            const po = new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    perfLog('paint:' + entry.name, entry.startTime.toFixed(1) + 'ms');
                    seen.add(entry.name);
                }
                if (seen.has('first-contentful-paint')) po.disconnect();
            });
            po.observe({ type: 'paint', buffered: true });
        } catch (e) {}
    }
    """
    #else
    private static let perfBridgeScript = """
    function perfNow() { return 0; }
    function perfLog() {}
    window.MdPreviewPerf = { now: perfNow, log: perfLog };
    """
    #endif

    // Always-on host bridge: pushes the document height to the AppKit host via
    // a WKScriptMessageHandler instead of having the host poll. Quietly no-ops
    // when the bridge isn't installed (e.g. Quick Look render).
    private static let hostBridgeScript: String = """
    <script>
    (() => {
        const post = (() => {
            try {
                const h = window.webkit && window.webkit.messageHandlers
                    && window.webkit.messageHandlers.mdPreviewHost;
                if (!h) return () => false;
                return (msg) => {
                    h.postMessage(msg);
                    return true;
                };
            } catch (e) { return () => false; }
        })();

        \(perfBridgeScript)

        function measureHeight() {
            const body = document.body;
            const article = document.querySelector('.markdown-body');
            if (!body || !article) return 1;
            const rect = article.getBoundingClientRect();
            const cs = getComputedStyle(body);
            const pt = parseFloat(cs.paddingTop) || 0;
            const pb = parseFloat(cs.paddingBottom) || 0;
            return Math.max(rect.bottom + pb, pt + article.scrollHeight + pb, 1);
        }

        let last = -1;
        let raf = 0;

        function pushHeight() {
            if (raf) return;
            raf = requestAnimationFrame(() => {
                raf = 0;
                const h = Math.ceil(measureHeight());
                if (h !== last) {
                    last = h;
                    post({ kind: 'height', value: h });
                }
            });
        }

        window.MdPreviewHost = { pushHeight, measureHeight };

        function elementForEventTarget(target) {
            if (target instanceof Element) return target;
            if (target && target.parentElement instanceof Element) return target.parentElement;
            return document.activeElement instanceof Element ? document.activeElement : null;
        }

        function keyBelongsToFocusedControl(target) {
            const el = elementForEventTarget(target);
            if (!el) return false;
            if (el.isContentEditable) return true;
            return !!el.closest([
                'button',
                'input',
                'select',
                'textarea',
                'summary',
                'audio',
                'video',
                '[contenteditable]',
                '[role="button"]',
                '[role="checkbox"]',
                '[role="switch"]',
                '[role="textbox"]',
                '[role="combobox"]',
                '[role="listbox"]',
                '[role="menuitem"]'
            ].join(','));
        }

        function handlePreviewScrollKey(event) {
            if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return false;
            if (keyBelongsToFocusedControl(event.target)) return false;

            const isSpace = event.key === ' ' || event.key === 'Spacebar' || event.code === 'Space';
            if (isSpace) {
                return post({ kind: 'scroll', value: event.shiftKey ? 'pageUp' : 'pageDown' });
            }

            if (event.shiftKey) return false;
            const key = (event.key || '').toLowerCase();
            if (key === 'j') return post({ kind: 'scroll', value: 'lineDown' });
            if (key === 'k') return post({ kind: 'scroll', value: 'lineUp' });
            return false;
        }

        document.addEventListener('keydown', (event) => {
            if (handlePreviewScrollKey(event)) {
                event.preventDefault();
                event.stopPropagation();
            }
        }, true);

        function decorateCodeBlocks() {
            document.querySelectorAll('pre > code').forEach((code) => {
                const pre = code.parentElement;
                if (!pre || pre.dataset.copyButtonReady === '1') return;
                pre.dataset.copyButtonReady = '1';

                // Wrap pre in a positioned container so the copy button
                // stays pinned regardless of horizontal scroll inside pre.
                const wrap = document.createElement('div');
                wrap.className = 'md-code-wrap';
                pre.parentNode.insertBefore(wrap, pre);
                wrap.appendChild(pre);

                const button = document.createElement('button');
                button.type = 'button';
                button.className = 'md-code-copy';
                button.setAttribute('aria-label', 'Copy code');
                wrap.appendChild(button);
            });
        }

        function cloneSelectionWithoutCopyButtons(selection) {
            const fragment = document.createDocumentFragment();
            for (let i = 0; i < selection.rangeCount; i += 1) {
                fragment.appendChild(selection.getRangeAt(i).cloneContents());
            }
            const buttons = fragment.querySelectorAll('.md-code-copy');
            if (buttons.length === 0) return null;
            buttons.forEach((button) => button.remove());
            return fragment;
        }

        function plainTextFromFragment(fragment) {
            const div = document.createElement('div');
            div.appendChild(fragment.cloneNode(true));
            return div.innerText || div.textContent || '';
        }

        function htmlFromFragment(fragment) {
            const div = document.createElement('div');
            div.appendChild(fragment.cloneNode(true));
            return div.innerHTML;
        }

        async function copyCodeBlock(button) {
            const wrap = button.parentElement;
            const code = wrap && wrap.querySelector('pre > code');
            if (!code) return;
            const text = code.textContent || '';
            let copied = false;
            try {
                copied = post({ kind: 'copyCode', value: text });
            } catch (e) {}
            if (!copied && navigator.clipboard && navigator.clipboard.writeText) {
                try {
                    await navigator.clipboard.writeText(text);
                    copied = true;
                } catch (e) {}
            }
            if (!copied) return;
            button.setAttribute('aria-label', 'Code copied');
            button.classList.add('is-copied');
            clearTimeout(button.__mdCopyTimer);
            button.__mdCopyTimer = setTimeout(() => {
                button.setAttribute('aria-label', 'Copy code');
                button.classList.remove('is-copied');
            }, 1100);
        }

        document.addEventListener('click', (event) => {
            const button = event.target.closest('.md-code-copy');
            if (!button) return;
            event.preventDefault();
            event.stopPropagation();
            copyCodeBlock(button);
        });

        document.addEventListener('copy', (event) => {
            const selection = window.getSelection();
            if (!selection || selection.rangeCount === 0 || !event.clipboardData) return;
            const fragment = cloneSelectionWithoutCopyButtons(selection);
            if (!fragment) return;
            event.clipboardData.setData('text/plain', plainTextFromFragment(fragment));
            event.clipboardData.setData('text/html', htmlFromFragment(fragment));
            event.preventDefault();
        });

        // Vendor lazy-load helpers. rAF is paused while the WKWebView is
        // offscreen (e.g. during the launch-time warmup before the window
        // becomes visible), so afterPaint also falls back to setTimeout(50).
        window.MdPreviewLazy = {
            afterPaint(cb) {
                function tick() {
                    let fired = false;
                    function fire(via) {
                        if (!fired) {
                            fired = true;
                            perfLog('afterPaint fire', via);
                            cb();
                        }
                    }
                    requestAnimationFrame(() => requestAnimationFrame(() => fire('rAF')));
                    setTimeout(() => fire('timeout'), 50);
                }
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', tick, { once: true });
                } else {
                    tick();
                }
            },
            loadScript(src) {
                return new Promise((resolve, reject) => {
                    const tStart = perfNow();
                    perfLog('script append', src);
                    const s = document.createElement('script');
                    s.onload = () => {
                        perfLog('script onload', src + ' (+' + (perfNow() - tStart).toFixed(1) + 'ms)');
                        resolve();
                    };
                    s.onerror = () => reject(new Error('failed: ' + src));
                    s.src = src;
                    document.head.appendChild(s);
                });
            },
            // Wires up a renderer whose vendor JS is loaded after first paint.
            // - registers a reapplier that gates on `loaded`, so fast-path
            //   updates don't fire the renderer before its bundle has arrived
            // - on first paint, fetches `src` (and any `extras` after) and
            //   calls `run`
            lazyRenderer({ src, extras, run }) {
                let loaded = false;
                if (window.MdPreview && window.MdPreview.registerReapplier) {
                    window.MdPreview.registerReapplier(() => { if (loaded) run(); });
                }
                this.afterPaint(async () => {
                    try {
                        await this.loadScript(src);
                        loaded = true;
                        run();
                        if (extras) {
                            for (const e of extras) this.loadScript(e).catch(() => {});
                        }
                    } catch (e) {}
                });
            }
        };

        // DOMPurify config. Closes the raw-HTML XSS path on user markdown
        // (EscapingHTMLFormatter passes block- and inline-HTML through per
        // CommonMark). Inline event handlers, <script>, <iframe>, <object>,
        // <embed>, <base>, <meta>, <link>, <style>, and <form> are dropped;
        // the `style` attribute is stripped to defeat visual-deception
        // attacks against the copy button (display:none segments inside
        // <pre><code> would otherwise survive into clipboard textContent).
        // <button> stays allowed so the mermaid zoom HUD survives sanitize();
        // without a parent <form> (forbidden above), `formaction` has nothing
        // to submit to, and on* handlers are stripped by DOMPurify defaults.
        //
        // ALLOWED_URI_REGEXP extends DOMPurify's default safe-URL list with
        // `md-asset:` so markdown image references that resolve to the
        // document's base directory (![alt](relative/path.png)) keep working.
        const SANITIZE_CONFIG = {
            FORBID_TAGS: ['style', 'form', 'iframe', 'object',
                          'embed', 'meta', 'link', 'base'],
            FORBID_ATTR: ['style'],
            ADD_ATTR: ['target'],
            ALLOWED_URI_REGEXP: /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix|md-asset):|[^a-z]|[a-z+.\\-]+(?:[^a-z+.\\-:]|$))/i
        };

        function sanitize(html) {
            if (typeof html !== 'string') return '';
            if (typeof DOMPurify === 'undefined' || !DOMPurify.sanitize) {
                // Fail closed: refuse to render rather than risk shipping
                // unsanitized HTML into innerHTML. This branch fires only if
                // the bundled purify.min.js is missing from the app bundle.
                if (window.console && console.error) {
                    console.error('[md-preview] DOMPurify not loaded; refusing to render article.');
                }
                return '';
            }
            return DOMPurify.sanitize(html, SANITIZE_CONFIG);
        }

        // Incremental-update entry point. Each renderer (KaTeX/Mermaid)
        // registers an idempotent reapplier that re-processes the current
        // article. Same-flag re-renders skip the WKWebView reload entirely.
        const reappliers = [];
        window.MdPreview = window.MdPreview || {};
        window.MdPreview.registerReapplier = (fn) => {
            if (typeof fn === 'function') reappliers.push(fn);
        };
        // `opts.keepHidden` preserves the warmup opacity so the synthetic
        // Mermaid pre-render doesn't flash on screen. The host then issues a
        // second update without the flag once the real document arrives,
        // which clears the inline style and reveals the article.
        window.MdPreview.update = (articleHTML, opts) => {
            const article = document.querySelector('.markdown-body');
            if (!article) return;
            const tStart = perfNow();
            article.innerHTML = sanitize(articleHTML);
            if (!opts || !opts.keepHidden) {
                article.style.opacity = '';
                article.style.pointerEvents = '';
            }
            if (articleHTML) {
                decorateCodeBlocks();
                for (const fn of reappliers) {
                    try { fn(); } catch (e) { /* one bad apple shouldn't block others */ }
                }
            }
            perfLog('MdPreview.update', '(+' + (perfNow() - tStart).toFixed(1) + 'ms)');
            pushHeight();
        };

        // Initial-load populator. The article body ships inside an inert
        // <template> element so the parser never fires inline event handlers
        // on first paint. Pull it out, sanitize, inject. The template is
        // removed once consumed.
        function populateFromTemplate() {
            const tmpl = document.getElementById('md-article-source');
            if (!tmpl) return;
            const article = document.querySelector('.markdown-body');
            const keepHidden = !!(article && article.dataset.warmup === '1');
            window.MdPreview.update(tmpl.innerHTML, { keepHidden });
            tmpl.remove();
        }

        function start() {
            perfLog('start (DOM ready)');
            populateFromTemplate();
            decorateCodeBlocks();
            pushHeight();
            try {
                const ro = new ResizeObserver(pushHeight);
                ro.observe(document.body);
                const article = document.querySelector('.markdown-body');
                if (article) ro.observe(article);
            } catch (e) {}
            window.addEventListener('md-preview-mermaid-rendered', pushHeight);
            window.addEventListener('md-preview-math-rendered', pushHeight);
            window.addEventListener('load', pushHeight);
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }
    })();
    </script>
    """

    private static let katexFallbackScript = """
    <script>
    window.addEventListener('load', () => {
        document.querySelectorAll('.math').forEach((node) => {
            node.classList.add('math-error');
            node.textContent = 'KaTeX renderer is unavailable.\\n\\n' + node.textContent;
        });
    });
    </script>
    """

    /// JS body of `function renderMath()`. Shared between inline and lazy
    /// modes — only the surrounding wiring (immediate run vs. deferred-on-load)
    /// differs.
    private static let katexRenderMathBody = """
    function renderMath() {
        document.querySelectorAll('.math').forEach((el) => {
            if (el.dataset.mathDone === '1') return;
            const tex = el.textContent;
            const display = el.classList.contains('math-display');
            try {
                katex.render(tex, el, {
                    displayMode: display,
                    throwOnError: false,
                    output: 'htmlAndMathml'
                });
                el.dataset.mathDone = '1';
            } catch (err) {
                el.classList.add('math-error');
                el.textContent = String((err && err.message) || err);
                el.dataset.mathDone = '1';
            }
        });
        window.dispatchEvent(new Event('md-preview-math-rendered'));
    }
    """

    /// Inline DOMPurify so the bootstrap can call `DOMPurify.sanitize` before
    /// the first article ever reaches `innerHTML`. Emitted ahead of the host
    /// bridge so the sanitizer is defined by the time `MdPreview.update` runs.
    /// If the vendored file is missing (developer setup error), this returns
    /// empty and the bootstrap's `sanitize()` fails closed — rendering an
    /// empty article rather than shipping unsanitized HTML.
    private static func dompurifyHead() -> String {
        guard let js = bundledVendorResource("purify.min", ext: "js", subdir: "Vendor/DOMPurify") else {
            return ""
        }
        let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
        return "<script>\(safeJS)</script>"
    }

    private static func katexHead(mode: VendorLoading) -> String {
        guard bundledVendorURL("katex.min", ext: "js", subdir: "Vendor/KaTeX") != nil else {
            return katexFallbackScript
        }
        let css = bundledVendorResource("katex.min", ext: "css", subdir: "Vendor/KaTeX") ?? ""

        let initScript = """
        <script>
        (function() {
            \(katexRenderMathBody)
            if (window.MdPreview && window.MdPreview.registerReapplier) {
                window.MdPreview.registerReapplier(renderMath);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', renderMath, { once: true });
            } else {
                renderMath();
            }
        })();
        </script>
        """

        switch mode {
        case .inline:
            let js = bundledVendorResource("katex.min", ext: "js", subdir: "Vendor/KaTeX") ?? ""
            let copyTex = bundledVendorResource("copy-tex.min", ext: "js", subdir: "Vendor/KaTeX") ?? ""
            let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
            let safeCopyTex = copyTex.replacingOccurrences(of: "</script", with: "<\\/script")
            return """
            <style>\(css)</style>
            <script>\(safeJS)</script>
            \(initScript)
            \(safeCopyTex.isEmpty ? "" : "<script>\(safeCopyTex)</script>")
            """
        case .lazy:
            // CSS stays inline so layout is stable while KaTeX JS streams in.
            return """
            <style>\(css)</style>
            <script>
            (function() {
                \(katexRenderMathBody)
                window.MdPreviewLazy.lazyRenderer({
                    src: '\(MarkdownAssetScheme.vendorURL("katex.min.js"))',
                    extras: ['\(MarkdownAssetScheme.vendorURL("copy-tex.min.js"))'],
                    run: renderMath,
                });
            })();
            </script>
            """
        }
    }

    private static func bundledVendorURL(_ name: String,
                                         ext: String,
                                         subdir: String) -> URL? {
        let bundles = [Bundle.main, Bundle(for: MarkdownHTMLBundleToken.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdir) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func bundledVendorResource(_ name: String,
                                              ext: String,
                                              subdir: String) -> String? {
        bundledVendorURL(name, ext: ext, subdir: subdir).flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }
    }

    private static func replaceMatches(of regex: NSRegularExpression,
                                       in source: String,
                                       transform: (String) -> String) -> String {
        rewrite(matchesOf: regex, in: source, captureGroup: 1, transform: transform)
    }

    private static func replaceFullMatches(of regex: NSRegularExpression,
                                           in source: String,
                                           transform: (String) -> String) -> String {
        rewrite(matchesOf: regex, in: source, captureGroup: 0, transform: transform)
    }

    private static func rewrite(matchesOf regex: NSRegularExpression,
                                in source: String,
                                captureGroup: Int,
                                transform: (String) -> String) -> String {
        let nsSource = source as NSString
        let matches = regex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        guard !matches.isEmpty else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var cursor = 0
        for match in matches {
            result += nsSource.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            result += transform(nsSource.substring(with: match.range(at: captureGroup)))
            cursor = match.range.location + match.range.length
        }
        result += nsSource.substring(from: cursor)
        return result
    }

    private static func htmlEscape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - Code highlighting (highlight.js)

    // Excludes `language-mermaid` since renderMermaidBlocks already lifted
    // those into `<figure>` containers before this runs.
    private static let highlightableCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<pre><code class="language-(?!mermaid")[a-zA-Z0-9_+#-]+""#
        )
    }()

    private static func detectHighlightableCode(in html: String) -> Bool {
        firstMatch(of: highlightableCodeRegex, in: html) != nil
    }

    /// Yields via rAF every ~8 ms so the main thread is never pinned for
    /// more than one frame on docs with many code blocks.
    private static let highlightAllBody = """
    function highlightAll() {
        if (typeof hljs === 'undefined') return;
        if (!document.querySelector('pre code[class*="language-"]:not([data-hljs-done="1"])')) return;
        const blocks = Array.prototype.slice.call(
            document.querySelectorAll('pre code[class*="language-"]:not([data-hljs-done="1"])')
        );
        MdPreviewPerf.log('hljs highlightAll start', blocks.length + ' blocks');
        let i = 0;
        function step() {
            const sliceStart = MdPreviewPerf.now();
            while (i < blocks.length) {
                const block = blocks[i++];
                try {
                    hljs.highlightElement(block);
                } catch (e) {
                    MdPreviewPerf.log('hljs threw', String(e && e.message || e));
                }
                block.dataset.hljsDone = '1';
                if (MdPreviewPerf.now() - sliceStart > 8) break;
            }
            if (i < blocks.length) {
                requestAnimationFrame(step);
            } else {
                window.dispatchEvent(new Event('md-preview-hljs-rendered'));
                MdPreviewPerf.log('hljs all done');
            }
        }
        requestAnimationFrame(step);
    }
    """

    private static func highlightHead(mode: VendorLoading) -> String {
        guard bundledVendorURL("highlight.min", ext: "js", subdir: "Vendor/Highlight") != nil else {
            return ""
        }
        let css = bundledVendorResource("highlight.min", ext: "css", subdir: "Vendor/Highlight") ?? ""

        let initScript = """
        <script>
        (function() {
            \(highlightAllBody)
            if (window.MdPreview && window.MdPreview.registerReapplier) {
                window.MdPreview.registerReapplier(highlightAll);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', highlightAll, { once: true });
            } else {
                highlightAll();
            }
        })();
        </script>
        """

        switch mode {
        case .inline:
            let js = bundledVendorResource("highlight.min", ext: "js", subdir: "Vendor/Highlight") ?? ""
            let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
            return """
            <style>\(css)</style>
            <script>\(safeJS)</script>
            \(initScript)
            """
        case .lazy:
            // CSS stays inline so layout doesn't shift when the JS arrives.
            return """
            <style>\(css)</style>
            <script>
            (function() {
                \(highlightAllBody)
                window.MdPreviewLazy.lazyRenderer({
                    src: '\(MarkdownAssetScheme.vendorURL("highlight.min.js"))',
                    run: highlightAll,
                });
            })();
            </script>
            """
        }
    }

    // MARK: - Mermaid

    private struct MermaidRenderResult {
        let html: String
        let containsMermaid: Bool
    }

    private static let mermaidRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#
        )
    }()

    private static func renderMermaidBlocks(in html: String) -> MermaidRenderResult {
        guard html.contains("language-mermaid") else {
            return MermaidRenderResult(html: html, containsMermaid: false)
        }
        let rendered = replaceMatches(of: mermaidRegex, in: html) { diagram in
            """
            <figure class="mermaid-figure" tabindex="0" role="img" aria-label="Mermaid diagram">
            <div class="mermaid-stage"><div class="mermaid">
            \(diagram)
            </div></div>
            <div class="mermaid-hud" aria-hidden="true">
            <button type="button" class="mermaid-hud-btn" data-mm-act="out" tabindex="-1" aria-label="Zoom out">−</button>
            <button type="button" class="mermaid-hud-btn mermaid-hud-level" data-mm-act="reset" tabindex="-1" aria-label="Reset zoom">100%</button>
            <button type="button" class="mermaid-hud-btn" data-mm-act="in" tabindex="-1" aria-label="Zoom in">+</button>
            </div>
            </figure>
            """
        }
        return MermaidRenderResult(html: rendered, containsMermaid: true)
    }

    private static let mermaidFallbackScript = """
    <script>
    window.addEventListener('load', () => {
        document.querySelectorAll('.mermaid').forEach((node) => {
            node.classList.add('mermaid-error');
            node.textContent = 'Mermaid renderer is unavailable.\\n\\n' + node.textContent;
        });
    });
    </script>
    """

    /// Mermaid wiring IIFE. Assumes the `mermaid` global has been (or will
    /// be) defined by the time DOMContentLoaded fires — true for both inline
    /// vendor `<script>` and `<script defer src=...>` delivery, since `defer`
    /// scripts run before DOMContentLoaded.
    private static let mermaidInitWiring = """
    (() => {
            const states = new WeakMap();
            const queue = [];
            let draining = false;
            let initialized = false;

            function ensureInit() {
                if (initialized) return;
                initialized = true;
                const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                mermaid.initialize({
                    startOnLoad: false,
                    theme: dark ? 'dark' : 'default',
                    securityLevel: 'strict',
                    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif'
                });
            }

            async function drain() {
                if (draining) return;
                draining = true;
                while (queue.length) {
                    const figure = queue.shift();
                    await renderOne(figure);
                }
                draining = false;
                window.dispatchEvent(new Event('md-preview-mermaid-rendered'));
            }

            async function renderOne(figure) {
                ensureInit();
                const node = figure.querySelector('.mermaid');
                if (!node || node.dataset.mmDone === '1') return;
                try {
                    await mermaid.run({ nodes: [node], suppressErrors: true });
                } catch (err) {
                    figure.classList.add('mermaid-error');
                    return;
                }
                const svg = node.querySelector('svg');
                if (!svg) {
                    figure.classList.add('mermaid-error');
                    return;
                }
                node.dataset.mmDone = '1';
                attachZoom(figure, svg);
            }

            function attachZoom(figure, svg) {
                // Normalize sizing: prefer viewBox, drop intrinsic width/height.
                let vbW, vbH;
                const vb = svg.viewBox && svg.viewBox.baseVal;
                if (vb && vb.width && vb.height) {
                    vbW = vb.width; vbH = vb.height;
                } else {
                    vbW = parseFloat(svg.getAttribute('width')) || svg.getBBox().width || 1;
                    vbH = parseFloat(svg.getAttribute('height')) || svg.getBBox().height || 1;
                    svg.setAttribute('viewBox', '0 0 ' + vbW + ' ' + vbH);
                }
                svg.removeAttribute('width');
                svg.removeAttribute('height');
                svg.style.width = '100%';
                svg.style.height = '100%';
                svg.style.transformOrigin = '0 0';

                // Stable layout: figure claims height from the diagram's aspect ratio,
                // capped by max-height so massive diagrams don't push the page.
                if (vbW > 0 && vbH > 0) {
                    figure.style.setProperty('--mm-aspect', vbW + ' / ' + vbH);
                }

                const state = {
                    tx: 0, ty: 0, scale: 1, min: 1, max: 8,
                    rect: null, raf: 0, dragging: false,
                    lastX: 0, lastY: 0, svg
                };
                states.set(figure, state);
                cacheRect(figure);

                figure.addEventListener('wheel', onWheel, { passive: false });
                figure.addEventListener('pointerdown', onPointerDown);
                figure.addEventListener('dblclick', onDoubleClick);
                const hud = figure.querySelector('.mermaid-hud');
                if (hud) hud.addEventListener('click', onHudClick);
            }

            function cacheRect(figure) {
                const s = states.get(figure);
                if (s) s.rect = figure.getBoundingClientRect();
            }

            function apply(figure, s) {
                if (s.raf) return;
                s.raf = requestAnimationFrame(() => {
                    s.raf = 0;
                    s.svg.style.transform = 'translate(' + s.tx + 'px,' + s.ty + 'px) scale(' + s.scale + ')';
                    const lvl = figure.querySelector('.mermaid-hud-level');
                    if (lvl) lvl.textContent = Math.round(s.scale * 100) + '%';
                });
            }

            function zoomAt(figure, x, y, k) {
                const s = states.get(figure);
                if (!s) return;
                const next = Math.max(s.min, Math.min(s.max, s.scale * k));
                if (next === s.scale) return;
                const ratio = next / s.scale;
                s.tx = x - (x - s.tx) * ratio;
                s.ty = y - (y - s.ty) * ratio;
                s.scale = next;
                if (s.scale <= 1.001) { s.tx = 0; s.ty = 0; }
                apply(figure, s);
            }

            function reset(figure) {
                const s = states.get(figure);
                if (!s) return;
                s.tx = 0; s.ty = 0; s.scale = 1;
                apply(figure, s);
            }

            function step(figure, factor) {
                const s = states.get(figure);
                if (!s) return;
                if (!s.rect) cacheRect(figure);
                const r = s.rect;
                zoomAt(figure, r.width / 2, r.height / 2, factor);
            }

            function onWheel(e) {
                // ⌘/Ctrl + wheel zooms; macOS pinch synthesizes wheel + ctrlKey.
                // Plain wheel falls through to the page scroll (don't preventDefault).
                if (!(e.ctrlKey || e.metaKey)) return;
                const figure = e.currentTarget;
                const s = states.get(figure);
                if (!s) return;
                e.preventDefault();
                if (!s.rect) cacheRect(figure);
                const r = s.rect;
                const k = Math.exp(-e.deltaY * 0.01);
                zoomAt(figure, e.clientX - r.left, e.clientY - r.top, k);
            }

            function onPointerDown(e) {
                if (e.button !== 0) return;
                const figure = e.currentTarget;
                const s = states.get(figure);
                if (!s) return;
                if (e.target.closest('.mermaid-hud')) return;
                figure.setPointerCapture(e.pointerId);
                s.dragging = true;
                s.lastX = e.clientX;
                s.lastY = e.clientY;
                figure.addEventListener('pointermove', onPointerMove);
                figure.addEventListener('pointerup', onPointerUp);
                figure.addEventListener('pointercancel', onPointerUp);
            }

            function onPointerMove(e) {
                const figure = e.currentTarget;
                const s = states.get(figure);
                if (!s || !s.dragging) return;
                s.tx += e.clientX - s.lastX;
                s.ty += e.clientY - s.lastY;
                s.lastX = e.clientX;
                s.lastY = e.clientY;
                apply(figure, s);
            }

            function onPointerUp(e) {
                const figure = e.currentTarget;
                const s = states.get(figure);
                if (!s) return;
                s.dragging = false;
                figure.removeEventListener('pointermove', onPointerMove);
                figure.removeEventListener('pointerup', onPointerUp);
                figure.removeEventListener('pointercancel', onPointerUp);
            }

            function onDoubleClick(e) {
                const figure = e.currentTarget;
                if (e.target.closest('.mermaid-hud')) return;
                const s = states.get(figure);
                if (!s) return;
                if (s.scale > 1.001) {
                    reset(figure);
                } else {
                    if (!s.rect) cacheRect(figure);
                    const r = s.rect;
                    zoomAt(figure, e.clientX - r.left, e.clientY - r.top, 2);
                }
            }

            function onHudClick(e) {
                const btn = e.target.closest('[data-mm-act]');
                if (!btn) return;
                e.stopPropagation();
                const figure = btn.closest('.mermaid-figure');
                if (!figure) return;
                figure.focus();
                switch (btn.dataset.mmAct) {
                    case 'in':    step(figure, 1.25); break;
                    case 'out':   step(figure, 0.8);  break;
                    case 'reset': reset(figure);      break;
                }
            }

            const ro = new ResizeObserver((entries) => {
                for (const entry of entries) cacheRect(entry.target);
            });

            function bootstrap() {
                const figures = document.querySelectorAll('.mermaid-figure');
                if (!figures.length) return;
                const io = new IntersectionObserver((entries) => {
                    for (const entry of entries) {
                        if (entry.isIntersecting) {
                            io.unobserve(entry.target);
                            queue.push(entry.target);
                            ro.observe(entry.target);
                            drain();
                        }
                    }
                }, { rootMargin: '300px 0px' });
                figures.forEach((f) => io.observe(f));
            }

            return { bootstrap };
        })()
    """

    private static func mermaidScript(mode: VendorLoading) -> String {
        guard bundledVendorURL("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") != nil else {
            return mermaidFallbackScript
        }
        switch mode {
        case .inline:
            let vendorJS = bundledVendorResource("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") ?? ""
            let safeVendor = vendorJS.replacingOccurrences(of: "</script", with: "<\\/script")
            return """
            <script>
            \(safeVendor)

            const __mdpMermaid = \(mermaidInitWiring);
            if (window.MdPreview && window.MdPreview.registerReapplier) {
                window.MdPreview.registerReapplier(__mdpMermaid.bootstrap);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', __mdpMermaid.bootstrap, { once: true });
            } else {
                __mdpMermaid.bootstrap();
            }
            </script>
            """
        case .lazy:
            return """
            <script>
            (() => {
                let mm = null;
                window.MdPreviewLazy.lazyRenderer({
                    src: '\(MarkdownAssetScheme.vendorURL("mermaid.min.js"))',
                    run: () => {
                        mm = mm || \(mermaidInitWiring);
                        mm.bootstrap();
                    },
                });
            })();
            </script>
            """
        }
    }

    private final class MarkdownHTMLBundleToken {}

    // Mirrors MarkdownUI's Theme.docC. Top-only margins (bottom: 0), Apple SF
    // palette (text #1d1d1f / #f5f5f7, link #0066cc / #2997ff, grid #d2d2d7 /
    // #424245, code bg #f5f5f7 / #2A2828, aside bg #f5f5f7 / #323232), 15px continuous container
    // radius, horizontal-only table borders.
    private static let stylesheet = """
    :root {
        color-scheme: light dark;
        --text: #1d1d1f;
        --secondary: #6e6e73;
        --link: #0066cc;
        --aside-bg: #f5f5f7;
        --aside-border: #696969;
        --quote-border: #d2d2d7;
        --code-bg: #f5f5f7;
        --grid: #d2d2d7;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --text: #f5f5f7;
            --secondary: #86868b;
            --link: #2997ff;
            --aside-bg: #323232;
            --aside-border: #9a9a9e;
            --quote-border: #6e6e73;
            --code-bg: #2A2828;
            --grid: #424245;
        }
    }

    * { box-sizing: border-box; }
    mark.md-search-highlight {
        background: #ffd84d;
        color: #1d1d1f;
        -webkit-box-decoration-break: clone;
    }
    mark.md-search-highlight-current {
        background: #ffbf00;
    }
    .md-search-burst {
        position: absolute;
        pointer-events: none;
        background: rgba(255, 191, 0, 0.5);
        border-radius: 6px;
        box-shadow: 0 0 4px rgba(0, 0, 0, 0.12),
                    0 2px 6px rgba(0, 0, 0, 0.15);
        z-index: 9999;
        transform-origin: center center;
        will-change: transform;
        animation: md-search-burst 250ms forwards;
    }
    /* Per-segment timing: accelerate into the peak (cubic-bezier ease-in),
       then decelerate out of it (strong ease-out). High matching velocity
       at the peak means the motion flows through without pausing — the
       "stuck" feel of multi-stop ease-out keyframes. */
    @keyframes md-search-burst {
        0% {
            transform: scale(1.0);
            animation-timing-function: cubic-bezier(0.55, 0, 1, 0.45);
        }
        50% {
            transform: scale(1.32);
            animation-timing-function: cubic-bezier(0, 0.55, 0.45, 1);
        }
        100% {
            transform: scale(1.0);
        }
    }
    @media (prefers-reduced-motion: reduce) {
        .md-search-burst { animation-duration: 1ms; }
    }
    html, body {
        margin: 0;
        padding: 0;
        overflow: hidden;
    }
    ::-webkit-scrollbar {
        display: none;
        width: 0;
        height: 0;
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        font-size: 15px;
        line-height: 1.52;
        color: var(--text);
        background: transparent;
        padding: 32px 40px 48px;
        -webkit-font-smoothing: antialiased;
    }

    article.markdown-body {
        max-width: \(contentColumnWidth)px;
        margin-left: auto;
        margin-right: auto;
    }
    article.markdown-body > *:first-child { margin-top: 0 !important; }

    p {
        margin: 0.8em 0 0;
    }

    h1, h2, h3, h4, h5, h6 {
        font-weight: 600;
        line-height: 1.18;
        margin: 1.6em 0 0;
    }
    h1 { font-size: 2em; margin-top: 0.8em; }
    h2 { font-size: 1.88em; line-height: 1.06; }
    h3 { font-size: 1.65em; line-height: 1.07; }
    h4 { font-size: 1.41em; line-height: 1.08; }
    h5 { font-size: 1.29em; line-height: 1.09; }
    h6 { font-size: 1em; line-height: 1.24; }

    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .footnote-ref {
        font-size: 0.75em;
        line-height: 0;
        vertical-align: super;
    }
    .footnote-ref a {
        padding: 0 0.12em;
    }
    .footnotes {
        margin-top: 2.35em;
        color: var(--text);
        font-size: 0.9em;
        line-height: 1.45;
    }
    .footnotes hr {
        margin: 0 0 1em;
    }
    .footnotes ol {
        margin-top: 0;
        padding-left: 1.45em;
    }
    .footnotes li {
        margin-top: 0.72em;
        padding-left: 0.12em;
    }
    .footnotes li:first-child {
        margin-top: 0;
    }
    .footnotes li > p:first-child {
        margin-top: 0;
    }
    .footnote-backrefs {
        display: inline-flex;
        gap: 0.28em;
        margin-left: 0.28em;
        white-space: nowrap;
    }
    .footnote-backref {
        font-size: 0.78em;
        opacity: 0.65;
        vertical-align: baseline;
    }
    .footnote-backref:hover {
        opacity: 1;
    }

    code {
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
        padding: 0.18em 0.42em;
        background: var(--code-bg);
        border-radius: 6px;
    }
    pre {
        position: relative;
        margin: 0.8em 0 0;
        padding: 10px 14px;
        background: var(--code-bg);
        border-radius: 15px;
        overflow-x: auto;
        line-height: 1.45;
    }
    pre::-webkit-scrollbar {
        display: block;
        height: 10px;
        width: 0;
    }
    pre::-webkit-scrollbar-track {
        background: transparent;
    }
    pre::-webkit-scrollbar-thumb {
        background-color: color-mix(in srgb, var(--text) 22%, transparent);
        border-radius: 10px;
        border: 3px solid transparent;
        background-clip: padding-box;
    }
    pre:hover::-webkit-scrollbar-thumb {
        background-color: color-mix(in srgb, var(--text) 38%, transparent);
    }
    pre::-webkit-scrollbar-thumb:hover,
    pre::-webkit-scrollbar-thumb:active {
        background-color: color-mix(in srgb, var(--text) 55%, transparent);
    }
    pre code {
        padding: 0;
        background: transparent;
        font-size: 0.88em;
    }
    .md-code-wrap {
        position: relative;
    }
    .md-code-copy {
        position: absolute;
        top: 8px;
        right: 8px;
        appearance: none;
        min-width: 56px;
        height: 24px;
        padding: 0 10px;
        border: none;
        border-radius: 8px;
        color: var(--secondary);
        background: color-mix(in srgb, var(--text) 10%, var(--code-bg));
        font: 500 11px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        cursor: pointer;
        opacity: 0;
        transition: opacity 120ms ease,
                    color 120ms ease,
                    background-color 120ms ease,
                    transform 120ms ease;
        user-select: none;
        -webkit-user-select: none;
        z-index: 2;
    }
    .md-code-copy::after {
        content: "Copy";
    }
    .md-code-copy.is-copied::after {
        content: "Copied";
    }
    .md-code-wrap:hover .md-code-copy,
    .md-code-wrap:focus-within .md-code-copy,
    .md-code-copy.is-copied {
        opacity: 1;
    }
    .md-code-copy:hover {
        color: var(--text);
        background: color-mix(in srgb, var(--text) 16%, var(--code-bg));
    }
    .md-code-copy:active {
        background: color-mix(in srgb, var(--text) 22%, var(--code-bg));
        transform: scale(0.97);
    }
    .md-code-copy:focus-visible {
        outline: none;
        box-shadow: 0 0 0 3px color-mix(in srgb, AccentColor 60%, transparent);
    }
    @media (prefers-reduced-motion: reduce) {
        .md-code-copy { transition: none; }
        .md-code-copy:active { transform: none; }
    }
    .mermaid-figure {
        position: relative;
        margin: 1.6em 0 0;
        background: var(--code-bg);
        border-radius: 15px;
        overflow: hidden;
        outline: none;
        aspect-ratio: var(--mm-aspect, 4 / 3);
        max-height: min(70vh, 720px);
        contain: layout paint;
    }
    .mermaid-figure:focus-visible {
        box-shadow: 0 0 0 3px color-mix(in srgb, AccentColor 60%, transparent);
    }
    .mermaid-stage {
        position: absolute;
        inset: 0;
        overflow: hidden;
        contain: strict;
    }
    .mermaid-figure .mermaid-stage { cursor: grab; }
    .mermaid-figure .mermaid-stage:active { cursor: grabbing; }
    .mermaid {
        position: absolute;
        inset: 0;
        padding: 16px;
        box-sizing: border-box;
    }
    .mermaid svg {
        display: block;
        width: 100%;
        height: 100%;
    }
    .mermaid-hud {
        position: absolute;
        top: 8px;
        right: 8px;
        display: flex;
        gap: 2px;
        padding: 3px;
        border-radius: 9px;
        background: color-mix(in srgb, Canvas 75%, transparent);
        backdrop-filter: blur(20px) saturate(160%);
        -webkit-backdrop-filter: blur(20px) saturate(160%);
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.12s ease;
        z-index: 2;
        font-size: 12px;
        line-height: 1;
        color: var(--text);
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12);
    }
    .mermaid-figure:hover .mermaid-hud,
    .mermaid-figure:focus-within .mermaid-hud {
        opacity: 1;
        pointer-events: auto;
    }
    .mermaid-hud-btn {
        appearance: none;
        border: none;
        background: transparent;
        color: inherit;
        font: inherit;
        font-weight: 500;
        padding: 5px 9px;
        border-radius: 6px;
        cursor: pointer;
        min-width: 26px;
        text-align: center;
    }
    .mermaid-hud-btn:hover {
        background: color-mix(in srgb, var(--text) 12%, transparent);
    }
    .mermaid-hud-btn:active {
        background: color-mix(in srgb, var(--text) 18%, transparent);
    }
    .mermaid-hud-level {
        min-width: 46px;
        font-variant-numeric: tabular-nums;
    }
    @media (prefers-reduced-motion: reduce) {
        .mermaid-hud { transition: none; }
    }
    .mermaid-error {
        position: static;
        aspect-ratio: auto;
        padding: 12px 16px;
        text-align: left;
        white-space: pre-wrap;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
    }
    .math-display {
        margin: 1.2em 0 0;
        overflow-x: auto;
        overflow-y: hidden;
    }
    .math-display .katex-display {
        margin: 0;
    }
    .math-error {
        color: #b00020;
        background: var(--code-bg);
        padding: 4px 8px;
        border-radius: 6px;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.88em;
        white-space: pre-wrap;
    }
    @media (prefers-color-scheme: dark) {
        .math-error { color: #ff6e6e; }
    }
    .katex { direction: ltr !important; unicode-bidi: isolate; }

    blockquote {
        margin: 1.2em 0 0;
        padding: 0 0 0 1em;
        border-left: 4px solid var(--quote-border);
        color: var(--secondary);
    }
    blockquote > *:first-child { margin-top: 0; }

    .markdown-alert {
        margin: 1.6em 0 0;
        padding: 12px 16px;
        background: var(--aside-bg);
        border-left: 4px solid var(--aside-border);
        border-radius: 6px;
        color: var(--text);
    }
    .markdown-alert > *:first-child { margin-top: 0; }
    .markdown-alert-title {
        font-weight: 600;
        margin: 0;
        display: flex;
        align-items: center;
        line-height: 1;
    }
    .markdown-alert-icon {
        width: 1em;
        height: 1em;
        margin-right: 0.5em;
        flex: 0 0 auto;
        fill: currentColor;
    }
    .markdown-alert-note { border-left-color: #0969da; }
    .markdown-alert-note .markdown-alert-title { color: #0969da; }
    .markdown-alert-tip { border-left-color: #1a7f37; }
    .markdown-alert-tip .markdown-alert-title { color: #1a7f37; }
    .markdown-alert-important { border-left-color: #8250df; }
    .markdown-alert-important .markdown-alert-title { color: #8250df; }
    .markdown-alert-warning { border-left-color: #9a6700; }
    .markdown-alert-warning .markdown-alert-title { color: #9a6700; }
    .markdown-alert-caution { border-left-color: #d1242f; }
    .markdown-alert-caution .markdown-alert-title { color: #d1242f; }

    ul, ol { margin: 0.8em 0 0; padding-left: 1.6em; }
    li { margin-top: 0.4em; }
    li:first-child { margin-top: 0.8em; }
    li > ul, li > ol { margin-top: 0.4em; }
    li > p:first-child { margin-top: 0; }

    li.task-list-item { list-style: none; }
    li.task-list-item > p:first-of-type { display: inline; margin-top: 0; }
    .task-list-item-checkbox {
        margin: 0 0.4em 0.18em -1.4em;
        vertical-align: middle;
    }

    table {
        margin: 1.6em 0 0;
        border-collapse: collapse;
        display: block;
        overflow-x: auto;
        max-width: 100%;
    }
    th, td {
        padding: 9px 10px;
        border-top: 1px solid var(--grid);
        border-bottom: 1px solid var(--grid);
        text-align: left;
    }
    th { font-weight: 600; }

    hr {
        border: 0;
        height: 1px;
        background: var(--grid);
        margin: 2.35em 0;
    }

    img {
        display: block;
        max-width: 100%;
        height: auto;
        margin: 1.6em auto;
        border-radius: 10px;
    }
    p img {
        display: inline-block;
        vertical-align: middle;
        margin: 0 0.35em 0.35em 0;
    }
    p > img:only-child {
        display: block;
        margin: 1.6em auto;
    }

    strong { font-weight: 600; }
    em { font-style: italic; }

    [dir="rtl"] { text-align: right; }

    """
}
