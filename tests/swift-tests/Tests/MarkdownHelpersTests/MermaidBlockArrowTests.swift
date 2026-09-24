import WebKit
import XCTest
@testable import MarkdownHelpers

final class MermaidBlockArrowTests: XCTestCase {
    @MainActor
    func testBlockDottedLinksKeepPatternAndArrowheads() async throws {
        let markdown = try String(
            contentsOf: TestVendor.repositoryRoot.appendingPathComponent("samples/mermaid-block-arrows.md"),
            encoding: .utf8
        )
        // Exercise the production HTML and offline bundle used by Quick Look.
        let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .inline)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        webView.loadHTMLString(rendered.html, baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        var edges: [[String: String]] = []
        while Date() < deadline {
            if !webView.isLoading {
                edges = (try await webView.evaluateJavaScript("""
                Array.from(document.querySelectorAll('.mermaid svg path.flowchart-link')).map(path => ({
                    dash: getComputedStyle(path).strokeDasharray,
                    marker: path.getAttribute('marker-end') || ''
                }))
                """)) as? [[String: String]] ?? []
                if edges.count == 3 { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(edges.count, 3, "All block links must render")
        guard edges.count == 3 else { return }
        XCTAssertTrue(["none", "0px"].contains(try XCTUnwrap(edges[0]["dash"])), "The solid link must remain solid")
        for edge in edges.dropFirst() {
            XCTAssertFalse(["none", "0px"].contains(try XCTUnwrap(edge["dash"])), "Dotted links must have a dash pattern")
            XCTAssertFalse(try XCTUnwrap(edge["dash"]).isEmpty)
        }
        for edge in edges {
            XCTAssertTrue(try XCTUnwrap(edge["marker"]).contains("url("), "Every link must retain its arrowhead")
        }
    }
}
