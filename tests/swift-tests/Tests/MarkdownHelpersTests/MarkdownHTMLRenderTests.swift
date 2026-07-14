import XCTest
@testable import MarkdownHelpers

final class MarkdownHTMLRenderTests: XCTestCase {
    func testReadModeLeavesSelectionPaintingToWebKit() {
        let rendered = MarkdownHTML.render(
            markdown: "Select this text.",
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
        let stylesheet = styleBlocks.joined(separator: "\n").lowercased()
        let nonSelectableRules = stylesheet
            .components(separatedBy: "}")
            .filter { $0.contains("user-select: none") }

        XCTAssertFalse(stylesheet.contains("::selection"))
        XCTAssertFalse(stylesheet.contains("::-webkit-selection"))
        XCTAssertFalse(stylesheet.contains("::-moz-selection"))
        XCTAssertEqual(nonSelectableRules.count, 1)
        XCTAssertTrue(nonSelectableRules[0].contains(".md-code-copy"))
    }

    func testBlockquoteUsesItsContentDirectionForLogicalBorder() {
        let rtl = MarkdownHTML.render(
            markdown: "> هذا اقتباس بالعربية.",
            vendorLoading: .lazy
        )
        let ltr = MarkdownHTML.render(
            markdown: "> An English blockquote.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rtl.articleHTML.contains(
            #"<blockquote data-source-line="1" data-source-start="1" data-source-end="1" dir="rtl">"#
        ))
        XCTAssertFalse(ltr.articleHTML.contains(
            #"<blockquote data-source-line="1" data-source-start="1" data-source-end="1" dir="rtl">"#
        ))
        XCTAssertTrue(rtl.html.contains(
            "border-inline-start: 4px solid var(--quote-border);"
        ))
    }

    func testReadOnlyRenderingPreservesActualBlankLineCounts() {
        let rendered = MarkdownHTML.render(
            markdown: "First paragraph.\n\n\n## Heading\n\nSecond paragraph.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<h2 data-source-line=\"4\""
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<p data-source-line=\"6\""
        ))
        XCTAssertTrue(rendered.html.contains(".md-source-blank-line {"))
        XCTAssertTrue(rendered.html.contains("height: 22.8px;"))
    }

    func testMermaidPostProcessingAcceptsSourceMappedPreTag() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<figure data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"4\" class=\"mermaid-figure\""
        ))
        XCTAssertFalse(rendered.articleHTML.contains("<code class=\"language-mermaid\""))
    }

    func testCodeBlockLayoutMatchesDeferredHighlightingFromFirstPaint() throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```swift
            let answer = 42
            ```
            """,
            vendorLoading: .lazy
        )

        let codeRuleStart = try XCTUnwrap(rendered.html.range(of: "pre code {"))
        let codeRuleEnd = try XCTUnwrap(
            rendered.html.range(of: "}", range: codeRuleStart.upperBound..<rendered.html.endIndex)
        )
        let codeRule = rendered.html[codeRuleStart.lowerBound..<codeRuleEnd.upperBound]

        XCTAssertTrue(codeRule.contains("display: block;"))
    }

    func testBlockMathKeepsValidWrapperAndSourceLine() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```math
            E = mc^2
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<div data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"3\" class=\"math math-display\">"
        ), rendered.articleHTML)
        XCTAssertFalse(rendered.articleHTML.contains("<p data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"3\"><div"))
    }

    func testFootnoteRemovalDoesNotShiftFollowingSourceLines() {
        let rendered = MarkdownHTML.render(
            markdown: """
            Prelude.

            Reference.[^note]

            [^note]: First definition line.
                Second definition line.
                Third definition line.

            ## Target
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<h2 data-source-line=\"9\" data-source-start=\"9\" data-source-end=\"9\" id=\"md-heading-0\">Target</h2>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"7\">First definition line."
        ))
    }

    func testFootnoteSourceLinesIncludeFrontmatterOffset() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            title: Footnotes
            ---
            Prelude.

            Reference.[^note]

            [^note]: First definition line.
                Second definition line.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"8\" data-source-start=\"8\" data-source-end=\"9\">First definition line."
        ))
    }

    func testTablesExposeSourceRangeAndStableCellCoordinates() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            title: Editable table
            ---

            | Name | Score |
            | --- | ---: |
            | Ada | 10 |
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<table data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"7\">"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "<th data-table-row=\"0\" data-table-column=\"0\">Name</th>"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "<td data-table-row=\"1\" data-table-column=\"1\" align=\"right\">10</td>"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.html.contains("function enableTableEditing()"))
        XCTAssertFalse(rendered.html.contains("md-table-edge-action"))
        XCTAssertTrue(rendered.html.contains("kind: 'tableContextMenu'"))
        XCTAssertTrue(rendered.html.contains("cell.dataset.placeholder = placeholder"))
        XCTAssertTrue(rendered.html.contains("function selectTablePart(cell, operation)"))
        XCTAssertTrue(rendered.html.contains("event.key === 'Backspace' || event.key === 'Delete'"))
        XCTAssertTrue(rendered.html.contains("selectTableRange(tableCellDrag.cell, cell)"))
        XCTAssertTrue(rendered.html.contains("window.getSelection()?.removeAllRanges()"))
        XCTAssertTrue(rendered.html.contains(".md-table-editor .is-table-selection-left"))
    }

    func testTableCellEditTargetsExactSourceRangeAndEscapesPipes() throws {
        let markdown = """
        Before

        | Name | Value |
        | :--- | ---: |
        | Existing | `a|b` |

        After
        """
        let updated = try XCTUnwrap(MarkdownTableSource.applying(
            .setCell(row: 1, column: 0, markdown: "A | B"),
            fromLine: 3,
            throughLine: 5,
            in: markdown
        ))

        XCTAssertTrue(updated.contains("| A \\| B"), updated)
        XCTAssertTrue(updated.contains("`a|b`"), updated)
        XCTAssertTrue(updated.hasPrefix("Before\n\n"))
        XCTAssertTrue(updated.hasSuffix("\n\nAfter"))
    }

    func testTableRowsAndColumnsCanBeInsertedAndDeleted() throws {
        let markdown = """
        | Name | Value |
        | --- | --- |
        | One | 1 |
        """
        let withRow = try XCTUnwrap(MarkdownTableSource.applying(
            .insertRowAfter(1), fromLine: 1, throughLine: 3, in: markdown
        ))
        XCTAssertEqual(withRow.components(separatedBy: "\n").count, 4)

        let rowBefore = try XCTUnwrap(MarkdownTableSource.applying(
            .insertRowBefore(1), fromLine: 1, throughLine: 3, in: markdown
        ))
        XCTAssertEqual(rowBefore.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(rowBefore.components(separatedBy: "\n")[2]
            .components(separatedBy: "|")
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespaces)
            .isEmpty == true)

        let withColumn = try XCTUnwrap(MarkdownTableSource.applying(
            .insertColumnAfter(0), fromLine: 1, throughLine: 4, in: withRow
        ))
        XCTAssertTrue(withColumn.components(separatedBy: "\n").allSatisfy {
            $0.filter { $0 == "|" }.count == 4
        }, withColumn)

        let columnBefore = try XCTUnwrap(MarkdownTableSource.applying(
            .insertColumnBefore(0), fromLine: 1, throughLine: 3, in: markdown
        ))
        let headerCells = columnBefore.components(separatedBy: "\n")[0]
            .components(separatedBy: "|")
            .dropFirst()
        XCTAssertTrue(headerCells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true)
        XCTAssertEqual(headerCells.dropFirst().first?.trimmingCharacters(in: .whitespaces), "Name")

        let withoutRow = try XCTUnwrap(MarkdownTableSource.applying(
            .deleteRow(2), fromLine: 1, throughLine: 4, in: withColumn
        ))
        let withoutColumn = try XCTUnwrap(MarkdownTableSource.applying(
            .deleteColumn(1), fromLine: 1, throughLine: 3, in: withoutRow
        ))
        XCTAssertEqual(withoutColumn.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(withoutColumn.contains("| Name"))
        XCTAssertTrue(withoutColumn.contains("| One"))
    }
}
