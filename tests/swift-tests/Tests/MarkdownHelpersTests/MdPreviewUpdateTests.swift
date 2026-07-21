import XCTest
import WebKit
@testable import MarkdownHelpers

/// Drives the exact `MdPreview.update` pipeline the app ships — bundled
/// DOMPurify + morphdom plus `MarkdownHTML.hostBridgeScript` — in a real
/// WKWebView and asserts the morphdom fast path preserves finished renderer
/// output (KaTeX/Mermaid/highlight.js stand-ins) across an update that only
/// touches unrelated prose, while the warmup article keeps taking the
/// innerHTML replace.
final class MdPreviewUpdateTests: XCTestCase {
    @MainActor
    func testMorphdomUpdatePreservesRenderedBlocksAndDetailsState() async throws {
        let webView = try await loadHarness(articleAttributes: "")

        func articleHTML(paragraph: String) -> String {
            MarkdownHTML.render(
                markdown: """
                \(paragraph)

                Euler: $x^2$ inline.

                ```mermaid
                flowchart LR
                    A --> B
                ```

                ```swift
                let answer = 42
                ```

                <details open>
                <summary>More</summary>

                Hidden content.

                </details>
                """,
                vendorLoading: .lazy
            ).articleHTML
        }
        let docV1 = MarkdownHTML.javaScriptStringLiteral(articleHTML(paragraph: "Intro paragraph, first draft."))
        let docV2 = MarkdownHTML.javaScriptStringLiteral(articleHTML(paragraph: "Intro paragraph, edited draft."))

        _ = try await webView.evaluateJavaScript(
            "window.MdPreview.update(\(docV1)); true"
        )
        try await waitForFakeRenderers(in: webView, count: 3)

        // Tag node identity and collapse the <details> so the second update
        // has user state to preserve.
        let tagged = try await webView.evaluateJavaScript("""
        (() => {
            let i = 0;
            document.querySelectorAll('.math, .mermaid-figure .mermaid, pre > code').forEach((el) => {
                el.__ident = ++i;
            });
            document.querySelector('details').open = false;
            return i;
        })()
        """) as? Int
        XCTAssertEqual(tagged, 3)

        _ = try await webView.evaluateJavaScript(
            "window.MdPreview.update(\(docV2)); true"
        )

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const article = document.querySelector('.markdown-body');
            const math = article.querySelector('.math');
            const mermaid = article.querySelector('.mermaid-figure .mermaid');
            const code = article.querySelector('pre > code');
            return JSON.stringify({
                mathIdent: math.__ident || 0,
                mathRenders: math.__renderCount || 0,
                mathDone: math.dataset.mathDone || '',
                mathSentinel: !!math.querySelector('.fake-katex'),
                mermaidIdent: mermaid.__ident || 0,
                mermaidRenders: mermaid.__renderCount || 0,
                mermaidDone: mermaid.dataset.mmDone || '',
                mermaidSentinel: !!mermaid.querySelector('.fake-mermaid'),
                codeIdent: code.__ident || 0,
                codeRenders: code.__renderCount || 0,
                codeDone: code.dataset.hljsDone || '',
                codeSentinel: !!code.querySelector('.fake-hljs'),
                paragraphText: article.querySelector('p').textContent,
                detailsOpen: article.querySelector('details').open,
                keyedBlocks: article.querySelectorAll('[data-md-key]').length,
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let state = try JSONDecoder().decode(MdPreviewUpdateState.self, from: Data(json.utf8))

        // The morphdom path actually ran: only keyExpensiveBlocks stamps keys.
        XCTAssertGreaterThanOrEqual(state.keyedBlocks, 3, json)
        // Unchanged expensive blocks kept their identity and rendered output.
        XCTAssertEqual(state.mathIdent, 1, json)
        XCTAssertEqual(state.mermaidIdent, 2, json)
        XCTAssertEqual(state.codeIdent, 3, json)
        XCTAssertEqual(state.mathRenders, 1, json)
        XCTAssertEqual(state.mermaidRenders, 1, json)
        XCTAssertEqual(state.codeRenders, 1, json)
        XCTAssertEqual(state.mathDone, "1")
        XCTAssertEqual(state.mermaidDone, "1")
        XCTAssertEqual(state.codeDone, "1")
        XCTAssertTrue(state.mathSentinel, json)
        XCTAssertTrue(state.mermaidSentinel, json)
        XCTAssertTrue(state.codeSentinel, json)
        // The changed paragraph morphed to the new text.
        XCTAssertEqual(state.paragraphText, "Intro paragraph, edited draft.")
        // The user's collapse survived the incoming `open` attribute.
        XCTAssertFalse(state.detailsOpen, json)
    }

    @MainActor
    func testWarmupArticleTakesInnerHTMLReplaceBeforeMorphing() async throws {
        let webView = try await loadHarness(
            articleAttributes: " data-warmup=\"1\" style=\"opacity:0;pointer-events:none\""
        )

        func articleHTML(paragraph: String) -> String {
            MarkdownHTML.render(
                markdown: """
                \(paragraph)

                ```swift
                let answer = 42
                ```
                """,
                vendorLoading: .lazy
            ).articleHTML
        }
        let warmupDoc = MarkdownHTML.javaScriptStringLiteral(articleHTML(paragraph: "Synthetic warmup."))
        let realDoc = MarkdownHTML.javaScriptStringLiteral(articleHTML(paragraph: "Real document."))
        let editedDoc = MarkdownHTML.javaScriptStringLiteral(articleHTML(paragraph: "Real document, edited."))

        // Hidden warmup populate keeps the flag, so the first real document
        // is still a guaranteed clean innerHTML replace, not a morph against
        // synthetic content.
        _ = try await webView.evaluateJavaScript(
            "window.MdPreview.update(\(warmupDoc), { keepHidden: true }); true"
        )
        try await waitForFakeRenderers(in: webView, count: 1)
        let afterWarmup = try await stateJSON(in: webView)
        XCTAssertEqual(afterWarmup.warmup, "1", afterWarmup.raw)
        XCTAssertEqual(afterWarmup.opacity, "0", afterWarmup.raw)
        XCTAssertEqual(afterWarmup.keyedBlocks, 0, afterWarmup.raw)

        _ = try await webView.evaluateJavaScript(
            "window.MdPreview.update(\(realDoc)); true"
        )
        let afterReal = try await stateJSON(in: webView)
        XCTAssertEqual(afterReal.warmup, "", afterReal.raw)
        XCTAssertEqual(afterReal.opacity, "", afterReal.raw)
        // Fallback path never stamps keys — the swap was an innerHTML replace.
        XCTAssertEqual(afterReal.keyedBlocks, 0, afterReal.raw)
        XCTAssertEqual(afterReal.paragraphText, "Real document.")

        _ = try await webView.evaluateJavaScript(
            "window.MdPreview.update(\(editedDoc)); true"
        )
        let afterEdit = try await stateJSON(in: webView)
        // With the warmup retired, subsequent updates take the morph path.
        XCTAssertGreaterThanOrEqual(afterEdit.keyedBlocks, 1, afterEdit.raw)
        XCTAssertEqual(afterEdit.paragraphText, "Real document, edited.")

        let codeSurvived = try await webView.evaluateJavaScript("""
        (() => {
            const code = document.querySelector('pre > code');
            return code.dataset.hljsDone === '1' && (code.__renderCount || 0) === 1;
        })()
        """) as? Bool
        XCTAssertEqual(codeSurvived, true)
    }

    /// Builds the harness page — bundled DOMPurify + morphdom, the shipped
    /// host bridge, and fake renderers that mimic the real markers: stash
    /// `__mdSrc`, set the done flag, replace the children with a sentinel,
    /// and count runs so a destructive re-render (fresh node, count reset)
    /// is detectable.
    @MainActor
    private func loadHarness(articleAttributes: String) async throws -> WKWebView {
        let purifyJS = try TestVendor.script("md-preview/Vendor/DOMPurify/purify.min.js")
        let morphdomJS = try TestVendor.script("md-preview/Vendor/Morphdom/morphdom.min.js")
        let fakeRenderers = """
        <script>
        (() => {
            function renderFake() {
                document.querySelectorAll('.math:not([data-math-done="1"])').forEach((el) => {
                    el.__mdSrc = el.textContent;
                    el.dataset.mathDone = '1';
                    el.__renderCount = (el.__renderCount || 0) + 1;
                    el.innerHTML = '<span class="fake-katex">rendered-math</span>';
                });
                document.querySelectorAll('.mermaid-figure .mermaid:not([data-mm-done="1"])').forEach((el) => {
                    el.__mdSrc = el.textContent;
                    el.dataset.mmDone = '1';
                    el.__renderCount = (el.__renderCount || 0) + 1;
                    el.innerHTML = '<svg class="fake-mermaid"></svg>';
                });
                document.querySelectorAll('pre code[class*="language-"]:not([data-hljs-done="1"])').forEach((el) => {
                    el.__mdSrc = el.textContent;
                    el.dataset.hljsDone = '1';
                    el.__renderCount = (el.__renderCount || 0) + 1;
                    el.innerHTML = '<span class="fake-hljs">highlighted</span>';
                });
            }
            window.MdPreview.registerReapplier(renderFake);
        })();
        </script>
        """
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <script>\(purifyJS)</script>
        <script>\(morphdomJS)</script>
        \(MarkdownHTML.hostBridgeScript)
        \(fakeRenderers)
        </head><body>
        <article class="markdown-body"\(articleAttributes)></article>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: TestVendor.repositoryRoot)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        return webView
    }

    @MainActor
    private func waitForFakeRenderers(in webView: WKWebView, count: Int) async throws {
        for _ in 0..<100 {
            let rendered = try await webView.evaluateJavaScript("""
            document.querySelectorAll('[data-math-done="1"], [data-mm-done="1"], [data-hljs-done="1"]').length === \(count)
            """) as? Bool
            if rendered == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func stateJSON(in webView: WKWebView) async throws -> WarmupArticleState {
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const article = document.querySelector('.markdown-body');
            return JSON.stringify({
                warmup: article.dataset.warmup || '',
                opacity: article.style.opacity,
                keyedBlocks: article.querySelectorAll('[data-md-key]').length,
                paragraphText: article.querySelector('p')?.textContent || '',
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        var state = try JSONDecoder().decode(WarmupArticleState.self, from: Data(json.utf8))
        state.raw = json
        return state
    }

}

private struct MdPreviewUpdateState: Decodable {
    let mathIdent: Int
    let mathRenders: Int
    let mathDone: String
    let mathSentinel: Bool
    let mermaidIdent: Int
    let mermaidRenders: Int
    let mermaidDone: String
    let mermaidSentinel: Bool
    let codeIdent: Int
    let codeRenders: Int
    let codeDone: String
    let codeSentinel: Bool
    let paragraphText: String
    let detailsOpen: Bool
    let keyedBlocks: Int
}

private struct WarmupArticleState: Decodable {
    let warmup: String
    let opacity: String
    let keyedBlocks: Int
    let paragraphText: String
    var raw: String = ""

    private enum CodingKeys: String, CodingKey {
        case warmup, opacity, keyedBlocks, paragraphText
    }
}
