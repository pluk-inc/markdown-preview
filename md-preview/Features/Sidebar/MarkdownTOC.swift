//
//  MarkdownTOC.swift
//  md-preview
//

import Foundation

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
        var result: [RawHeading] = []
        var inFence = false

        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for raw in lines {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence { continue }

            guard let heading = parseATXHeading(line) else { continue }
            result.append(heading)
        }

        return result
    }

    private static func parseATXHeading(_ line: String) -> RawHeading? {
        let chars = Array(line)
        var i = 0

        // Up to 3 leading spaces (CommonMark).
        var leading = 0
        while i < chars.count, chars[i] == " ", leading < 3 {
            i += 1
            leading += 1
        }

        var hashes = 0
        while i < chars.count, chars[i] == "#", hashes < 7 {
            hashes += 1
            i += 1
        }
        guard hashes >= 1, hashes <= 6 else { return nil }

        // Heading marker must be followed by a space or end of line.
        if i < chars.count, chars[i] != " " { return nil }
        if i < chars.count { i += 1 }

        var rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)

        // Strip optional trailing closing hashes (CommonMark ATX closing sequence).
        if let trimmedClose = stripClosingHashes(rest) { rest = trimmedClose }

        let cleaned = stripInlineMarkers(rest)
        guard !cleaned.isEmpty else { return nil }

        return RawHeading(level: hashes, title: cleaned)
    }

    private static func stripClosingHashes(_ text: String) -> String? {
        guard let lastNonSpace = text.lastIndex(where: { $0 != " " }),
              text[lastNonSpace] == "#" else { return nil }

        var idx = lastNonSpace
        while idx > text.startIndex, text[idx] == "#" {
            idx = text.index(before: idx)
        }
        // Need whitespace before the hash run for it to count as a closer.
        guard idx >= text.startIndex, text[idx] == " " else { return nil }
        return String(text[..<idx]).trimmingCharacters(in: .whitespaces)
    }

    private static func stripInlineMarkers(_ text: String) -> String {
        var s = text

        // [label](url) → label
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
        }

        // Remove emphasis / code markers.
        for marker in ["**", "__", "*", "_", "`", "~~"] {
            s = s.replacingOccurrences(of: marker, with: "")
        }

        return s.trimmingCharacters(in: .whitespaces)
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
