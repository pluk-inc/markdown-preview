import XCTest
@testable import MarkdownHelpers

final class MarkdownHTMLRenderTests: XCTestCase {
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

        XCTAssertTrue(rendered.articleHTML.contains("<figure data-source-line=\"1\" class=\"mermaid-figure\""))
        XCTAssertFalse(rendered.articleHTML.contains("<code class=\"language-mermaid\""))
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

        XCTAssertTrue(rendered.articleHTML.contains("<div data-source-line=\"1\" class=\"math math-display\">"))
        XCTAssertFalse(rendered.articleHTML.contains("<p data-source-line=\"1\"><div"))
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

        XCTAssertTrue(rendered.articleHTML.contains("<h2 data-source-line=\"9\" id=\"md-heading-0\">Target</h2>"))
        XCTAssertTrue(rendered.articleHTML.contains("<p data-source-line=\"5\">First definition line."))
    }
}
