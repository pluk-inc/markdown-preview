//
//  MarkdownHTML+Utils.swift
//  md-preview
//
//  Shared string, regex, and bundle-resource helpers.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    static func bundledVendorURL(_ name: String,
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

    static func bundledVendorResource(_ name: String,
                                              ext: String,
                                              subdir: String) -> String? {
        bundledVendorURL(name, ext: ext, subdir: subdir).flatMap {
            try? String(contentsOf: $0, encoding: .utf8)
        }
    }

    static func replaceMatches(of regex: NSRegularExpression,
                                       in source: String,
                                       transform: (String) -> String) -> String {
        rewrite(matchesOf: regex, in: source, captureGroup: 1, transform: transform)
    }

    static func replaceFullMatches(of regex: NSRegularExpression,
                                           in source: String,
                                           transform: (String) -> String) -> String {
        rewrite(matchesOf: regex, in: source, captureGroup: 0, transform: transform)
    }

    static func rewrite(matchesOf regex: NSRegularExpression,
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

    /// Replaces generated `prefix + decimal index + suffix` placeholders in a
    /// single forward pass. Re-running `replacingOccurrences` once per token
    /// made documents with many code spans, code fences, or footnotes scale
    /// quadratically because each restoration rescanned the whole document.
    static func restoreIndexedTokens(in source: String,
                                             prefix: String,
                                             suffix: String,
                                             replacements: [String]) -> String {
        guard !replacements.isEmpty, source.contains(prefix) else { return source }

        var result = ""
        result.reserveCapacity(source.count)
        var cursor = source.startIndex

        while let tokenStart = source.range(
            of: prefix,
            range: cursor..<source.endIndex
        ) {
            result.append(contentsOf: source[cursor..<tokenStart.lowerBound])

            var digitsEnd = tokenStart.upperBound
            while digitsEnd < source.endIndex, source[digitsEnd].isNumber {
                source.formIndex(after: &digitsEnd)
            }

            guard digitsEnd > tokenStart.upperBound,
                  source[digitsEnd...].hasPrefix(suffix),
                  let index = Int(source[tokenStart.upperBound..<digitsEnd]),
                  replacements.indices.contains(index) else {
                // This prefix can appear in authored Markdown. Preserve it and
                // continue searching after the prefix instead of consuming an
                // unrelated suffix later in the document.
                result.append(contentsOf: source[tokenStart.lowerBound..<tokenStart.upperBound])
                cursor = tokenStart.upperBound
                continue
            }

            result.append(replacements[index])
            cursor = source.index(digitsEnd, offsetBy: suffix.count)
        }

        result.append(contentsOf: source[cursor...])
        return result
    }

    static func htmlEscape(_ string: String) -> String {
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

    static func renderFrontmatter(_ raw: String,
                                          format: MarkdownFrontmatter.Format,
                                          sourceEndLine: Int) -> String {
        let entries = MarkdownFrontmatter.parse(raw, format: format)
        guard !entries.isEmpty else { return "" }

        let rows = entries.map { entry in
            let valueHTML: String
            if let items = entry.items {
                valueHTML = items.map {
                    "<span class=\"md-fm-pill\" dir=\"auto\">\(htmlEscape($0))</span>"
                }.joined()
            } else if entry.value.isEmpty {
                valueHTML = "<span class=\"md-fm-empty\" aria-hidden=\"true\"></span>"
            } else {
                valueHTML = htmlEscape(entry.value)
            }
            return """
            <tr><th scope="row" dir="auto">\(htmlEscape(entry.key))</th><td dir="auto">\(valueHTML)</td></tr>
            """
        }.joined(separator: "\n")

        return """
        <section class="md-frontmatter" data-source-line="1" data-source-start="1" data-source-end="\(max(1, sourceEndLine))">
        <table><tbody>
        \(rows)
        </tbody></table>
        </section>

        """
    }

    // Internal (not private) so regression tests can build JS payloads with
    // the exact escaping the production bridge uses, like `hostBridgeScript`.
    static func javaScriptStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(json.dropFirst().dropLast())
    }

    private final class MarkdownHTMLBundleToken {}

    static func firstMatch(of regex: NSRegularExpression,
                                   in source: String) -> NSTextCheckingResult? {
        let nsSource = source as NSString
        return regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
    }

    // Fenced code block. Group 1 = backtick run, group 2 = info string, group 3 = body.
    static let codeFenceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(?m)^(`{3,})[ \t]*([^\n`]*)\n([\s\S]*?)\n\1[ \t]*$"#
        )
    }()

    // Inline code span: matched-length backtick runs that are not adjacent to other
    // backticks. Mirrors CommonMark so spans like `` ` ```math ` `` (single-backtick
    // delimiters around three inner backticks) tokenize correctly.
    static let inlineCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)([^\n]*?)(?<!`)\1(?!`)"#)
    }()
}
