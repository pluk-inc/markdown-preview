import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorFormattingTests: XCTestCase {
    func testPointerGestureAnchorsClicksAndRevealsSyntaxImmediately() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let sources = ["Before **target words** after", "Before *target words* after",
                       "Before ~~target words~~ after", "Before `target words` after",
                       "Before [target words](https://example.com/a/long/path) after",
                       "> target words", "- target words", "1. target words",
                       "```swift\nlet target = 1\n```", "### target words"]
        for (source, gesture) in sources.flatMap({ source in
            ["click", "drag", "double", "shift"].map { (source, $0) }
        }) {
            let editor = WebViewLayoutHarness(
                html: EditorHTML.render(markdown: source, editorJavaScript: script),
                width: 500, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                // The harness has no foreground NSWindow, but must exercise
                // the same focus-based reveal path as the visible app.
                document.hasFocus = () => true;
                const content = document.querySelector('.cm-content');
                const settle = async () => {
                    for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                };
                const targetRect = () => {
                    const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
                    while (walker.nextNode()) {
                        const start = walker.currentNode.textContent.indexOf('target');
                        if (start < 0) continue;
                        const range = document.createRange();
                        range.setStart(walker.currentNode, start + 2);
                        range.setEnd(walker.currentNode, start + 3);
                        return range.getBoundingClientRect();
                    }
                    throw new Error('Missing target text');
                };
                const original = targetRect();
                const x = original.x + original.width / 2, y = original.y + original.height / 2;
                const mouse = (type, target, buttons, dx = 0) => target.dispatchEvent(new MouseEvent(type,
                    { bubbles: true, cancelable: true, button: 0, buttons,
                      detail: gesture === 'double' ? 2 : 1, shiftKey: gesture === 'shift',
                      clientX: x + dx, clientY: y, view: window }));
                mouse('mousedown', document.elementFromPoint(x, y), 1);
                await settle();
                const during = targetRect();
                const immediateText = content.textContent;
                const anchor = window.__mdEditor.getLinkSelection();
                // A tiny movement used to hit different source characters
                // after Markdown markers expanded beneath the pointer.
                const movement = gesture === 'drag' ? 45 : 0.1;
                mouse('mousemove', document, 1, movement);
                await settle();
                const beforeRelease = window.__mdEditor.getLinkSelection();
                mouse('mouseup', document, 0, movement);
                await new Promise(resolve => setTimeout(resolve, 20));
                await settle();
                const final = window.__mdEditor.getLinkSelection();
                const after = targetRect();
                return { dx: during.x - original.x, dy: during.y - original.y,
                    releaseDX: after.x - during.x, releaseDY: after.y - during.y, immediateText,
                    from: final.from, to: final.to, anchor: anchor.from,
                    beforeFrom: beforeRelease.from, beforeTo: beforeRelease.to,
                    rendered: content.textContent,
                    source: window.__mdEditor.getMarkdown() };
                """, arguments: ["gesture": gesture], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            if gesture == "double" || gesture == "shift" {
                XCTAssertEqual(try XCTUnwrap(values["dx"] as? Double), 0, accuracy: 0.01, source)
                XCTAssertEqual(try XCTUnwrap(values["dy"] as? Double), 0, accuracy: 0.01, source)
            }
            XCTAssertEqual(values["from"] as? Int, values["beforeFrom"] as? Int, "\(gesture): \(source)")
            XCTAssertEqual(values["to"] as? Int, values["beforeTo"] as? Int, "\(gesture): \(source)")
            if gesture == "click" {
                XCTAssertEqual(try XCTUnwrap(values["releaseDX"] as? Double), 0, accuracy: 0.01, source)
                XCTAssertEqual(try XCTUnwrap(values["releaseDY"] as? Double), 0, accuracy: 0.01, source)
                XCTAssertEqual(values["from"] as? Int, values["to"] as? Int, source)
                XCTAssertEqual(values["from"] as? Int, values["anchor"] as? Int, source)
                if source == "Before **target words** after" {
                    XCTAssertTrue((values["immediateText"] as? String)?.contains("**target words**") == true,
                                  "Syntax should reveal on mouse down, not after release")
                }
            } else {
                XCTAssertNotEqual(values["from"] as? Int, values["to"] as? Int, "\(gesture): \(source)")
            }
            XCTAssertEqual(values["source"] as? String, source)
        }
    }

    func testHeadingMarkersRevealInlineAfterActivation() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for sample in (1...6).flatMap({ level in (0...3).map { (level, $0) } }) {
            let (level, indentation) = sample
            let source = "Paragraph\n\n" + String(repeating: " ", count: indentation) + String(repeating: "#", count: level) + " Heading text that wraps onto another line with more words ###\n\nAfter"
            let editor = WebViewLayoutHarness(
                html: EditorHTML.render(markdown: source, editorJavaScript: script),
                width: 360, isEditor: true, height: 400)
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const settle = async () => {
                    for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                };
                const rects = () => {
                    const line = document.querySelector('.cm-md-heading-prefix').closest('.cm-line');
                    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
                    while (walker.nextNode()) {
                        const node = walker.currentNode;
                        const start = node.textContent.indexOf('Heading');
                        if (start < 0) continue;
                        const range = document.createRange();
                        range.setStart(node, start); range.setEnd(node, start + 1);
                        const first = range.getBoundingClientRect();
                        const block = line.getBoundingClientRect();
                        return [[first.x, first.y, first.width, first.height],
                                [block.x, block.y, block.width, block.height]];
                    }
                    return [];
                };
                await settle();
                const before = rects();
                window.__mdEditor.insertTextAt('', position, position);
                // A windowless WebKit test cannot take keyboard focus. Find
                // activates the same source decorations as a focused caret.
                window.__mdEditor.find('Heading', false, false);
                await settle();
                const after = rects();
                const prefixWidth = document.querySelector('.cm-md-heading-prefix').getBoundingClientRect().width;
                return { before, after, prefixWidth, hidden: !!document.querySelector('.cm-md-heading-source-hidden') };
                """, arguments: ["position": 11 + indentation + level + 4], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            let before = try XCTUnwrap(values["before"] as? [[Double]])
            let after = try XCTUnwrap(values["after"] as? [[Double]])
            XCTAssertFalse(before.isEmpty)
            XCTAssertEqual(before.count, after.count)
            let prefixWidth = try XCTUnwrap(values["prefixWidth"] as? Double)
            XCTAssertEqual(before[0][0], before[1][0], accuracy: 1,
                           "Inactive heading level \(level), indentation \(indentation) must align to its column")
            // WebKit rounds text-indent placement to CSS pixels.
            XCTAssertEqual(after[0][0] - before[0][0], prefixWidth, accuracy: 1,
                           "Heading level \(level) should reveal its markers inline")
            XCTAssertEqual(values["hidden"] as? Bool, false)
            editor.close()
        }
    }

}
