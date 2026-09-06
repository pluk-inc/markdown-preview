import XCTest

@testable import MarkdownHelpers

final class MarkdownTOCTests: XCTestCase {
    private func flattened(_ items: [TOCItem]) -> [TOCItem] {
        items.flatMap { [$0] + flattened($0.children) }
    }

    func testListFenceDoesNotHideFollowingHeadingOrExposeCodeHeadings() {
        for opener in ["- ```", "* ```", "+ ```", "1. ```", "1) ```", "> - ```"] {
            let indent = opener.hasPrefix("1") ? "   " : "  "
            let quote = opener.hasPrefix(">") ? "> " : ""
            let markdown = """
            ## Code block inside a list item

            \(opener)
            \(quote)    foo
            \(quote)\(indent)```

            ## Code block containing ATX headings

            ```text
            # foo
            ## foo
            ### foo
            #### foo
            ##### foo
            ###### foo
            ```
            """
            let items = flattened(MarkdownTOC.parse(markdown))
            XCTAssertEqual(items.map(\.title), ["Code block inside a list item", "Code block containing ATX headings"], opener)
            XCTAssertEqual(items.map(\.id), [0, 1], opener)
        }
    }

    func testFenceCloserMustMatchCharacterLengthAndHaveNoInfoString() {
        for (open, inner, close) in [
            ("````text", "- ```\n    foo\n  ```", "````"),
            ("~~~~", "```\n# hidden\n```", "~~~~"),
            ("````", "```\n# hidden", "`````"),
            ("```", "```text\n# hidden", "```"),
        ] {
            let markdown = "## Before\n\n\(open)\n\(inner)\n\(close)\n\n## After\n\n```text\n# hidden\n```"
            XCTAssertEqual(flattened(MarkdownTOC.parse(markdown)).map(\.title), ["Before", "After"])
        }
    }

    func testUnclosedListFenceEndsWithItsContainer() {
        let markdown = "# Before\n\n- ```\n  # hidden\n\n# After"
        XCTAssertEqual(flattened(MarkdownTOC.parse(markdown)).map(\.title), ["Before", "After"])
    }

    func testFrontmatterDoesNotCreateOutlineHeadings() {
        let markdown = "---\n# Metadata comment\ntitle: Example\n---\n# Body"
        let items = flattened(MarkdownTOC.parse(markdown))
        XCTAssertEqual(items.map(\.title), ["Body"])
        XCTAssertEqual(items.map(\.id), [0])
    }

    func testHeadingHierarchyAndIDsFollowMarkdownDocumentOrder() {
        let markdown = """
        # **Root**
        > ## [Link](https://example.com)

        - ### `child_name`

        Setext
        ------

        ##
        ## Last
        """
        let roots = MarkdownTOC.parse(markdown)
        let items = flattened(roots)
        XCTAssertEqual(items.map(\.title), ["Root", "Link", "child_name", "Setext", "", "Last"])
        XCTAssertEqual(items.map(\.id), Array(0...5))
        XCTAssertEqual(items.map(\.level), [1, 2, 3, 2, 2, 2])
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots[0].children.count, 4)
    }
}
