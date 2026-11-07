//
//  MarkdownTOC.swift
//  md-preview
//

import Foundation
import Markdown

nonisolated struct TOCItem: Identifiable, Hashable, Sendable {
    let id: Int
    let level: Int
    let title: String
    let sourceLine: Int
    var children: [TOCItem]
}

nonisolated enum MarkdownTOC {

    static func parse(_ markdown: String) -> [TOCItem] {
        let headings = extractHeadings(from: markdown)
        return buildTree(headings)
    }

    private struct RawHeading {
        let level: Int
        let title: String
        let sourceLine: Int
    }

    private static func extractHeadings(from markdown: String) -> [RawHeading] {
        // Share the renderer's CommonMark parsing so container nesting and fence
        // delimiters cannot turn code-block contents into outline entries.
        let split = MarkdownFrontmatter.split(markdown)
        let body = split.body
        var collector = HeadingCollector(body: body, sourceLineOffset: split.bodyLineOffset)
        collector.visit(Document(parsing: body))
        return collector.headings
    }

    private struct HeadingCollector: MarkupWalker {
        let body: String
        let sourceLineOffset: Int
        var headings: [RawHeading] = []
        // Only split when a heading has no range, which most documents never hit.
        private lazy var bodyLines = Self.lines(of: body)

        init(body: String, sourceLineOffset: Int) {
            self.body = body
            self.sourceLineOffset = sourceLineOffset
        }

        mutating func visitHeading(_ heading: Heading) {
            // Keep empty headings too: IDs follow rendered heading order.
            headings.append(RawHeading(
                level: heading.level,
                title: Self.titleText(heading),
                sourceLine: startLine(of: heading) + sourceLineOffset
            ))
        }

        private mutating func startLine(of heading: Heading) -> Int {
            if let range = heading.range { return range.lowerBound.line }
            // cmark gives an empty ATX heading after whitespace (`- #`, `> #`, ` #`)
            // an end before its start, and swift-markdown drops that range to nil.
            // Only blank lines, container markers and link reference definitions can
            // come between the previous block and the heading, so it is the first
            // line after that block that ends the way these headings do.
            let index = heading.indexInParent
            let previous = index > 0 ? heading.parent?.child(at: index - 1) : nil
            // A previous heading without a range is the last one collected, on one line.
            let previousEnd = previous?.range?.upperBound.line
                ?? (previous is Heading ? headings.last.map { $0.sourceLine - sourceLineOffset } : nil)
            let first = previousEnd.map { $0 + 1 } ?? heading.parent?.range?.lowerBound.line ?? 1
            return stride(from: first, through: bodyLines.count, by: 1)
                .first { Self.endsInSpacedHeadingMarker(bodyLines[$0 - 1]) } ?? first
        }

        /// Whether a line ends in one to six `#` after a space or tab: the shape
        /// that loses its range. `>#` and `- # ` keep theirs.
        private static func endsInSpacedHeadingMarker(_ line: Substring.UTF8View) -> Bool {
            let marks = line.reversed().prefix { $0 == UInt8(ascii: "#") }.count
            guard (1...6).contains(marks) else { return false }
            let before = line.dropLast(marks).last
            return before == UInt8(ascii: " ") || before == UInt8(ascii: "\t")
        }

        /// Splits at LF, CR and CRLF, as CommonMark counts lines.
        private static func lines(of text: String) -> [Substring.UTF8View] {
            let utf8 = text.utf8
            var lines: [Substring.UTF8View] = []
            var start = utf8.startIndex
            var index = start
            while index != utf8.endIndex {
                let byte = utf8[index]
                guard byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") else {
                    utf8.formIndex(after: &index)
                    continue
                }
                lines.append(utf8[start..<index])
                utf8.formIndex(after: &index)
                if byte == UInt8(ascii: "\r"), index != utf8.endIndex, utf8[index] == UInt8(ascii: "\n") {
                    utf8.formIndex(after: &index)
                }
                start = index
            }
            lines.append(utf8[start...])
            return lines
        }

        private static func titleText(_ markup: Markup) -> String {
            // InlineCode.plainText includes backticks; the outline shows its content.
            if let code = markup as? InlineCode { return code.code }
            if markup.childCount > 0 {
                return markup.children.map { titleText($0) }.joined()
            }
            return (markup as? InlineMarkup)?.plainText ?? ""
        }
    }

    private static func buildTree(_ headings: [RawHeading]) -> [TOCItem] {
        final class Node {
            let level: Int
            let id: Int
            let title: String
            let sourceLine: Int
            var children: [Node] = []
            init(level: Int, id: Int, title: String, sourceLine: Int) {
                self.level = level
                self.id = id
                self.title = title
                self.sourceLine = sourceLine
            }
            func toItem() -> TOCItem {
                TOCItem(id: id, level: level, title: title, sourceLine: sourceLine,
                        children: children.map { $0.toItem() })
            }
        }

        // Synthetic root is not included in the returned outline.
        let root = Node(level: 0, id: -1, title: "", sourceLine: 0)
        var stack: [Node] = [root]

        for (index, heading) in headings.enumerated() {
            while let top = stack.last, top.level >= heading.level {
                stack.removeLast()
            }
            let node = Node(level: heading.level, id: index,
                            title: heading.title, sourceLine: heading.sourceLine)
            stack.last?.children.append(node)
            stack.append(node)
        }

        return root.children.map { $0.toItem() }
    }
}
