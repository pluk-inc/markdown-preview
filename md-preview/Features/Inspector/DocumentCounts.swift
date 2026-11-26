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
/// first form of this count (`slow`), so a rule of Unicode (a character of
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
        var body = body
        body.makeContiguousUTF8()
        characters = body.count
        var references = 0
        body.utf8.withContiguousStorageIfAvailable { bytes in
            let count = bytes.count
            var lineStart = 0
            var ascii = true
            var inWord = false
            var lineWords = 0
            var first = -1  // the first byte of the line that is no space and no tab
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
                    let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<end]), as: UTF8.self)
                    let slow = Self.slow(line: line)
                    words += slow.words
                    headings += slow.headings
                    references += slow.references
                    images += slow.images
                }
                ascii = true
                inWord = false
                lineWords = 0
                first = -1
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
                if byte >= 0x80 {
                    ascii = false
                } else if byte == 0x20 || byte == 0x09 {
                    inWord = false
                } else {
                    if !inWord {
                        inWord = true
                        lineWords += 1
                    }
                    if first < 0 { first = Int(byte) }
                }
                index += 1
            }
            endLine(at: count)
            lines = breaks + 1
        }
        links = max(0, references - images)
    }

    /// The counts of one line by the string rules: for a line with a
    /// character that is no ASCII.
    private static func slow(line: String) -> (words: Int, headings: Int, references: Int, images: Int) {
        (line.split { $0.isWhitespace }.count,
         line.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? 1 : 0,
         max(0, line.components(separatedBy: "](").count - 1),
         max(0, line.components(separatedBy: "![").count - 1))
    }
}
