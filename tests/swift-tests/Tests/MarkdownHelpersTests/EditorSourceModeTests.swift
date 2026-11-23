import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorSourceModeTests: XCTestCase {
    private static let source = "# Title\n\nA paragraph with **bold** text.\n\n- item one\n- item two\n\n| a | b |\n| - | - |\n| 1 | 2 |\n"

    private func measure(sourceMode: Bool, pageScrolling: Bool, switchAfterLoad: Bool = false) async throws -> [String: Double] {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        var configuration = EditorHTML.Configuration()
        configuration.sourceMode = sourceMode
        configuration.usesPageScrolling = pageScrolling
        let html = EditorHTML.render(markdown: Self.source, editorJavaScript: script, configuration: configuration)
        let harness = WebViewLayoutHarness(html: html, width: 1000, isEditor: true, height: 600)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 0)
        if switchAfterLoad {
            _ = try await harness.webView.callAsyncJavaScript(
                "window.__mdSetSourceMode(true)", arguments: [:], in: nil, contentWorld: .page)
            _ = try await harness.layout(texts: [], imageCount: 0)
        }
        let result = try await harness.webView.callAsyncJavaScript("""
            const line = document.querySelector('.cm-line').getBoundingClientRect();
            const gutter = document.querySelector('.cm-gutters')?.getBoundingClientRect();
            const scroller = document.querySelector('.cm-scroller').getBoundingClientRect();
            return {
                lineTop: line.top, lineLeft: line.left, lineRight: line.right,
                gutterLeft: gutter ? gutter.left : -1, gutterRight: gutter ? gutter.right : -1,
                scrollerTop: scroller.top, scrollerLeft: scroller.left, scrollerRight: scroller.right,
                endRoom: parseFloat(getComputedStyle(document.querySelector('.cm-content')).paddingBottom),
                paneHeight: window.innerHeight,
                numbers: document.querySelectorAll('.cm-lineNumbers .cm-gutterElement').length,
                markers: document.querySelector('.cm-content').textContent.includes('**bold**') ? 1 : 0,
            };
            """, arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(result as? [String: Double])
    }

    func testSourceModeReadsLikeCodeFromThePaneEdges() async throws {
        for pageScrolling in [false, true] {
            let formatted = try await measure(sourceMode: false, pageScrolling: pageScrolling)
            let opened = try await measure(sourceMode: true, pageScrolling: pageScrolling)
            let switched = try await measure(sourceMode: false, pageScrolling: pageScrolling, switchAfterLoad: true)
            // Read like code: numbers on the pane's left edge, text beside
            // them, and the full width instead of the centered column.
            for style in [opened, switched] {
                XCTAssertEqual(style["gutterLeft"], formatted["scrollerLeft"].map { $0 + 6 })
                XCTAssertEqual(style["lineLeft"], style["gutterRight"], "the current-line band has no break")
                XCTAssertEqual(style["lineRight"], formatted["scrollerRight"].map { $0 - 8 })
                XCTAssertGreaterThan(try XCTUnwrap(style["numbers"]), 1)
            }
            XCTAssertEqual(formatted["numbers"], 0)
            // Source mode scrolls past the end until the last line is in the
            // middle of the pane; the formatted style keeps its page margin.
            XCTAssertEqual(formatted["endRoom"], 48)
            for style in [opened, switched] {
                let room = try XCTUnwrap(style["endRoom"]), pane = try XCTUnwrap(style["paneHeight"])
                XCTAssertEqual(room, pane / 2, accuracy: 1)
            }
            XCTAssertEqual(opened["markers"], 1)
            XCTAssertEqual(switched["markers"], 1)
            // No reading clearance above the first line, only a small gap.
            XCTAssertGreaterThan(try XCTUnwrap(formatted["lineTop"]), 30)
            XCTAssertEqual(opened["lineTop"], opened["scrollerTop"].map { $0 + 8 })
            XCTAssertEqual(switched["lineTop"], switched["scrollerTop"].map { $0 + 8 })
        }
    }

    /// Runs one formatting bar command on the word "two" and returns the
    /// value the command gave back together with the Markdown it left.
    private func barResults(sourceMode: Bool, calls: [String]) async throws -> [String] {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        var configuration = EditorHTML.Configuration()
        configuration.sourceMode = sourceMode
        let html = EditorHTML.render(markdown: "", editorJavaScript: script, configuration: configuration)
        let harness = WebViewLayoutHarness(html: html, width: 800, isEditor: true, height: 500)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 0)
        var results: [String] = []
        for call in calls {
            let result = try await harness.webView.evaluateJavaScript("""
                (() => {
                    const e = window.__mdEditor;
                    e.replaceMarkdown("first line\\n\\none two three\\n\\nlast line\\n");
                    e.select(16, 19);
                    const returned = \(call);
                    return JSON.stringify([returned ?? null, e.getMarkdown()]);
                })()
                """)
            results.append(try XCTUnwrap(result as? String, call))
        }
        let numbers = try await harness.webView.evaluateJavaScript("document.querySelectorAll('.cm-lineNumbers').length")
        XCTAssertEqual(numbers as? Int, sourceMode ? 1 : 0)
        return results
    }

    func testFormattingBarCommandsWriteTheSameMarkdownInSourceMode() async throws {
        var calls = ["bold", "italic", "strikethrough", "highlight", "code", "h0", "h1", "h2", "h3", "h4", "h5", "h6",
                     "quote", "bulletList", "orderedList", "taskList", "link"].map { "e.exec('\($0)')" }
        calls += ["none", "quote", "code", "plain", "fenced", "table"].map { "e.setBlockStyle('\($0)', 'swift')" }
        calls += ["none", "bullet", "ordered", "task"].map { "e.setListStyle('\($0)')" }
        calls += ["e.insertLinkFromPopover('two', 'https://example.com', 16, 19)",
                  "(e.exec('bold'), e.exec('bold'))",
                  "(e.exec('h2'), e.getHeadingLevel())",
                  "(e.setListStyle('task'), e.getListStyle())",
                  "(e.setBlockStyle('quote', ''), e.getBlockStyle())"]
        let formatted = try await barResults(sourceMode: false, calls: calls)
        let source = try await barResults(sourceMode: true, calls: calls)
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(source[index], formatted[index], call)
        }
        // Anchor the comparison, so a break in both styles cannot pass.
        let written = Dictionary(uniqueKeysWithValues: zip(calls, source))
        XCTAssertEqual(written["e.exec('bold')"], #"[null,"first line\n\none **two** three\n\nlast line\n"]"#)
        XCTAssertEqual(written["e.exec('taskList')"], #"[null,"first line\n\n- [ ] one two three\n\nlast line\n"]"#)
        XCTAssertEqual(written["e.setBlockStyle('fenced', 'swift')"],
                       #"[true,"first line\n\n```swift\none two three\n```\n\nlast line\n"]"#)
        XCTAssertEqual(written["(e.exec('h2'), e.getHeadingLevel())"], #"[2,"first line\n\n## one two three\n\nlast line\n"]"#)
    }
}
