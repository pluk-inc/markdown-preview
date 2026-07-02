import XCTest

@testable import MarkdownHelpers

@MainActor
final class MarkdownSyntaxHighlighterTests: XCTestCase {

    private let highlighter = MarkdownSyntaxHighlighter()

    // MARK: - Helpers

    private func makeStorage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    private func foregroundColor(in storage: NSTextStorage, at location: Int) -> NSColor? {
        guard location < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func font(in storage: NSTextStorage, at location: Int) -> NSFont? {
        guard location < storage.length else { return nil }
        return storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func hasUnderline(in storage: NSTextStorage, at location: Int) -> Bool {
        guard location < storage.length else { return false }
        let value = storage.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int
        return value != nil && value != 0
    }

    // MARK: - Empty / guard

    func testEmptyDocumentDoesNotCrash() {
        let storage = makeStorage("")
        highlighter.applyHighlighting(to: storage)
        XCTAssertEqual(storage.length, 0)
    }

    func testSingleCharacterDocument() {
        let storage = makeStorage("x")
        highlighter.applyHighlighting(to: storage)
        XCTAssertEqual(storage.string, "x")
    }

    // MARK: - Headings

    func testHeadingIsHighlighted() {
        let storage = makeStorage("# Hello World")
        highlighter.applyHighlighting(to: storage)
        let color = foregroundColor(in: storage, at: 0)
        XCTAssertEqual(color, .systemBlue, "Heading should be blue")
        let f = font(in: storage, at: 0)
        XCTAssertEqual(f, NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                       "Heading should be bold")
    }

    func testH3Heading() {
        let storage = makeStorage("### Third level")
        highlighter.applyHighlighting(to: storage)
        XCTAssertEqual(foregroundColor(in: storage, at: 0), .systemBlue)
    }

    func testNonHeadingHashNotHighlighted() {
        let storage = makeStorage("Not a # heading")
        highlighter.applyHighlighting(to: storage)
        // Mid-line # is not a heading
        XCTAssertNotEqual(foregroundColor(in: storage, at: 0), .systemBlue)
    }

    // MARK: - Code fences

    func testCodeFenceIsHighlighted() {
        let text = "```\nlet x = 1\n```"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        // Characters inside the fence should be green
        let insideOffset = (text as NSString).range(of: "let").location
        XCTAssertEqual(foregroundColor(in: storage, at: insideOffset), .systemGreen,
                       "Code fence content should be green")
    }

    func testCodeFenceExcludesInnerPatterns() {
        // A heading inside a code fence should NOT be highlighted as a heading
        let text = "```\n# Not a heading\n```"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let hashOffset = (text as NSString).range(of: "# Not").location
        let color = foregroundColor(in: storage, at: hashOffset)
        XCTAssertEqual(color, .systemGreen, "Heading inside fence should be code-colored, not heading-colored")
        XCTAssertNotEqual(color, .systemBlue)
    }

    func testTildeFence() {
        let text = "~~~\ncode\n~~~"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let codeOffset = (text as NSString).range(of: "code").location
        XCTAssertEqual(foregroundColor(in: storage, at: codeOffset), .systemGreen)
    }

    func testUnclosedFenceHighlightsToEnd() {
        let text = "```\ncode without end"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let codeOffset = (text as NSString).range(of: "code").location
        XCTAssertEqual(foregroundColor(in: storage, at: codeOffset), .systemGreen)
    }

    func testCRLFFenceCloses() {
        // CRLF line endings: the \r before the \n must not defeat the
        // closing-fence detection.
        let text = "```\r\ncode\r\n```\r\n# Heading after fence"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let codeOffset = (text as NSString).range(of: "code").location
        XCTAssertEqual(foregroundColor(in: storage, at: codeOffset), .systemGreen,
                       "Fence content should be code-colored")

        let headingOffset = (text as NSString).range(of: "# Heading").location
        XCTAssertEqual(foregroundColor(in: storage, at: headingOffset), .systemBlue,
                       "Text after a CRLF-terminated closing fence should not be code-colored")
    }

    // MARK: - Inline code

    func testInlineCodeIsHighlighted() {
        let text = "Use `foo()` here"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let tickOffset = (text as NSString).range(of: "`foo()`").location
        XCTAssertEqual(foregroundColor(in: storage, at: tickOffset), .systemGreen)
    }

    // MARK: - Links

    func testLinkIsHighlighted() {
        let text = "Click [here](https://example.com) now"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let linkOffset = (text as NSString).range(of: "[here]").location
        XCTAssertEqual(foregroundColor(in: storage, at: linkOffset), .systemIndigo)
        XCTAssertTrue(hasUnderline(in: storage, at: linkOffset), "Link should be underlined")
    }

    // MARK: - Blockquotes

    func testBlockquoteIsHighlighted() {
        let text = "> This is a quote"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        XCTAssertEqual(foregroundColor(in: storage, at: 0), .systemOrange)
    }

    // MARK: - List markers

    func testUnorderedListMarkerIsHighlighted() {
        let text = "- item one"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        XCTAssertEqual(foregroundColor(in: storage, at: 0), .systemPurple,
                       "List marker should be purple")
    }

    func testOrderedListMarkerIsHighlighted() {
        let text = "1. first item"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        XCTAssertEqual(foregroundColor(in: storage, at: 0), .systemPurple)
    }

    // MARK: - Horizontal rules

    func testHorizontalRuleIsHighlighted() {
        let text = "---"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        XCTAssertEqual(foregroundColor(in: storage, at: 0), .tertiaryLabelColor)
    }

    // MARK: - Bold

    func testBoldIsHighlighted() {
        let text = "Some **bold text** here"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        let boldOffset = (text as NSString).range(of: "bold").location
        let f = font(in: storage, at: boldOffset)
        XCTAssertEqual(f, NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                       "Bold text should use bold font")
    }

    // MARK: - Italic (does not match inside bold)

    func testItalicDoesNotMatchInsideBold() {
        // **bold** should NOT have its inner *bold* matched as italic
        let text = "**bold text**"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        // The inner text should be bold-colored, not italic-colored
        let innerOffset = (text as NSString).range(of: "bold").location
        let color = foregroundColor(in: storage, at: innerOffset)
        XCTAssertNotEqual(color, .secondaryLabelColor,
                          "Bold inner text should not be colored as italic")
    }

    // MARK: - Document size guard

    func testLargeDocumentSkipsHighlighting() {
        // Create a string > 512KB
        let bigText = "# heading\n" + String(repeating: "a", count: 600_000)
        let storage = makeStorage(bigText)
        highlighter.applyHighlighting(to: storage)

        // When the size guard trips, applyHighlighting returns before the
        // base-attribute reset, so the storage keeps its default font (not
        // the highlighter's monospaced base font) and the heading line is
        // never colored.
        XCTAssertNotEqual(font(in: storage, at: 0),
                          NSFont.monospacedSystemFont(ofSize: 13, weight: .bold),
                          "Heading font pass must not run for oversized documents")
        XCTAssertNil(foregroundColor(in: storage, at: 0),
                     "Heading must not be colored when highlighting is skipped")
    }

    // MARK: - Multi-construct document

    func testMixedDocument() {
        let text = "# Heading\n\nSome text with `code` and **bold**.\n\n> A quote\n\n```\nfenced code\n```\n\n- list item"
        let storage = makeStorage(text)
        highlighter.applyHighlighting(to: storage)

        // Just verify it doesn't crash and produces some output
        XCTAssertGreaterThan(storage.length, 0)

        // Heading should be blue
        XCTAssertEqual(foregroundColor(in: storage, at: 0), .systemBlue)

        // Fenced code should be green
        let fencedOffset = (text as NSString).range(of: "fenced").location
        XCTAssertEqual(foregroundColor(in: storage, at: fencedOffset), .systemGreen)
    }

    // MARK: - Idempotency

    func testHighlightingIsIdempotent() {
        let text = "# Hello\n\n`code`\n\n**bold**"
        let storage = makeStorage(text)

        highlighter.applyHighlighting(to: storage)
        let firstPassColor = foregroundColor(in: storage, at: 0)

        highlighter.applyHighlighting(to: storage)
        let secondPassColor = foregroundColor(in: storage, at: 0)

        XCTAssertEqual(firstPassColor, secondPassColor,
                       "Highlighting should produce identical results on re-application")
    }
}
