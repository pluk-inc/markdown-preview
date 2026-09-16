import WebKit
import XCTest
@testable import MarkdownHelpers

/// The document body is delivered inside an inert `<template>` and only
/// reaches the page after DOMPurify has seen it. Everything the sanitizer
/// does rests on the document staying inside that element, so the one thing
/// a document must never manage is closing it early.
///
/// End tags are case-insensitive to the HTML parser. A document containing
/// `</TEMPLATE>` used to terminate the element, and whatever followed was
/// parsed into the live document — where an event-handler attribute fires
/// immediately, before any sanitising. These tests pin both halves: the
/// terminator is escaped whatever its spelling, and nothing a document writes
/// executes.
final class TemplateDeliveryTests: XCTestCase {

    private let payload = #"<img src="x" onerror="window.__executed = true">"#

    /// Every spelling the HTML parser would accept as the end tag.
    private var spellings: [String] {
        ["</template>", "</TEMPLATE>", "</Template>", "</tEmPlAtE>", "</template >", "</TEMPLATE\t>"]
    }

    func testTemplateTerminatorIsEscapedInEverySpelling() {
        for spelling in spellings {
            let html = MarkdownHTML.render(markdown: "Text\n\n\(spelling)\(payload)").html
            let terminators = html.ranges(of: "</template", options: [.caseInsensitive]).count
            XCTAssertEqual(
                terminators, 1,
                """
                \(spelling) survived into the page, so the document can close \
                the article template and escape the sanitizer entirely.
                """
            )
        }
    }

    /// The claim the escape exists to support, asserted end to end: a document
    /// cannot run script in the preview.
    @MainActor
    func testDocumentMarkupCannotExecuteInThePage() async throws {
        for spelling in spellings {
            let executed = try await loadAndReportExecution(
                markdown: "Text\n\n\(spelling)\(payload)"
            )
            XCTAssertFalse(
                executed,
                """
                A document escaped the article template using \(spelling) and \
                its event handler ran in the page.
                """
            )
        }
    }

    @MainActor
    private func loadAndReportExecution(markdown: String) async throws -> Bool {
        let rendered = MarkdownHTML.render(markdown: markdown)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(rendered.html, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !webView.isLoading else { throw WebViewLayoutHarness.Failure("Template page navigation timed out") }
        // The handler fires on the parser's own timeline, not the bootstrap's.
        try await Task.sleep(for: .milliseconds(200))
        let result = try await webView.evaluateJavaScript("window.__executed === true")
        return (result as? Bool) ?? false
    }
}

private extension String {
    func ranges(of search: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var cursor = startIndex
        while let next = range(of: search, options: options, range: cursor..<endIndex) {
            found.append(next)
            cursor = next.upperBound
        }
        return found
    }
}
