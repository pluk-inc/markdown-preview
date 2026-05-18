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
            html.contains(#"<pre><code class="language-mermaid">"#),
            "expected language-mermaid class (metadata after space ignored): \(html)"
        )
        XCTAssertFalse(
            html.contains("some-name"),
            "metadata after the language word must not leak into the class attribute: \(html)"
        )
    }
}
