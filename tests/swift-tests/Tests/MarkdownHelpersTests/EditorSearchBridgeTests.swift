import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorSearchBridgeTests: XCTestCase {
    private final class Messages: NSObject, WKScriptMessageHandler {
        var results: [[String: Int]] = []

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  body["kind"] as? String == "findResult",
                  let index = body["index"] as? Int,
                  let total = body["total"] as? Int else { return }
            results.append(["index": index, "total": total])
        }
    }

    func testProductionPageExposesSearchAndReportsEditedMatchCounts() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let html = EditorHTML.render(markdown: "needle first\n\nneedle second", editorJavaScript: script)
        let editor = WebViewLayoutHarness(html: html, width: 900, isEditor: true)
        let messages = Messages()
        editor.webView.configuration.userContentController.add(messages, name: "mdEditorHost")
        defer {
            editor.webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdEditorHost")
            editor.close()
        }
        _ = try await editor.layout(texts: ["needle first", "needle second"], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            const first = window.__mdEditor.find('needle', false, false);
            const next = window.__mdEditor.find('needle', false, false);
            const highlighted = document.querySelector('.cm-find-current')?.textContent;
            window.__mdEditor.replaceMarkdown('needle first');
            return { first: first.index, next: next.index, total: next.total, highlighted };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["first"] as? Int, 1)
        XCTAssertEqual(values["next"] as? Int, 2)
        XCTAssertEqual(values["total"] as? Int, 2)
        XCTAssertEqual(values["highlighted"] as? String, "needle")

        let deadline = Date().addingTimeInterval(2)
        while messages.results.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(messages.results.last, ["index": 1, "total": 1])
    }
}
