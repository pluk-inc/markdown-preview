import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorFormattingTests: XCTestCase {
    func testLinkPopoverRejectsPartialOverlapAtEitherSelectionEdge() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let source = "Before [hello](https://example.com) after"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const api = window.__mdEditor, source = api.getMarkdown();
                const start = source.indexOf('['), end = source.indexOf(')') + 1;
                const ranges = [[0, start + 3], [0, source.indexOf('example') + 2],
                                [start + 2, source.length], [start, end - 1]];
                const rejected = ranges.every(([from, to]) =>
                    api.insertLinkFromPopover('new', 'https://new.example', from, to) === false
                    && api.getMarkdown() === source);
                const replaced = api.insertLinkFromPopover('new', 'https://new.example', start, end);
                return { rejected, replaced, source: api.getMarkdown() };
            })()
            """) as? [String: Any]
        XCTAssertEqual(result?["rejected"] as? Bool, true)
        XCTAssertEqual(result?["replaced"] as? Bool, true)
        XCTAssertEqual(result?["source"] as? String, "Before [new](https://new.example) after")
    }

    func testPopoverReviewRegressions() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let cases: [(String, String, String, String)] = [
            ("```swift\nhello\nworld\n```", "hello", "setBlockStyle('code')", "`hello world`"),
            ("    hello", "hello", "setBlockStyle('code')", "`hello`"),
            ("> hello", "hello", "setBlockStyle('code')", "`hello`"),
            ("> a`b", "a`b", "setBlockStyle('code')", "``a`b``"),
            ("| Name |\n| --- |\n| value |", "value", "setBlockStyle('code')", "`Name value`"),
            ("plain\n\n> quoted", "plain\n\n> quoted", "setBlockStyle('quote')", "> plain\n> \n> quoted"),
            ("one\n\ntwo", "one\n\ntwo", "setListStyle('ordered')", "1. one\n\n2. two"),
            ("```text\n- item\n```", "- item", "setListStyle('none')", "```text\n- item\n```"),
            ("    - item", "- item", "setListStyle('bullet')", "    - item"),
            ("```text\nhello\n```", "hello", "setBlockStyle('table')", "```text\nhello\n```\n\n| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n")
        ]
        for (source, selection, command, expected) in cases {
            let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                              width: 650, isEditor: true, height: 400)
            _ = try await editor.layout(texts: [], imageCount: 0)
            _ = try await editor.webView.callAsyncJavaScript("const from = window.__mdEditor.getMarkdown().indexOf(query); window.__mdEditor.select(from, query.includes('\\n') ? from + query.length : from);",
                                                            arguments: ["query": selection], in: nil, contentWorld: .page)
            _ = try await editor.webView.evaluateJavaScript("window.__mdEditor.\(command)")
            let actual = try await editor.webView.evaluateJavaScript("window.__mdEditor.getMarkdown()") as? String
            XCTAssertEqual(actual, expected, command + " in " + source)
            editor.close()
        }
    }

    func testLinkPopoverReplacesExistingLinkAndEncodesUnicodeWhitespace() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: "[hello](old)", editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            window.__mdEditor.insertTextAt('', 3, 3);
            const selection = window.__mdEditor.getLinkSelection(true);
            window.__mdEditor.insertLinkFromPopover(selection.text, 'https://example.com/a\\u00a0b\\u2003c(x)', selection.from, selection.to);
            window.__mdEditor.getMarkdown();
            """) as? String
        XCTAssertEqual(result, "[hello](https://example.com/a%C2%A0b%E2%80%83c%28x%29)")
    }

    func testFormattingStateIsPublishedSynchronouslyOnSelectionAndCommands() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "", editorJavaScript: script),
            width: 600, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const host = document.createElement('div');
                document.body.append(host);
                const source = '# Heading\\n\\n**bold** *italic* ~~strike~~ [link](https://example.com)\\n\\nBody';
                let latest;
                const api = MDEditor.create(host, source, {
                    onFormattingChange: state => { latest = state; }
                });
                const initial = latest.heading === 1;
                const cases = [['bold', 'bold'], ['italic', 'italic'], ['strike', 'strikethrough'], ['link', 'link']];
                const inline = cases.every(([text, command]) => {
                    api.select(source.indexOf(text) + 1);
                    return latest.heading === 0 && latest.commands.includes(command);
                });
                api.select(source.indexOf('Body') + 1);
                const body = latest.heading === 0 && latest.commands.length === 0;
                api.exec('h3');
                const command = latest.heading === 3;
                api.select(2);
                const heading = latest.heading === 1;
                api.select(2, source.indexOf('bold') + 2);
                const mixed = latest.heading === 0 && latest.commands.length === 0;
                return initial && inline && body && command && heading && mixed;
            })()
            """) as? Bool
        XCTAssertEqual(result, true)
    }

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
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0,
                                        selectors: [".cm-md-heading-prefix": 1])
            let result = try await editor.webView.callAsyncJavaScript("""
                const settle = async () => {
                    // Let CodeMirror's queued tasks run as well as its frame
                    // callbacks; microtasks alone can starve decoration work.
                    await new Promise(resolve => setTimeout(resolve, 0));
                    for (let i = 0; i < 12; i++) {
                        window.__layoutTestFrame();
                        await Promise.resolve();
                    }
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
        }
    }

    func testStylingPopoverConvertsBlocksWithoutLosingText() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "Example", editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        for (style, language, source) in [
            ("quote", "", "> Example"), ("none", "", "Example"),
            ("plain", "", "    Example"), ("none", "", "Example"),
            ("fenced", "swift", "```swift\nExample\n```"),
            ("fenced", "python", "```python\nExample\n```"), ("none", "", "Example")
        ] {
            let result = try await editor.webView.callAsyncJavaScript("""
                window.__mdEditor.setBlockStyle(style, language);
                for (let i = 0; i < 8; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                return { style: window.__mdEditor.getBlockStyle(), source: window.__mdEditor.getMarkdown() };
                """, arguments: ["style": style, "language": language], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: String])
            XCTAssertEqual(values["style"], style)
            XCTAssertEqual(values["source"], source)
        }
        _ = try await editor.webView.evaluateJavaScript("window.__mdEditor.setBlockStyle('table', '')")
        let source = try await editor.webView.evaluateJavaScript("window.__mdEditor.getMarkdown()") as? String
        XCTAssertEqual(source, "Example\n\n| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n")
    }

    func testListPopoverReplacesMarkersAndPreservesIndentation() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "  - [x] Item", editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        for (style, source) in [("task", "  - [x] Item"), ("bullet", "  - Item"),
                                ("ordered", "  1. Item"), ("task", "  - [ ] Item"), ("none", "  Item")] {
            let result = try await editor.webView.callAsyncJavaScript("""
                window.__mdEditor.setListStyle(style);
                for (let i = 0; i < 8; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                return { style: window.__mdEditor.getListStyle(), source: window.__mdEditor.getMarkdown() };
                """, arguments: ["style": style], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: String])
            XCTAssertEqual(values["style"], style)
            XCTAssertEqual(values["source"], source)
        }
    }

    func testLinkPopoverInsertionEscapingAndEmptyURL() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "Before selected after", editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            const api = window.__mdEditor;
            const before = api.getMarkdown();
            const selection = api.getLinkSelection();
            const untouched = api.getMarkdown() === before;
            const rejected = !api.insertLinkFromPopover('text', ' ', 7, 15) && api.getMarkdown() === before;
            api.insertLinkFromPopover('A [label]', 'https://example.com/a (b)', 7, 15);
            const linked = api.getMarkdown();
            api.insertLinkFromPopover('', 'https://example.org', 0, 0);
            return { untouched, rejected, linked, fallback: api.getMarkdown(), selection };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["untouched"] as? Bool, true)
        XCTAssertEqual(values["rejected"] as? Bool, true)
        let linked = "Before [A \\[label\\]](https://example.com/a%20%28b%29) after"
        XCTAssertEqual(values["linked"] as? String, linked)
        XCTAssertEqual(values["fallback"] as? String, "[https://example.org](https://example.org)" + linked)
    }

    func testHeadingPopoverCommandsAndSelectedStyle() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "Example", editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        for level in Array(1...6) + [0] {
            let result = try await editor.webView.callAsyncJavaScript("""
                window.__mdEditor.exec('h' + level);
                for (let i = 0; i < 8; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                return { heading: window.__mdEditor.getHeadingLevel(), source: window.__mdEditor.getMarkdown() };
                """, arguments: ["level": level], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(values["heading"] as? Int, level)
            XCTAssertEqual(values["source"] as? String,
                           (level == 0 ? "" : String(repeating: "#", count: level) + " ") + "Example")
            if level > 0 {
                let isGray = try await editor.webView.evaluateJavaScript("""
                    (() => {
                        const marker = document.querySelector('.cm-md-heading-marker');
                        const probe = document.createElement('span');
                        probe.style.color = 'var(--secondary)';
                        document.querySelector('#editor').append(probe);
                        const expected = getComputedStyle(probe).color;
                        const matches = marker && [marker, ...marker.querySelectorAll('*')]
                            .every(element => getComputedStyle(element).color === expected);
                        probe.remove();
                        return !!matches;
                    })()
                    """) as? Bool
                XCTAssertEqual(isGray, true, "Heading markers should use secondary gray at level \(level)")
            }
        }
    }
}
