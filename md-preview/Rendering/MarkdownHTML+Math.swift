//
//  MarkdownHTML+Math.swift
//  md-preview
//
//  KaTeX math extraction and block rendering.
//

import Foundation
import Markdown

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // MARK: - Math (KaTeX)

    struct MathExtraction {
        let processedMarkdown: String
        let blocks: [String]
        let blockLineCounts: [Int]
        let inlines: [String]
    }

    struct MathRenderResult {
        let html: String
        let containsMath: Bool
    }

    private static let blockMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\$\$([\s\S]+?)\$\$"#)
    }()

    private static let bracketedBlockMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\\\[([\s\S]+?)\\\]"#)
    }()

    private static let singleBackslashBracketRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\\(?:\[|\])"#)
    }()

    // Markdown authors sometimes double the delimiter backslashes so the
    // Markdown parser emits the single-backslash form expected by MathJax.
    // Math is extracted before Markdown parsing here, so accept that source
    // form directly while still rejecting runs of three or more backslashes.
    private static let markdownEscapedBracketedBlockMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\\\\\[([\s\S]+?)\\\\\]"#)
    }()

    // Reject leading `\$` (escaped) and require non-whitespace adjacent to
    // delimiters so prose like "$5 and $10" doesn't match.
    private static let inlineMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\$(?=\S)([^\$\n]+?)(?<=\S)\$"#)
    }()

    private static let parenthesizedInlineMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\\\(([^\n]+?)\\\)"#)
    }()

    private static let markdownEscapedParenthesizedInlineMathRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!\\)\\\\\(([^\n]+?)\\\\\)"#)
    }()


    // First alternative captures attributes+kind+index for a paragraph-wrapped block token
    // (the common case after swift-markdown wraps the standalone token); the
    // second captures a bare token. The wrapper is stripped in either case for
    // block kind to keep the resulting `<div>` out of an enclosing `<p>`.
    private static let mathTokenRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<p\b([^>]*)>MdPreviewMath(Block|Inline)(\d+)Token</p>|MdPreviewMath(Block|Inline)(\d+)Token"#
        )
    }()

    static func extractMath(from markdown: String) -> MathExtraction {
        var blocks: [String] = []
        var blockLineCounts: [Int] = []
        var inlines: [String] = []
        var protected: [String] = []

        // In a valid Markdown link label, `\[` and `\]` are bracket escapes,
        // not display-math delimiters. Protect those ranges before the math
        // pass, then restore them for swift-markdown to parse normally.
        let afterLinkLabels = protectEscapedBracketsInLinks(
            in: markdown,
            protected: &protected
        )

        let nsMarkdown = afterLinkLabels as NSString
        let fenceMatches = codeFenceRegex.matches(
            in: afterLinkLabels,
            range: NSRange(location: 0, length: nsMarkdown.length)
        )
        var afterFences = ""
        afterFences.reserveCapacity(afterLinkLabels.count)
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
                let fullFence = nsMarkdown.substring(with: match.range)
                blockLineCounts.append(fullFence.count(where: \.isNewline) + 1)
                let newlineCount = fullFence.count(where: \.isNewline)
                // Keep the replacement on the opening line and preserve the
                // original number of line breaks so later source ranges remain
                // aligned with the editor buffer.
                afterFences += "MdPreviewMathBlock\(blocks.count - 1)Token"
                afterFences += String(repeating: "\n", count: newlineCount)
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

        func extractBlocks(matching regex: NSRegularExpression, from source: String) -> String {
            let nsSource = source as NSString
            let matches = regex.matches(
                in: source,
                range: NSRange(location: 0, length: nsSource.length)
            )
            var result = ""
            result.reserveCapacity(source.count)
            var cursor = 0
            for match in matches {
                result += nsSource.substring(with: NSRange(
                    location: cursor,
                    length: match.range.location - cursor
                ))
                let capture = nsSource.substring(with: match.range(at: 1))
                let fullMatch = nsSource.substring(with: match.range)
                let newlineCount = fullMatch.count(where: \.isNewline)
                blockLineCounts.append(newlineCount + 1)
                result += "MdPreviewMathBlock\(blocks.count)Token"
                result += String(repeating: "\n", count: newlineCount)
                blocks.append(capture)
                cursor = match.range.location + match.range.length
            }
            result += nsSource.substring(from: cursor)
            return result
        }

        let afterDollarBlockMath = extractBlocks(matching: blockMathRegex, from: afterInlineCode)
        let afterMarkdownEscapedBlockMath = extractBlocks(
            matching: markdownEscapedBracketedBlockMathRegex,
            from: afterDollarBlockMath
        )
        let afterBlockMath = extractBlocks(
            matching: bracketedBlockMathRegex,
            from: afterMarkdownEscapedBlockMath
        )
        let afterDollarInlineMath = replaceMatches(
            of: inlineMathRegex,
            in: afterBlockMath
        ) { capture in
            defer { inlines.append(capture) }
            return "MdPreviewMathInline\(inlines.count)Token"
        }
        let afterMarkdownEscapedInlineMath = replaceMatches(
            of: markdownEscapedParenthesizedInlineMathRegex,
            in: afterDollarInlineMath
        ) { capture in
            defer { inlines.append(capture) }
            return "MdPreviewMathInline\(inlines.count)Token"
        }
        let afterInlineMath = replaceMatches(
            of: parenthesizedInlineMathRegex,
            in: afterMarkdownEscapedInlineMath
        ) { capture in
            defer { inlines.append(capture) }
            return "MdPreviewMathInline\(inlines.count)Token"
        }

        let processed = restoreIndexedTokens(
            in: afterInlineMath,
            prefix: "MdPreviewProtect",
            suffix: "Token",
            replacements: protected
        )

        return MathExtraction(
            processedMarkdown: processed,
            blocks: blocks,
            blockLineCounts: blockLineCounts,
            inlines: inlines
        )
    }

    private static func protectEscapedBracketsInLinks(
        in markdown: String,
        protected: inout [String]
    ) -> String {
        let nsMarkdown = markdown as NSString
        let fullRange = NSRange(location: 0, length: nsMarkdown.length)
        let candidates = singleBackslashBracketRegex.matches(in: markdown, range: fullRange)
        guard !candidates.isEmpty else { return markdown }

        var collector = MarkdownLinkRangeCollector(source: markdown)
        collector.visit(Document(parsing: markdown))
        let matches = candidates.filter { candidate in
            collector.ranges.contains { linkRange in
                candidate.range.location >= linkRange.location
                    && NSMaxRange(candidate.range) <= NSMaxRange(linkRange)
            }
        }
        guard !matches.isEmpty else { return markdown }

        var result = ""
        result.reserveCapacity(markdown.count)
        var cursor = 0
        for match in matches where match.range.location >= cursor {
            result += nsMarkdown.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            protected.append(nsMarkdown.substring(with: match.range))
            result += "MdPreviewProtect\(protected.count - 1)Token"
            cursor = match.range.location + match.range.length
        }
        result += nsMarkdown.substring(from: cursor)
        return result
    }

    static func renderMathBlocks(in html: String,
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
            let wrapped = match.range(at: 2).location != NSNotFound
            let kindRange = wrapped ? match.range(at: 2) : match.range(at: 4)
            let indexRange = wrapped ? match.range(at: 3) : match.range(at: 5)
            let isBlock = nsHtml.substring(with: kindRange) == "Block"
            let index = Int(nsHtml.substring(with: indexRange)) ?? 0
            let latex = isBlock ? math.blocks[index] : math.inlines[index]
            let escaped = htmlEscape(latex)
            var sourceAttributes = wrapped
                ? nsHtml.substring(with: match.range(at: 1))
                : ""
            if isBlock, index < math.blockLineCounts.count {
                sourceAttributes = expandSourceEnd(
                    in: sourceAttributes,
                    lineCount: math.blockLineCounts[index]
                )
            }
            rebuilt += isBlock
                ? "<div\(sourceAttributes) class=\"math math-display\">\(escaped)</div>"
                : "<span class=\"math math-inline\">\(escaped)</span>"
            cursor = match.range.location + match.range.length
        }
        rebuilt += nsHtml.substring(from: cursor)
        return MathRenderResult(html: rebuilt, containsMath: true)
    }

    private static func expandSourceEnd(in attributes: String, lineCount: Int) -> String {
        guard lineCount > 1,
              let startRange = attributes.range(of: #"data-source-start="\d+""#,
                                                options: .regularExpression),
              let start = Int(attributes[startRange].dropFirst(19).dropLast()) else {
            return attributes
        }
        let end = start + lineCount - 1
        return attributes.replacingOccurrences(
            of: #"data-source-end="\d+""#,
            with: "data-source-end=\"\(end)\"",
            options: .regularExpression
        )
    }
}

nonisolated private struct MarkdownLinkRangeCollector: MarkupWalker {
    let source: String
    private let lineStartOffsets: [Int]
    private(set) var ranges: [NSRange] = []

    init(source: String) {
        self.source = source
        var offsets = [0]
        for (offset, byte) in source.utf8.enumerated() where byte == 0x0A {
            offsets.append(offset + 1)
        }
        lineStartOffsets = offsets
    }

    mutating func visitLink(_ link: Link) {
        guard let sourceRange = link.range,
              let lower = index(for: sourceRange.lowerBound),
              let upper = index(for: sourceRange.upperBound),
              lower <= upper else { return }
        ranges.append(NSRange(lower..<upper, in: source))
    }

    private func index(for location: SourceLocation) -> String.Index? {
        guard location.line > 0,
              location.line <= lineStartOffsets.count,
              location.column > 0 else { return nil }
        let offset = lineStartOffsets[location.line - 1] + location.column - 1
        guard let utf8Index = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: offset,
            limitedBy: source.utf8.endIndex
        ) else { return nil }
        return String.Index(utf8Index, within: source)
    }
}
