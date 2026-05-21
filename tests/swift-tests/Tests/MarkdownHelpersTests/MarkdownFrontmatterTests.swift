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
        XCTAssertEqual(result.body, markdown)
    }
}
