import XCTest
@testable import MarkdownHelpers

final class MarkdownHTMLRenderTests: XCTestCase {
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
}
