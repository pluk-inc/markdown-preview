import XCTest

@testable import MarkdownHelpers

final class DocumentCountsTests: XCTestCase {
    /// The rules of the inspector as it had them, with the strings of
    /// Foundation: what `DocumentCounts` must give for each text.
    private func reference(_ body: String) -> DocumentCounts {
        var counts = DocumentCounts()
        let lines = body.components(separatedBy: .newlines)
        counts.characters = body.count
        counts.words = body.split { $0.isWhitespace }.count
        counts.lines = body.isEmpty ? 0 : lines.count
        counts.headings = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
        let references = max(0, body.components(separatedBy: "](").count - 1)
        counts.images = max(0, body.components(separatedBy: "![").count - 1)
        counts.links = max(0, references - counts.images)
        return counts
    }

    func testCountsOfPlainText() {
        let counts = DocumentCounts(body: "# Title\n\nTwo words [a](b) ![c](d)\n  ## Sub\n")
        XCTAssertEqual(counts.words, 8)
        XCTAssertEqual(counts.lines, 5)
        XCTAssertEqual(counts.headings, 2)
        XCTAssertEqual(counts.links, 1)
        XCTAssertEqual(counts.images, 1)
        XCTAssertEqual(DocumentCounts(body: ""), DocumentCounts())
    }

    func testSameNumbersAsTheStringRules() {
        let cases = [
            "", " ", "\n", "a", "a\n", "\r\n", "a\r\nb", "a\rb\n\nc", "a\u{0B}b\u{0C}c",
            "a\u{85}b", "a\u{2028}b\u{2029}c", "\t# heading after a tab\n #", "#\n# \n#x",
            "\u{A0}# after a no-break space", "\u{3000}# after an ideographic space",
            "]([a](b)](", "![![a](b)!](c)", "! [a] (b)", "[a]\n(b)", "!\n[",
            "word\u{301} e\u{301}\u{302} \u{301}alone", "a \u{301}b", "a\n\u{301}b", "a\r\u{301}b",
            "日本語の 文章 です。\n# 見出し\n", "مرحبا بالعالم", "👨‍👩‍👧‍👦 family 🇯🇵 flag",
            "a\u{200B}b c\u{2003}d", "a\u{0}b \u{0}# no heading", "\u{0}", "x\u{1F}y\u{1C}z",
            "](\u{301} and ![\u{301}", "#\u{301} heading with a mark on its sign",
            "tab\tseparated\twords", "trailing spaces   \n   leading", "\u{FEFF}# after a mark",
        ]
        for text in cases {
            XCTAssertEqual(DocumentCounts(body: text), reference(text), text.debugDescription)
        }
    }

    func testSameNumbersForTheSampleDocuments() throws {
        let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../samples")
        let files = try FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(DocumentCounts(body: text), reference(text), file.lastPathComponent)
        }
    }

    func testSameNumbersForRandomText() {
        // With characters that join the space beside them into one
        // character: marks, joiners, signs that go before a letter, emoji
        // modifiers, Hangul parts, tag characters.
        let pieces = ["a", "b", " ", " ", " ", "\t", "\n", "\n", "\r", "\r\n", "#", "# ", "](", "![", "!", "[", "]", "(",
                      "\u{301}", "\u{200D}", "\u{200C}", "é", "日", "あ", "한", "👍", "\u{A0}", "\u{2028}", "\u{85}",
                      "\u{0B}", "\u{0C}", "\u{3000}", "\u{2003}", "\u{0}", "word", "\u{FE0F}", "🇯", "🇵",
                      "\u{201C}", "\u{201D}", "\u{2014}", "\u{600}", "\u{110BD}", "\u{D4E}", "\u{1F3FB}",
                      "\u{E33}", "\u{903}", "\u{FF9E}", "\u{1100}", "\u{1161}", "\u{11A8}", "\u{E0020}",
                      "\u{20E3}", "\u{34F}", "\u{AD}", "\u{200B}", "\u{FEFF}", "€", "×", "\u{2028}"]
        var generator = SystemRandomNumberGenerator()
        for round in 0..<20000 {
            var text = ""
            for _ in 0..<Int.random(in: 0...24, using: &generator) {
                text += pieces.randomElement(using: &generator)!
            }
            let got = DocumentCounts(body: text), want = reference(text)
            if got != want {
                XCTFail("round \(round): \(text.debugDescription): \(got), not \(want)")
                return
            }
        }
    }
}
