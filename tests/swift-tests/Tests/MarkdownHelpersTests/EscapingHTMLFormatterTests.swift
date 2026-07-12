import XCTest
@testable import MarkdownHelpers

// Info-string parsing is covered by CodeFenceInfoTests. This single test just
// confirms the formatter wires that parser into the `language-` class so the
// trailing metadata (e.g. ```mermaid some-name) does not leak into HTML.
final class EscapingHTMLFormatterTests: XCTestCase {

    func testFencedCodeBlockSetsLanguageClassFromFirstInfoWord() {
        let html = EscapingHTMLFormatter.format("""
        ```mermaid some-name
        graph TD
        ```
        """)
        XCTAssertTrue(
            html.contains(#"<pre data-source-line="1" data-source-start="1" data-source-end="3"><code class="language-mermaid">"#),
            "expected language-mermaid class (metadata after space ignored): \(html)"
        )
        XCTAssertFalse(
            html.contains("some-name"),
            "metadata after the language word must not leak into the class attribute: \(html)"
        )
    }

    func testGitHubAlertWithDefaultTitle() {
        let html = EscapingHTMLFormatter.format("""
        > [!IMPORTANT]
        > Body text.
        """)
        XCTAssertTrue(
            html.contains(#"<div class="markdown-alert markdown-alert-important">"#),
            "expected alert wrapper: \(html)"
        )
        XCTAssertTrue(
            html.contains(#"<p class="markdown-alert-title"><svg class="markdown-alert-icon""#),
            "expected title with leading icon SVG: \(html)"
        )
        XCTAssertTrue(html.contains("Important</p>"), "expected default title text: \(html)")
        XCTAssertTrue(html.contains("<p>Body text.</p>"), "expected body paragraph: \(html)")
        XCTAssertFalse(html.contains("<blockquote"), "alert should replace blockquote: \(html)")
    }

    func testGitHubAlertWithCustomTitle() {
        let html = EscapingHTMLFormatter.format("""
        > [!WARNING] Something specific
        > Multi
        > line body.
        """)
        XCTAssertTrue(html.contains("markdown-alert-warning"), "expected warning kind: \(html)")
        XCTAssertTrue(html.contains("Something specific</p>"), "expected custom title text: \(html)")
        XCTAssertTrue(
            html.contains("Multi<br />\nline body."),
            "expected body line break to remain visible: \(html)"
        )
    }

    func testSoftBreakRendersAsVisibleLineBreak() {
        let html = EscapingHTMLFormatter.format("First line\nSecond line")
        XCTAssertTrue(
            html.contains("First line<br />\nSecond line"),
            "expected a source newline to remain visible: \(html)"
        )
    }

    func testEveryPrecedingBlankSourceLineIsRecorded() {
        let html = EscapingHTMLFormatter.format("First paragraph.\n\n\nSecond paragraph.")
        XCTAssertTrue(
            html.contains(
                "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<p data-source-line=\"4\" data-source-start=\"4\" data-source-end=\"4\">Second paragraph.</p>"
            ),
            "expected both empty source lines to be preserved: \(html)"
        )
    }

    func testSourceMarkdownExcludesRemovedContentFromBlankLineCount() {
        let html = EscapingHTMLFormatter.format(
            "Before.\n\n\n\nAfter.",
            sourceMarkdown: "Before.\n\n[^note]: Removed.\n\nAfter."
        )
        XCTAssertTrue(
            html.contains(
                "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<p data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"5\">After.</p>"
            ),
            "removed source content must not become extra visual blank lines: \(html)"
        )
        XCTAssertEqual(html.components(separatedBy: "md-source-blank-line").count - 1, 1)
    }

    func testGitHubAlertTagIsCaseInsensitive() {
        let html = EscapingHTMLFormatter.format("> [!tIp] Pro move")
        XCTAssertTrue(
            html.contains(#"<div class="markdown-alert markdown-alert-tip">"#),
            "case-insensitive tag should match: \(html)"
        )
        XCTAssertTrue(html.contains("Pro move</p>"), "expected custom title text: \(html)")
    }

    func testGitHubAlertSupportsInlineFormattingInCustomTitle() {
        let html = EscapingHTMLFormatter.format("> [!NOTE] With **bold** title")
        XCTAssertTrue(
            html.contains("With <strong>bold</strong> title</p>"),
            "inline formatting in title should be rendered: \(html)"
        )
    }

    func testGitHubAlertIncludesOcticonSVG() {
        let html = EscapingHTMLFormatter.format("> [!NOTE]")
        XCTAssertTrue(
            html.contains(#"<svg class="markdown-alert-icon" viewBox="0 0 16 16""#),
            "expected Octicon SVG markup: \(html)"
        )
        XCTAssertTrue(html.contains("<path d=\""), "expected path data: \(html)")
    }

    func testUnknownAlertTagFallsBackToBlockquote() {
        let html = EscapingHTMLFormatter.format("> [!FOO] Nope")
        XCTAssertTrue(
            html.contains(#"<blockquote data-source-line="1" data-source-start="1" data-source-end="1">"#),
            "unknown tag should be a source-mapped plain blockquote: \(html)"
        )
        XCTAssertFalse(html.contains("markdown-alert"), "no alert wrapper for unknown tag: \(html)")
    }

    func testQuotedBlankLinesRenderAsPlainBlockquote() {
        let html = EscapingHTMLFormatter.format("""
        > All canon is stored as markdown files.
        >
        > Markdown files are the authoritative source of truth.
        >
        > Agent modifications must be applied through patches whenever possible.
        >
        > Generated content is disposable.
        >
        > Canon is permanent.
        """)

        XCTAssertTrue(
            html.contains(#"<blockquote data-source-line="1" data-source-start="1" data-source-end="9">"#),
            "expected source-mapped plain blockquote wrapper: \(html)"
        )
        XCTAssertTrue(
            html.contains(#"<p data-source-line="1" data-source-start="1" data-source-end="1">All canon is stored as markdown files.</p>"#),
            "expected first quote paragraph: \(html)"
        )
        XCTAssertTrue(
            html.contains(#"<p data-source-line="9" data-source-start="9" data-source-end="9">Canon is permanent.</p>"#),
            "expected final quote paragraph: \(html)"
        )
        XCTAssertFalse(html.contains("<pre><code"), "blockquote must not render as a code block: \(html)")
    }

    func testGitHubAlertEscapesPlainTextInCustomTitle() {
        // Ampersands and lone `<`/`>` in text should round-trip as entities.
        // Inline HTML (e.g. <script>) is parsed as InlineHTML and passed
        // through by design — DOMPurify handles that at render time.
        let html = EscapingHTMLFormatter.format("> [!CAUTION] R&D < 5")
        XCTAssertTrue(
            html.contains("R&amp;D &lt; 5"),
            "custom title plain text must be HTML-escaped: \(html)"
        )
    }
}
