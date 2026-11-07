import Markdown
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

    func testCommonHeadingSyntaxAndNonHeadings() {
        let markdown = """
        # First ###
        ### Skipped level
        #\tTabbed marker
           ## Three spaces

            # Indented code

        \\# Escaped marker
        #No space
        ####### Seven hashes

        <!--
        # Comment
        -->

        Last
        ====
        """.replacingOccurrences(of: "\n", with: "\r\n")
        let items = flattened(MarkdownTOC.parse(markdown))
        XCTAssertEqual(items.map(\.title), ["First", "Skipped level", "Tabbed marker", "Three spaces", "Last"])
        XCTAssertEqual(items.map(\.level), [1, 3, 1, 2, 1])
        XCTAssertTrue(MarkdownTOC.parse("").isEmpty)
        XCTAssertTrue(MarkdownTOC.parse("Just a paragraph").isEmpty)
    }

    func testInlineFormattingPreservesLiteralTitleContent() {
        let markdown = #"# **Bold** *italic* ~~deleted~~ [link](https://example.com) `a_b*` &amp; \*literal\* ![alt](image.png)"#
        XCTAssertEqual(MarkdownTOC.parse(markdown).first?.title, "Bold italic deleted link a_b* & *literal* alt")
    }

    func testOutlineChangesOnlyWhenHeadingsChange() {
        let original = "# Original\n\nBody text"
        let editedBody = "# Original\n\nUpdated body text"
        let renamedHeading = "# Renamed\n\nBody text"
        let insertedHeading = "# Original\n\n## New section\n\nBody text"

        XCTAssertEqual(MarkdownTOC.parse(original), MarkdownTOC.parse(editedBody))
        XCTAssertNotEqual(MarkdownTOC.parse(original), MarkdownTOC.parse(renamedHeading))
        XCTAssertNotEqual(MarkdownTOC.parse(original), MarkdownTOC.parse(insertedHeading))
    }

    func testOutlineCanParseOffMainActor() async {
        let titles = await Task.detached {
            MarkdownTOC.parse("# Background\n\nBody").map(\.title)
        }.value
        XCTAssertEqual(titles, ["Background"])
    }

    func testHeadingSourceLinesIncludeFrontmatterAndUnsavedInsertions() {
        let original = "# First\n\n## Second"
        let inserted = "# First\n\n# New\n\n## Second"
        XCTAssertEqual(flattened(MarkdownTOC.parse(original)).map(\.sourceLine), [1, 3])
        XCTAssertEqual(flattened(MarkdownTOC.parse(inserted)).map(\.sourceLine), [1, 3, 5])

        // Both empty frontmatter and blank lines inside it must be accounted for.
        let withFrontmatter = "---\n\ntitle: Example\n---\n# First\n\nSetext\n------"
        XCTAssertEqual(flattened(MarkdownTOC.parse(withFrontmatter)).map(\.sourceLine), [5, 7])
    }

    func testOutlineIDsAndLevelsMatchRenderedArticle() throws {
        let markdown = """
        ---
        title: Example
        ---
        # Root
        > ## Quoted heading

        - ### List heading

          ~~~~text
          # Hidden
          ```
          ~~~~

        Setext heading
        --------------

        ##
        - #

        > #

        ## **Final** `a_b`
        """
        let items = flattened(MarkdownTOC.parse(markdown))
        let html = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy).articleHTML as NSString
        let regex = try NSRegularExpression(pattern: #"<h([1-6])[^>]* id="md-heading-(\d+)">"#)
        let matches = regex.matches(in: html as String, range: NSRange(location: 0, length: html.length))
        XCTAssertEqual(matches.count, 8)
        XCTAssertEqual(items.map(\.level), matches.compactMap { Int(html.substring(with: $0.range(at: 1))) })
        XCTAssertEqual(items.map(\.id), matches.compactMap { Int(html.substring(with: $0.range(at: 2))) })
    }

    func testEmptyHeadingsWithoutParsedRangeKeepOrderAndSourceLines() {
        // cmark gives these headings an inverted range, so they reach the
        // outline without a source range (#626).
        let cases: [(String, [Int])] = [
            ("- #", [1]),
            ("> #", [1]),
            (" #", [1]),
            ("   #", [1]),
            ("1. #", [1]),
            ("- ##", [1]),
            ("- ######", [1]),
            ("- a\n  - #", [2]),
            ("# A\n\n #\n\n## B", [1, 3, 5]),
            ("> a\n>\n> #\n\n# B", [3, 5]),
            ("- a\n\n  #\n- b", [3]),
            (" #\n #\n\n # \n- #", [1, 2, 4, 5]),
            ("---\ntitle: x\n---\n- #\n# After", [4, 5]),
        ]
        for (markdown, lines) in cases {
            let items = flattened(MarkdownTOC.parse(markdown + "\n"))
            XCTAssertEqual(items.map(\.sourceLine), lines, markdown)
            XCTAssertEqual(items.map(\.id), Array(lines.indices), markdown)
        }

        // Empty headings that keep their range are unchanged.
        for markdown in ["- # x", "#", ">#", "- # ", "- # #"] {
            XCTAssertEqual(flattened(MarkdownTOC.parse(markdown + "\n")).map(\.sourceLine), [1], markdown)
        }
    }

    func testSwiftMarkdownStillDropsInvertedEmptyHeadingRange() {
        // Tracks an upstream parser bug: cmark ends `- #` before it starts and
        // swift-markdown drops the range to nil. When this fails, the parser is
        // fixed: remove the fallback in MarkdownTOC's startLine(of:) and this
        // test, and keep the tests above.
        let heading = Document(parsing: "- #\n").child(at: 0)?.child(at: 0)?.child(at: 0)
        XCTAssertTrue(heading is Heading)
        XCTAssertNil(heading?.range)
    }
}
