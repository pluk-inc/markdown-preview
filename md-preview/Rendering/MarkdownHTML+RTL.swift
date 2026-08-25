//
//  MarkdownHTML+RTL.swift
//  md-preview
//
//  Right-to-left direction detection and dir attribute injection.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // MARK: - RTL Direction

    // Matches opening block-level tags whose direction controls alignment and
    // logical-edge styling such as blockquote borders.
    private static let rtlTagRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<(blockquote|p|li|h[1-6])(\s[^>]*)?>"#,
            options: [.caseInsensitive]
        )
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

    /// Over-inclusive by design: CommonMark decodes numeric character
    /// references before formatting, so any `&#` might become RTL text.
    /// False positives only take the existing slow path; false negatives
    /// would skip direction inference.
    static func sourceMayNeedRTLDirection(_ source: String) -> Bool {
        var previousWasAmpersand = false
        for scalar in source.unicodeScalars {
            if scalar.value >= 0x0590,
               scalar.value <= 0xFEFF,
               isRTL(scalar) {
                return true
            }
            if previousWasAmpersand, scalar.value == 0x23 {
                return true
            }
            previousWasAmpersand = scalar.value == 0x26
        }
        return false
    }

    static func injectRTLDirection(in html: String) -> String {
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
        return isRTL(scalar)
    }

    private static func isRTL(_ scalar: Unicode.Scalar) -> Bool {
        return rtlRanges.contains { $0.contains(scalar.value) }
    }
}
