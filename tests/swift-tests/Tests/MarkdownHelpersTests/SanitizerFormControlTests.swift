import WebKit
import XCTest
@testable import MarkdownHelpers

/// Drives the shipped sanitiser — bundled DOMPurify plus
/// `MarkdownHTML.hostBridgeScript` — in a real WKWebView and asserts that
/// document content cannot place a form control on the page.
///
/// CommonMark passes raw HTML through and `EscapingHTMLFormatter` honours that,
/// so DOMPurify is the only thing between a document and the reader here.
final class SanitizerFormControlTests: XCTestCase {

    /// The shape that motivated this: a credential prompt written in raw HTML,
    /// followed by every other control the sanitiser removes. Exercising all of
    /// them matters — with only the form here, dropping tags from FORBID_TAGS
    /// left the assertion passing on zero.
    private let credentialPrompt = """
    # Doc

    <form action="https://example.invalid/collect" method="post">
      <input name="password" type="password">
      <button type="submit">Sign in</button>
    </form>

    <label for="pw">Account password</label>
    <select name="target"><option>Choose an account</option></select>
    <textarea name="notes" rows="3">Paste your recovery phrase</textarea>
    <fieldset><legend>Billing</legend><output name="total">0.00</output></fieldset>
    <datalist id="s"><option value="admin"></option></datalist>
    <input type="text" name="username" list="s">
    """

    @MainActor
    func testFormControlsDoNotSurviveEvenWithoutTheirForm() async throws {
        let webView = try await loadHarness()
        try await render(credentialPrompt, in: webView)

        let raw = try await webView.evaluateJavaScript("""
        (() => {
          const a = document.querySelector('.markdown-body');
          return JSON.stringify({
            forms: a.querySelectorAll('form').length,
            controls: a.querySelectorAll(
              'select, textarea, label, fieldset, legend, output, datalist, option'
            ).length + [...a.querySelectorAll('input')].filter(
              (el) => (el.getAttribute('type') || '').toLowerCase() !== 'checkbox'
            ).length
          });
        })()
        """) as? String ?? "{}"

        XCTAssertTrue(raw.contains("\"forms\":0"), "the form element itself must not survive \(raw)")
        XCTAssertTrue(
            raw.contains("\"controls\":0"),
            """
            A form control survived without its form. DOMPurify's KEEP_CONTENT \
            default unwraps the forbidden <form> and reparents its children, so \
            counting <form> alone does not show whether a document can draw a \
            password field. <button> is not counted here: the app emits its own \
            buttons into the same article HTML, so a surviving button is not \
            evidence of anything. \(raw)
            """
        )
    }

    /// The narrow exception, and the reason `input` is not simply forbidden.
    @MainActor
    func testTaskListCheckboxesStillRenderAndStayClickable() async throws {
        let webView = try await loadHarness()
        try await render("- [ ] todo\n- [x] done\n", in: webView)

        let raw = try await webView.evaluateJavaScript("""
        (() => {
          const a = document.querySelector('.markdown-body');
          const boxes = [...a.querySelectorAll('input[type=checkbox]')];
          return JSON.stringify({
            count: boxes.length,
            disabled: boxes.filter((el) => el.hasAttribute('disabled')).length
          });
        })()
        """) as? String ?? "{}"

        XCTAssertTrue(raw.contains("\"count\":2"),
                      "task-list checkboxes must survive; the input rule is narrow, not blanket \(raw)")
        XCTAssertTrue(
            raw.contains("\"disabled\":0"),
            """
            Task checkboxes came back disabled. DOMPurify strips the `disabled` \
            the renderer emits, and that removal is load-bearing — clicking a \
            checkbox writes the change back to the file. \(raw)
            """
        )
    }

    // MARK: - Harness

    /// The app's own Mermaid controls must survive sanitisation.
    ///
    /// `MarkdownHTML+Mermaid` emits the five HUD buttons as part of the article
    /// HTML, so they pass through DOMPurify like document content. An earlier
    /// version of this patch put `button` in FORBID_TAGS and removed all five —
    /// with no test failing, because every sanitiser assertion checked what must
    /// be *absent* and none checked what must remain.
    @MainActor
    func testMermaidControlsSurviveSanitisation() async throws {
        let webView = try await loadHarness()
        try await render("```mermaid\ngraph TD; A-->B\n```\n", in: webView)
        try await Task.sleep(for: .milliseconds(80))

        let count = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.mermaid-hud button').length"
        ) as? Int ?? 0
        XCTAssertEqual(
            count, 5,
            """
            The Mermaid HUD controls did not survive sanitisation. They are \
            emitted as article HTML, so forbidding <button> deletes zoom out, \
            reset, zoom in, fill width and open-in-window.
            """
        )
    }

    @MainActor
    private func loadHarness() async throws -> WKWebView {
        let purifyJS = try TestVendor.script("md-preview/Vendor/DOMPurify/purify.min.js")
        let morphdomJS = try TestVendor.script("md-preview/Vendor/Morphdom/morphdom.min.js")
        let html = """
        <!DOCTYPE html>
        <html><head>
        <script>\(purifyJS)</script>
        <script>\(morphdomJS)</script>
        <script>
        window.webkit = { messageHandlers: { mdPreviewHost: { postMessage() {} } } };
        </script>
        \(MarkdownHTML.hostBridgeScript)
        </head><body><article class="markdown-body"></article></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: TestVendor.repositoryRoot)
        while webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        return webView
    }

    @MainActor
    private func render(_ markdown: String, in webView: WKWebView) async throws {
        let article = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy).articleHTML
        let literal = MarkdownHTML.javaScriptStringLiteral(article)
        _ = try await webView.evaluateJavaScript("window.MdPreview.update(\(literal)); true")
        try await Task.sleep(for: .milliseconds(50))
    }
}
