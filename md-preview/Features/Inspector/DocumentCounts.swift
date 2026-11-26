//
//  DocumentCounts.swift
//  md-preview
//
//  The numbers that the inspector shows for the text of a document.
//

import Foundation

/// The counts of the body of a document (its text after front matter), by
/// the plain rules of the inspector: no parse of the Markdown.
///
/// - words: the runs of characters that are no whitespace.
/// - lines: the pieces between line breaks (each of LF, CR, VT, FF,
///   U+0085, U+2028, U+2029 is one break, so CRLF is two).
/// - headings: the lines whose first character after spaces and tabs is "#".
/// - images: each "![". links: each "](" that is not of an image.
///
/// One pass over the bytes. A line of only ASCII is counted from its bytes;
/// a line with another character goes through the string rules of the
/// first form of this count, each only when the line needs it (it has the
/// bytes that the rule looks for; a space of it can be a part of a longer
/// character), so a rule of Unicode (a character of
/// more than one code point, a space of another script) gives the same
/// number as it did. A long document took 110 ms with those rules alone,
/// and this runs after each key of an edit with the inspector open.
nonisolated struct DocumentCounts: Equatable, Sendable {
    var words = 0
    var characters = 0
    var lines = 0
    var headings = 0
    var links = 0
    var images = 0

    init() {}

    init(body: String) {
        guard !body.isEmpty else { return }
        // A copy that `withUTF8` can make contiguous: it always gives the
        // bytes.
        var body = body
        characters = body.count
        var references = 0
        body.withUTF8 { bytes in
            let count = bytes.count
            var lineStart = 0
            var ascii = true
            var inWord = false
            var lineWords = 0
            var first = -1  // the first byte of the line that is no space and no tab
            // Bytes that the string rules of a line look for: with none of
            // them in the line, that rule has nothing to count.
            var hasSign = false, hasReference = false, hasImage = false
            var before: UInt8 = 0
            // The words of a line with other characters than ASCII are its
            // runs between spaces and tabs too, while each space and tab is
            // a character of its own (`standsAlone`) and the line has no
            // other whitespace. If not, the string rule counts them.
            var wordsFromBytes = true
            var beforeStandsAlone = true
            // The same for the "](" and "![" of such a line: the pairs of
            // its bytes, while no character beside a pair can take a byte
            // of it into a longer character.
            var pairsFromBytes = true
            var lineReferences = 0, lineImages = 0
            var twoBeforeStandsAlone = true
            var afterPair = false
            var breaks = 0
            var index = 0

            func endLine(at end: Int) {
                if ascii {
                    words += lineWords
                    if first == Int(UInt8(ascii: "#")) { headings += 1 }
                    // Pairs of ASCII bytes: no pair is a part of another one.
                    var at = lineStart
                    while at + 1 < end {
                        if bytes[at] == UInt8(ascii: "]"), bytes[at + 1] == UInt8(ascii: "(") {
                            references += 1
                            at += 2
                        } else if bytes[at] == UInt8(ascii: "!"), bytes[at + 1] == UInt8(ascii: "[") {
                            images += 1
                            at += 2
                        } else {
                            at += 1
                        }
                    }
                } else {
                    if wordsFromBytes { words += lineWords }
                    if pairsFromBytes {
                        references += lineReferences
                        images += lineImages
                    }
                    let slowPairs = !pairsFromBytes && (hasReference || hasImage)
                    if !wordsFromBytes || hasSign || slowPairs {
                        let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<end]), as: UTF8.self)
                        if !wordsFromBytes { words += line.split { $0.isWhitespace }.count }
                        if hasSign, line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { headings += 1 }
                        if slowPairs, hasReference { references += max(0, line.components(separatedBy: "](").count - 1) }
                        if slowPairs, hasImage { images += max(0, line.components(separatedBy: "![").count - 1) }
                    }
                }
                ascii = true
                inWord = false
                lineWords = 0
                first = -1
                hasSign = false
                hasReference = false
                hasImage = false
                before = 0
                wordsFromBytes = true
                beforeStandsAlone = true
                pairsFromBytes = true
                lineReferences = 0
                lineImages = 0
                twoBeforeStandsAlone = true
                afterPair = false
            }

            while index < count {
                let byte = bytes[index]
                // The line breaks: LF, VT, FF, CR, U+0085, U+2028, U+2029.
                var breakSize = 0
                if byte >= 0x0A, byte <= 0x0D {
                    breakSize = 1
                } else if byte == 0xC2, index + 1 < count, bytes[index + 1] == 0x85 {
                    breakSize = 2
                } else if byte == 0xE2, index + 2 < count, bytes[index + 1] == 0x80,
                          bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                    breakSize = 3
                }
                if breakSize > 0 {
                    endLine(at: index)
                    breaks += 1
                    index += breakSize
                    lineStart = index
                    continue
                }
                let endsPair = afterPair
                afterPair = false
                if byte == UInt8(ascii: "#") {
                    hasSign = true
                } else if byte == UInt8(ascii: "("), before == UInt8(ascii: "]") {
                    hasReference = true
                    lineReferences += 1
                    afterPair = true
                    if !twoBeforeStandsAlone { pairsFromBytes = false }
                } else if byte == UInt8(ascii: "["), before == UInt8(ascii: "!") {
                    hasImage = true
                    lineImages += 1
                    afterPair = true
                    if !twoBeforeStandsAlone { pairsFromBytes = false }
                }
                if byte >= 0x80 {
                    ascii = false
                    // One code point: its bytes, and what it is beside a
                    // space or a tab.
                    let size = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
                    var value = UInt32(byte) & (size == 4 ? 0x07 : size == 3 ? 0x0F : 0x1F)
                    var next = index + 1
                    while next < index + size, next < count {
                        value = value << 6 | UInt32(bytes[next] & 0x3F)
                        next += 1
                    }
                    let alone = Self.standsAlone(value)
                    if Self.isSpace(value) || (!alone && (before == 0x20 || before == 0x09)) {
                        wordsFromBytes = false
                    }
                    if endsPair, !alone { pairsFromBytes = false }
                    twoBeforeStandsAlone = beforeStandsAlone
                    beforeStandsAlone = alone
                    if !inWord {
                        inWord = true
                        lineWords += 1
                    }
                    before = byte
                    index = next
                    continue
                }
                if byte == 0x20 || byte == 0x09 {
                    inWord = false
                    if !beforeStandsAlone { wordsFromBytes = false }
                } else {
                    if !inWord {
                        inWord = true
                        lineWords += 1
                    }
                    if first < 0 { first = Int(byte) }
                }
                twoBeforeStandsAlone = beforeStandsAlone
                beforeStandsAlone = true
                before = byte
                index += 1
            }
            endLine(at: count)
            lines = breaks + 1
        }
        links = max(0, references - images)
    }

    /// A whitespace character that is no ASCII and no line break.
    private static func isSpace(_ value: UInt32) -> Bool {
        value == 0xA0 || value == 0x1680 || (value >= 0x2000 && value <= 0x200A)
            || value == 0x202F || value == 0x205F || value == 0x3000
    }

    /// A code point that makes no one character with a space or a tab
    /// beside it: a letter with a case, a digit, a punctuation mark, a
    /// symbol, or a letter of Chinese, Japanese, or Korean. Other ones can
    /// (a mark that goes on the space before it, a sign that takes the
    /// space after it), and a space in such a character is no whitespace.
    private static func standsAlone(_ value: UInt32) -> Bool {
        if (value >= 0x3040 && value <= 0x3096) || (value >= 0x30A0 && value <= 0x30FA)
            || (value >= 0x3400 && value <= 0x4DBF) || (value >= 0x4E00 && value <= 0x9FFF)
            || (value >= 0xAC00 && value <= 0xD7A3) {
            return true
        }
        guard let scalar = Unicode.Scalar(value) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .decimalNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
