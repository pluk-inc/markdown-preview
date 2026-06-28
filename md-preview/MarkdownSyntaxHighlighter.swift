//
//  MarkdownSyntaxHighlighter.swift
//  md-preview
//

import Cocoa

final class MarkdownSyntaxHighlighter {

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

    func applyHighlighting(to textStorage: NSTextStorage) {
        let length = textStorage.length
        guard length > 0 else { return }

        let fullRange = NSRange(location: 0, length: length)
        let string = textStorage.string as NSString

        textStorage.beginEditing()

        textStorage.setAttributes(
            [.font: baseFont, .foregroundColor: NSColor.labelColor],
            range: fullRange
        )

        let fenceRanges = highlightCodeFences(in: textStorage, string: string)

        applyPattern(
            "`[^`\\n]+`",
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { _ in
            [.font: self.baseFont, .foregroundColor: self.codeColor]
        }

        applyPattern(
            "(?m)^#{1,6}\\s+.*$",
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { _ in
            [.font: self.headingFont, .foregroundColor: self.headingColor]
        }

        applyPattern(
            "(\\*\\*|__)(.+?)\\1",
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
            "\\*[^*\\n]+\\*",
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { _ in
            [.font: self.baseFont, .foregroundColor: self.italicColor]
        }

        applyPattern(
            "\\[([^\\]]+)\\]\\(([^)]+)\\)",
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { _ in
            [
                .font: self.baseFont,
                .foregroundColor: self.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }

        applyPattern(
            "(?m)^>\\s+.*$",
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { _ in
            [.font: self.baseFont, .foregroundColor: self.blockquoteColor]
        }

        applyPattern(
            "(?m)^[\\t ]*([-*+]|\\d+\\.)\\s",
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
            "(?m)^[-*_]{3,}\\s*$",
            in: textStorage,
            string: string,
            excluding: fenceRanges
        ) { _ in
            [.font: self.baseFont, .foregroundColor: self.commentColor]
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
            let line = string.substring(with: lineRange)
            let lineContent = line.hasSuffix("\n") ? String(line.dropLast()) : line
            let lineNSString = lineContent as NSString

            if !inFence {
                if let match = fenceOpenRegex?.firstMatch(
                    in: lineContent,
                    range: NSRange(location: 0, length: lineNSString.length)
                ) {
                    delimiter = lineNSString.substring(with: match.range(at: 1))
                    inFence = true
                    applyCodeStyle(to: textStorage, range: lineRange)
                    protectedRanges.append(lineRange)
                }
            } else {
                applyCodeStyle(to: textStorage, range: lineRange)
                protectedRanges.append(lineRange)

                if lineNSString.length >= delimiter.count {
                    let prefix = lineNSString.substring(with: NSRange(location: 0, length: delimiter.count))
                    if prefix == delimiter {
                        let rest = lineNSString.substring(
                            from: delimiter.count
                        ).trimmingCharacters(in: .whitespaces)
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

    private func intersectsProtected(_ range: NSRange, protected: [NSRange]) -> Bool {
        protected.contains { NSIntersectionRange($0, range).length > 0 }
    }

    private func applyPattern(
        _ pattern: String,
        in textStorage: NSTextStorage,
        string: NSString,
        excluding protected: [NSRange],
        attributes: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let searchRange = NSRange(location: 0, length: string.length)
        regex.enumerateMatches(in: string as String, range: searchRange) { match, _, _ in
            guard let match else { return }
            guard !self.intersectsProtected(match.range, protected: protected) else { return }
            textStorage.addAttributes(attributes(match), range: match.range)
        }
    }

    private func applyPattern(
        _ pattern: String,
        in textStorage: NSTextStorage,
        string: NSString,
        excluding protected: [NSRange],
        attributes: (NSTextCheckingResult) -> (range: NSRange, attributes: [NSAttributedString.Key: Any])
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let searchRange = NSRange(location: 0, length: string.length)
        regex.enumerateMatches(in: string as String, range: searchRange) { match, _, _ in
            guard let match else { return }
            let result = attributes(match)
            guard !self.intersectsProtected(result.range, protected: protected) else { return }
            textStorage.addAttributes(result.attributes, range: result.range)
        }
    }
}
