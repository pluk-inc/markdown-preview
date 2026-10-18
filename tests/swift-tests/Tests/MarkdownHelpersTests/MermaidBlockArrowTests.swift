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
                Array.from(document.querySelectorAll('.mermaid svg .pele-edge')).map(edge => ({
                    dash: getComputedStyle(edge.querySelector('path:not(.pele-marker)')).strokeDasharray,
                    marker: edge.querySelector('path.pele-marker') ? 'arrowhead' : ''
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
            XCTAssertEqual(edge["marker"], "arrowhead", "Every link must retain its arrowhead")
        }
    }

    /// Pele reads frontmatter only from the first line, so the figure must
    /// hold the fence's text exactly, with no line break added before it.
    @MainActor
    func testFrontmatterDiagramRenders() async throws {
        let markdown = """
        ```mermaid
        ---
        title: Reef animals
        ---
        classDiagram
            Animal <|-- Turtle
            Animal : +int age
        ```
        """
        let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .inline)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        webView.loadHTMLString(rendered.html, baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        var state = ""
        while Date() < deadline {
            if !webView.isLoading {
                state = (try await webView.evaluateJavaScript("""
                (() => {
                    const figure = document.querySelector('.mermaid-figure');
                    if (!figure) return '';
                    if (figure.classList.contains('mermaid-error')) return 'error';
                    return figure.querySelector('.mermaid svg.pele-class') ? 'class' : '';
                })()
                """)) as? String ?? ""
                if !state.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(state, "class", "A frontmatter diagram must render as its type, not as an error")
    }
}
