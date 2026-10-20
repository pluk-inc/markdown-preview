import XCTest
import WebKit
@testable import MarkdownHelpers

/// A completed task is muted, not struck through, and only by its own
/// checkbox (pluk-inc/markdown-preview#465): a checked sub-item must not mark
/// its parent done, and a checked parent must not mute unchecked sub-items.
@MainActor
final class TaskListCompletionTests: XCTestCase {
    func testPreviewMutesOnlyItemsWhoseOwnCheckboxIsChecked() async throws {
        let markdown = """
            - [ ] item
              - [x] sub-item 1
              - [ ] sub-item 2
            - [x] done parent

              done paragraph
              - [ ] open child
            - [ ] sibling
            """
        let html = MarkdownHTML.render(markdown: markdown, contentWidth: .full).html
        let harness = WebViewLayoutHarness(html: html, width: 650, isEditor: false, height: 600)
        defer { harness.close() }
        _ = try await harness.layout(texts: ["sub-item 1", "open child"], imageCount: 0)
        let result = try await harness.webView.evaluateJavaScript("""
            (() => {
                const paragraphs = [...document.querySelectorAll('article li.task-list-item p')];
                const style = text => getComputedStyle(paragraphs.find(p => p.textContent.trim() === text));
                const plain = style('sibling').color;
                const texts = ['item', 'sub-item 1', 'sub-item 2', 'done parent', 'done paragraph', 'open child', 'sibling'];
                return {
                    muted: Object.fromEntries(texts.map(text => [text, style(text).color !== plain])),
                    struck: texts.some(text => style(text).textDecorationLine.includes('line-through')),
                };
            })()
            """) as? [String: Any]
        let muted = result?["muted"] as? [String: Bool]
        for text in ["sub-item 1", "done parent", "done paragraph"] {
            XCTAssertEqual(muted?[text], true, text)
        }
        for text in ["item", "sub-item 2", "open child", "sibling"] {
            XCTAssertEqual(muted?[text], false, text)
        }
        XCTAssertEqual(result?["struck"] as? Bool, false)
    }
}
