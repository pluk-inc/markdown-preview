//
//  MarkdownTOC.swift
//  md-preview
//

import Foundation
import Markdown

struct TOCItem: Identifiable, Hashable {
    let id: Int
    let level: Int
    let title: String
    var children: [TOCItem]
}

enum MarkdownTOC {

    static func parse(_ markdown: String) -> [TOCItem] {
        let headings = extractHeadings(from: markdown)
        return buildTree(headings)
    }

    private struct RawHeading {
        let level: Int
        let title: String
    }

    private static func extractHeadings(from markdown: String) -> [RawHeading] {
        // Share the renderer's CommonMark parsing so container nesting and fence
        // delimiters cannot turn code-block contents into outline entries.
        let body = MarkdownFrontmatter.split(markdown).body
        var collector = HeadingCollector()
        collector.visit(Document(parsing: body))
        return collector.headings
    }

    private struct HeadingCollector: MarkupWalker {
        var headings: [RawHeading] = []

        mutating func visitHeading(_ heading: Heading) {
            // Keep empty headings too: IDs follow rendered heading order.
            headings.append(RawHeading(level: heading.level, title: Self.titleText(heading)))
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
            var children: [Node] = []
            init(level: Int, id: Int, title: String) {
                self.level = level
                self.id = id
                self.title = title
            }
            func toItem() -> TOCItem {
                TOCItem(id: id, level: level, title: title, children: children.map { $0.toItem() })
            }
        }

        let root = Node(level: 0, id: -1, title: "")
        var stack: [Node] = [root]

        for (index, heading) in headings.enumerated() {
            while let top = stack.last, top.level >= heading.level {
                stack.removeLast()
            }
            let node = Node(level: heading.level, id: index, title: heading.title)
            stack.last?.children.append(node)
            stack.append(node)
        }

        return root.children.map { $0.toItem() }
    }
}
