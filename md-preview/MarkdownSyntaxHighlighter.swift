//
//  MarkdownSyntaxHighlighter.swift
//  md-preview
//

import Cocoa

/// Applies regex-based syntax highlighting to Markdown source text in an `NSTextStorage`.
///
/// Highlights headings, bold, italic, code (inline and fenced), links, blockquotes,
/// list markers, and horizontal rules. Code fences are detected first and excluded
/// from all subsequent pattern matches.
///
/// - Important: Must be called on the main thread. For documents larger than 512 KB,
///   highlighting is skipped to avoid blocking the UI.
@MainActor
final class MarkdownSyntaxHighlighter {

    private static let maxHighlightLength = 512_000  // 512 KB

    // Theme colors — adapts to light/dark mode via semantic colors
    private let headingColor: NSColor = .systemBlue
    private let boldColor: NSColor = .labelColor
    private let italicColor: NSColor = .secondaryLabelColor
    private let codeColor: NSColor = .systemGreen
    private let linkColor: NSColor = .systemIndigo
    private let blockquoteColor: NSColor = .systemOrange
    private let listMarkerColor: NSColor = .systemPurple
    private let commentColor: NSColor = .tertiaryLabelColor

    private let baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private let headingFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private let boldFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)

    private lazy var fenceOpenRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(`{3,}|~{3,})")
    }()

    private let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private let headingRegex = try! NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$")
    private let boldRegex = try! NSRegularExpression(pattern: "(\\*\\*|__)(.+?)\\1")
    private let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)")
    private let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")
    private let blockquoteRegex = try! NSRegularExpression(pattern: "(?m)^>\\s+.*$")
    private let listMarkerRegex = try! NSRegularExpression(pattern: "(?m)^[\\t ]*([-*+]|\\d+\\.)\\s")
    private let hruleRegex = try! NSRegularExpression(pattern: "(?m)^[-*_]{3,}\\s*$")

    /// Resets all attributes to the base style, then applies Markdown syntax highlighting.
    ///
    /// Call this after any text change. The method processes the full document — for
    /// incremental use, callers should debounce invocations.
    ///
    /// - Parameter textStorage: The text storage to highlight. Must not be empty.
    func applyHighlighting(to textStorage: NSTextStorage) {
        let length = textStorage.length
        guard length > 0, length <= Self.maxHighlightLength else { return }

        let fullRange = NSRange(location: 0, length: length)
        let string = textStorage.string as NSString

        textStorage.beginEditing()

        textStorage.setAttributes(
            [.font: baseFont, .foregroundColor: NSColor.labelColor],
            range: fullRange
        )

        let fenceRanges = highlightCodeFences(in: textStorage, string: string)

        applyPattern(
            inlineCodeRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            (range: match.range, attributes: [
                .font: self.baseFont,
                .foregroundColor: self.codeColor,
            ])
        }

        applyPattern(
            headingRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            (range: match.range, attributes: [
                .font: self.headingFont,
                .foregroundColor: self.headingColor,
            ])
        }

        applyPattern(
            boldRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            let innerRange = match.range(at: 2)
            return (range: innerRange, attributes: [
                .font: self.boldFont,
                .foregroundColor: self.boldColor,
            ])
        }

        applyPattern(
            italicRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            (range: match.range, attributes: [
                .font: self.baseFont,
                .foregroundColor: self.italicColor,
            ])
        }

        applyPattern(
            linkRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            (range: match.range, attributes: [
                .font: self.baseFont,
                .foregroundColor: self.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        }

        applyPattern(
            blockquoteRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            (range: match.range, attributes: [
                .font: self.baseFont,
                .foregroundColor: self.blockquoteColor,
            ])
        }

        applyPattern(
            listMarkerRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            let markerRange = match.range(at: 1)
            return (range: markerRange, attributes: [
                .font: self.baseFont,
                .foregroundColor: self.listMarkerColor,
            ])
        }

        applyPattern(
            hruleRegex,
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { match in
            (range: match.range, attributes: [
                .font: self.baseFont,
                .foregroundColor: self.commentColor,
            ])
        }

        textStorage.endEditing()
    }

    // MARK: - Code fences

    private func highlightCodeFences(in textStorage: NSTextStorage, string: NSString) -> [NSRange] {
        var protectedRanges: [NSRange] = []
        var index = 0
        var inFence = false
        var delimiter = ""

        while index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            var contentRange = lineRange
            // Strip the line terminator: \n, \r, or the \r of a \r\n pair —
            // a leftover \r would defeat the closing-fence emptiness check
            // on CRLF files (CharacterSet.whitespaces excludes \r).
            if contentRange.length > 0,
               string.character(at: NSMaxRange(contentRange) - 1) == 0x0A {
                contentRange.length -= 1
            }
            if contentRange.length > 0,
               string.character(at: NSMaxRange(contentRange) - 1) == 0x0D {
                contentRange.length -= 1
            }

            if !inFence {
                if let match = fenceOpenRegex?.firstMatch(
                    in: string as String,
                    range: contentRange
                ) {
                    delimiter = string.substring(with: match.range(at: 1))
                    inFence = true
                    applyCodeStyle(to: textStorage, range: lineRange)
                    protectedRanges.append(lineRange)
                }
            } else {
                applyCodeStyle(to: textStorage, range: lineRange)
                protectedRanges.append(lineRange)

                if contentRange.length >= delimiter.count {
                    let prefixRange = NSRange(location: contentRange.location, length: delimiter.count)
                    let prefix = string.substring(with: prefixRange)
                    if prefix == delimiter {
                        let restRange = NSRange(
                            location: contentRange.location + delimiter.count,
                            length: contentRange.length - delimiter.count
                        )
                        let rest = string.substring(with: restRange).trimmingCharacters(in: .whitespaces)
                        if rest.isEmpty {
                            inFence = false
                            delimiter = ""
                        }
                    }
                }
            }

            let nextIndex = NSMaxRange(lineRange)
            if nextIndex <= index { break }
            index = nextIndex
        }

        return protectedRanges
    }

    private func applyCodeStyle(to textStorage: NSTextStorage, range: NSRange) {
        textStorage.addAttributes(
            [.font: baseFont, .foregroundColor: codeColor],
            range: range
        )
    }

    // MARK: - Regex helpers

    private func binaryIntersects(_ range: NSRange, sortedProtected: [NSRange]) -> Bool {
        var lo = 0, hi = sortedProtected.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(sortedProtected[mid]) <= range.location {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        for i in lo ..< min(lo + 2, sortedProtected.count) {
            if NSIntersectionRange(sortedProtected[i], range).length > 0 { return true }
        }
        return false
    }

    private func applyPattern(
        _ regex: NSRegularExpression,
        in textStorage: NSTextStorage,
        string: NSString,
        excluding protected: [NSRange],
        handler: (NSTextCheckingResult) -> (range: NSRange, attributes: [NSAttributedString.Key: Any])
    ) {
        let searchRange = NSRange(location: 0, length: string.length)
        regex.enumerateMatches(in: string as String, range: searchRange) { match, _, _ in
            guard let match else { return }
            let result = handler(match)
            guard !self.binaryIntersects(result.range, sortedProtected: protected) else { return }
            textStorage.addAttributes(result.attributes, range: result.range)
        }
    }
}
