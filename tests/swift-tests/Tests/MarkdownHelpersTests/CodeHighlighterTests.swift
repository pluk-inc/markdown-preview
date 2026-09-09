import XCTest
@testable import MarkdownHelpers

/// Render-time highlighting: the same grammar bundle the page ships, run in
/// JavaScriptCore before the HTML leaves Swift.
final class CodeHighlighterTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestVendor.installHighlighterGrammar()
    }

    func testHighlightsKnownLanguagesAndSkipsUnknownOnes() throws {
        XCTAssertTrue(CodeHighlighter.isAvailable)
        let swift = try XCTUnwrap(CodeHighlighter.highlight("let answer = 42", language: "swift"))
        XCTAssertTrue(swift.contains("<span class=\"hljs-keyword\">let</span>"), swift)
        XCTAssertTrue(swift.contains("<span class=\"hljs-number\">42</span>"), swift)
        XCTAssertNil(CodeHighlighter.highlight("plain", language: "no-such-language"))
        XCTAssertNil(CodeHighlighter.highlight("plain", language: ""))
    }

    func testOutputStaysEscaped() throws {
        let html = try XCTUnwrap(CodeHighlighter.highlight("<b>&</b>", language: "html"))
        XCTAssertFalse(html.contains("<b>"))
        XCTAssertTrue(html.contains("&lt;"))
        XCTAssertTrue(html.contains("&amp;"))
    }

    func testShellOptionsAreDecoratedOutsideCommentsAndMeta() throws {
        let code = """
        #!/bin/bash -e
        git status --short
        git log --pretty=format:%h
        xcodebuild --derivedDataPath=/tmp/build
        npx serve-sim --list -q -a -b
        # --ignored
        """
        let html = try XCTUnwrap(CodeHighlighter.highlight(code, language: "bash"))
        let options = try optionSpans(in: html)
        XCTAssertEqual(
            options,
            ["--short", "--pretty", "--derivedDataPath", "--list", "-q", "-a", "-b"],
            html
        )
    }

    func testDetectsUntypedFencesWithTheGrammarBundle() {
        XCTAssertEqual(CodeHighlighter.detectLanguage("def greet(name):\n    return f'hi {name}'"), "python")
        XCTAssertNil(CodeHighlighter.detectLanguage(""))
    }

    func testRenderedCodeArrivesHighlightedAndNeedsNoRuntime() {
        let rendered = MarkdownHTML.render(
            markdown: "```swift\nlet answer = 42\n```",
            vendorLoading: .lazy
        )
        XCTAssertTrue(rendered.articleHTML.contains("data-hljs-done=\"1\""))
        XCTAssertTrue(rendered.articleHTML.contains("hljs-keyword"))
        XCTAssertFalse(rendered.containsCode)
        XCTAssertFalse(rendered.html.contains("highlight.min.js"))
        // The class rules must still reach a page that never loads the runtime.
        XCTAssertTrue(rendered.html.contains(".hljs-keyword"))
        XCTAssertTrue(MarkdownHTML.stylesheet.contains("var(--hl-keyword)"))

        let deferred = MarkdownHTML.render(
            markdown: "```swift\nlet answer = 42\n```",
            vendorLoading: .lazy,
            highlightsCode: false
        )
        XCTAssertFalse(deferred.articleHTML.contains("data-hljs-done"))
        XCTAssertTrue(deferred.containsCode)
    }

    func testUnknownLanguageIsStampedDoneWithPlainText() {
        let rendered = MarkdownHTML.render(
            markdown: "```no-such-language\nplain <text>\n```",
            vendorLoading: .lazy
        )
        XCTAssertTrue(rendered.articleHTML.contains("data-hljs-done=\"1\">plain &lt;text&gt;"))
        XCTAssertFalse(rendered.containsCode)
    }

    private func optionSpans(in html: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"<span class="hljs-attr">([^<]*)</span>"#)
        let nsHTML = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
            .map { nsHTML.substring(with: $0.range(at: 1)) }
    }
}
