import WebKit
import XCTest
@testable import MarkdownHelpers

/// Placement of the vendor bundles in the rendered document. `.inline`
/// (Quick Look) moves the heavy `<script>` blocks to body-end behind an
/// early populate call so text paints before the bundles parse; `.lazy`
/// (app) keeps its head-only stub layout.
///
/// These tests load the real vendor resources and cover the assembly contract
/// `render()` owns: where early population lands, whether `.lazy` bodies stay
/// script-free, and whether the article fills at body-parse time.
final class MarkdownHTMLVendorPlacementTests: XCTestCase {
    func testProductionVendorResourcesResolve() throws {
        for (name, directory) in [("purify.min", "DOMPurify"), ("mermaid.min", "Mermaid"),
                                  ("katex.min", "KaTeX"), ("highlight.min", "Highlight"),
                                  ("morphdom.min", "Morphdom"), ("mdedit.min", "CodeMirror")] {
            let source = try XCTUnwrap(MarkdownHTML.bundledVendorResource(name, ext: "js", subdir: "Vendor/\(directory)"),
                                      "Missing production asset \(directory)/\(name).js")
            XCTAssertGreaterThan(source.utf8.count, 1000)
        }
    }

    private let sample = """
    # Title

    Inline math $x^2$ and a paragraph.

    ```swift
    let answer = 42
    ```

    ```mermaid
    graph TD; A-->B;
    ```
    """

    private let earlyPopulateCall = "MdPreview.populateNow && MdPreview.populateNow()"

    func testInlineModeEmitsEarlyPopulateAfterTemplate() throws {
        let rendered = MarkdownHTML.render(markdown: sample, vendorLoading: .inline, highlightsCode: false)
        XCTAssertTrue(rendered.containsMath)
        XCTAssertTrue(rendered.containsMermaid)
        XCTAssertTrue(rendered.containsCode)

        let html = rendered.html
        // DOMPurify contains its own HTML-document string inside JavaScript.
        let headEnd = try XCTUnwrap(html.range(of: "\n</head>\n<body>"))
        let templateEnd = try XCTUnwrap(html.range(of: "</template>"))
        let head = html[..<headEnd.lowerBound]
        let bodyEnd = html[templateEnd.upperBound...]

        // The populate hook is exposed by the head bridge and called from a
        // body-end script sitting between the template and the vendor blocks.
        XCTAssertTrue(head.contains("window.MdPreview.populateNow = populateFromTemplate;"))
        XCTAssertFalse(head.contains(earlyPopulateCall))
        XCTAssertTrue(bodyEnd.contains(earlyPopulateCall))
    }

    func testLazyModeKeepsBodyFreeOfVendorScripts() throws {
        let rendered = MarkdownHTML.render(markdown: sample, vendorLoading: .lazy, highlightsCode: false)
        XCTAssertTrue(rendered.containsMath)
        XCTAssertTrue(rendered.containsMermaid)
        XCTAssertTrue(rendered.containsCode)

        // The app path is unchanged: nothing between the template and </body>.
        XCTAssertTrue(rendered.html.contains("</template>\n</body>"))
        XCTAssertFalse(rendered.html.contains(earlyPopulateCall))
    }

    @MainActor
    func testInlineDocumentPopulatesArticleBeforeDOMContentLoaded() async throws {
        let metrics = try await loadInlineDocument(warmup: false)
        XCTAssertTrue(metrics.templateGone)
        XCTAssertGreaterThan(metrics.childrenAtDCL, 0,
                             "article should be populated before DOMContentLoaded")
        XCTAssertGreaterThan(metrics.articleChildren, 0)
        XCTAssertEqual(metrics.opacity, "")
    }

    @MainActor
    func testInlineWarmupDocumentStaysHiddenAfterEarlyPopulate() async throws {
        let metrics = try await loadInlineDocument(warmup: true)
        XCTAssertTrue(metrics.templateGone)
        XCTAssertGreaterThan(metrics.childrenAtDCL, 0)
        XCTAssertEqual(metrics.opacity, "0", "warmup keepHidden must survive the early populate")
    }

    private struct PopulateMetrics: Decodable {
        let templateGone: Bool
        let articleChildren: Int
        let childrenAtDCL: Int
        let opacity: String
    }

    /// Loads the real `.inline` page with a probe that snapshots the article
    /// state at DOMContentLoaded.
    @MainActor
    private func loadInlineDocument(warmup: Bool) async throws -> PopulateMetrics {
        let rendered = MarkdownHTML.render(
            markdown: sample,
            vendorLoading: .inline,
            warmup: warmup
        )
        let probe = """
        <script>
        document.addEventListener('DOMContentLoaded', () => {
            const article = document.querySelector('.markdown-body');
            window.__childrenAtDCL = article ? article.children.length : -1;
        }, { once: true });
        </script>
        """
        // Replace only the actual opening tag. Vendor JavaScript also contains
        // literal "<head>" strings; global replacement corrupts those scripts.
        let head = try XCTUnwrap(rendered.html.range(of: "<head>"))
        let html = rendered.html.replacingCharacters(in: head, with: "<head>\n\(probe)")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !webView.isLoading else { throw WebViewLayoutHarness.Failure("Inline page navigation timed out") }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const article = document.querySelector('.markdown-body');
            return JSON.stringify({
                templateGone: !document.getElementById('md-article-source'),
                articleChildren: article ? article.children.length : -1,
                childrenAtDCL: window.__childrenAtDCL ?? -1,
                opacity: article ? article.style.opacity : 'missing',
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        return try JSONDecoder().decode(PopulateMetrics.self, from: Data(json.utf8))
    }
}
