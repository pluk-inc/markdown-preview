import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorScrollAnchorTests: XCTestCase {
    func testOriginalClearsAnOpenEditorsCustomPageBackground() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(html: EditorHTML.render(
            markdown: "# Original theme", editorJavaScript: script,
            configuration: .init(lightPageBackground: "#abcdef", darkPageBackground: "#123456")),
            width: 500, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        _ = try await editor.webView.evaluateJavaScript(ThemeColorsSetting.styleUpdateScript(
            css: ThemePreset.defaultPreset.setting.editorOverrideCSS))
        let clear = try await editor.webView.evaluateJavaScript("""
            [document.documentElement, document.body, document.querySelector('.cm-editor')]
                .every(element => getComputedStyle(element).backgroundColor === 'rgba(0, 0, 0, 0)')
            """)
        XCTAssertEqual(clear as? Bool, true)
    }

}
