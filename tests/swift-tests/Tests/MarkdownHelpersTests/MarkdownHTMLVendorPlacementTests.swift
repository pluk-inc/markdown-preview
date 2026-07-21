import WebKit
import XCTest
@testable import MarkdownHelpers

/// Placement of the vendor bundles in the rendered document. `.inline`
/// (Quick Look) moves the heavy `<script>` blocks to body-end behind an
/// early populate call so text paints before the bundles parse; `.lazy`
/// (app) keeps its head-only stub layout.
///
/// The SPM test bundle can't resolve the vendored KaTeX/Mermaid/Highlight
/// resources (they live in the Xcode targets), so the emitters fall back —
/// these tests cover the assembly contract `render()` owns: where the early
/// populate call lands, that `.lazy` bodies stay script-free, and that the
/// populate hook actually fills the article at body-parse time.
final class MarkdownHTMLVendorPlacementTests: XCTestCase {
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
        let rendered = MarkdownHTML.render(markdown: sample, vendorLoading: .inline)
        XCTAssertTrue(rendered.containsMath)
        XCTAssertTrue(rendered.containsMermaid)
        XCTAssertTrue(rendered.containsCode)

        let html = rendered.html
        let headEnd = try XCTUnwrap(html.range(of: "</head>"))
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
        let rendered = MarkdownHTML.render(markdown: sample, vendorLoading: .lazy)
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

    /// Renders the sample in `.inline` mode and loads it in a web view. The
    /// SPM bundle has no vendored DOMPurify, so the sanitizer (which the
    /// bootstrap requires before it will populate) is injected from the
    /// repository checkout, together with a probe that snapshots the article
    /// state at DOMContentLoaded.
    @MainActor
    private func loadInlineDocument(warmup: Bool) async throws -> PopulateMetrics {
        let purifyJS = try TestVendor.script("md-preview/Vendor/DOMPurify/purify.min.js")

        let rendered = MarkdownHTML.render(
            markdown: sample,
            vendorLoading: .inline,
            warmup: warmup
        )
        let probe = """
        <script>\(purifyJS)</script>
        <script>
        document.addEventListener('DOMContentLoaded', () => {
            const article = document.querySelector('.markdown-body');
            window.__childrenAtDCL = article ? article.children.length : -1;
        }, { once: true });
        </script>
        """
        let html = rendered.html.replacingOccurrences(
            of: "<head>",
            with: "<head>\n\(probe)"
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

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
