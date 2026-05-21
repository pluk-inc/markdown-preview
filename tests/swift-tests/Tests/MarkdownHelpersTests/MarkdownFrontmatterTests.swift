import XCTest

@testable import MarkdownHelpers

final class MarkdownFrontmatterTests: XCTestCase {

    func testSplitsYamlFrontmatter() {
        let markdown = """
        ---
        title: Draft
        ---
        # Body
        """

        let result = MarkdownFrontmatter.split(markdown)

        XCTAssertEqual(result.raw, "title: Draft")
        XCTAssertEqual(result.format, .yaml)
        XCTAssertEqual(result.body, "# Body")
    }

    func testSplitsYamlFrontmatterWithEllipsisCloser() {
        let markdown = """
        ---
        title: Draft
        ...
        # Body
        """

        let result = MarkdownFrontmatter.split(markdown)

        XCTAssertEqual(result.raw, "title: Draft")
        XCTAssertEqual(result.format, .yaml)
        XCTAssertEqual(result.body, "# Body")
    }

    func testSplitsTomlFrontmatter() {
        let markdown = """
        +++
        title = "Draft"
        +++
        # Body
        """

        let result = MarkdownFrontmatter.split(markdown)

        XCTAssertEqual(result.raw, #"title = "Draft""#)
        XCTAssertEqual(result.format, .toml)
        XCTAssertEqual(result.body, "# Body")
    }

    func testDoesNotSplitTomlFrontmatterWithYamlCloser() {
        let markdown = """
        +++
        title = "Draft"
        ---
        # Body
        """

        let result = MarkdownFrontmatter.split(markdown)

        XCTAssertNil(result.raw)
        XCTAssertNil(result.format)
        XCTAssertEqual(result.body, markdown)
    }

    func testDoesNotSplitPlusSignsAwayFromDocumentStart() {
        let markdown = """
        # Body

        +++
        title = "Draft"
        +++
        """

        let result = MarkdownFrontmatter.split(markdown)

        XCTAssertNil(result.raw)
        XCTAssertNil(result.format)
        XCTAssertEqual(result.body, markdown)
    }

    func testParsesYamlEntries() {
        let entries = MarkdownFrontmatter.parse("""
        title: Draft
        tags:
          - markdown
        """, format: .yaml)

        XCTAssertEqual(entries, [
            FrontmatterEntry(id: 0, key: "title", value: "Draft"),
            FrontmatterEntry(id: 1, key: "tags", value: "- markdown")
        ])
    }

    func testParsesTomlEntries() {
        let entries = MarkdownFrontmatter.parse("""
        title = "Draft"
        date = "2026-05-21"
        draft = false
        tags = ["markdown", "frontmatter"]
        """, format: .toml)

        XCTAssertEqual(entries, [
            FrontmatterEntry(id: 0, key: "title", value: "Draft"),
            FrontmatterEntry(id: 1, key: "date", value: "2026-05-21"),
            FrontmatterEntry(id: 2, key: "draft", value: "false"),
            FrontmatterEntry(id: 3, key: "tags", value: #"["markdown", "frontmatter"]"#)
        ])
    }
}
