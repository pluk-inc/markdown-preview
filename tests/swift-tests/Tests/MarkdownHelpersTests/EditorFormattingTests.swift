import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorFormattingTests: XCTestCase {
    func testFormattingMissingTableCellsDoesNotTargetBodySelection() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for command in ["bold", "keyboard", "link"] {
            let source = "Before\n\n| First | Second |\n| --- | --- |\n| One |"
            let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                              width: 650, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const api = window.__mdEditor;
                api.select(0, 6);
                const selector = '[data-table-row="1"][data-table-column="1"]';
                const cell = document.querySelector(selector);
                cell.focus();
                cell.replaceChildren(document.createTextNode(''));
                window.getSelection().setBaseAndExtent(cell.firstChild, 0, cell.firstChild, 0);
                if (command === 'keyboard') {
                    cell.dispatchEvent(new KeyboardEvent('keydown', {key: 'b', metaKey: true,
                        bubbles: true, cancelable: true}));
                } else if (command === 'link') {
                    const selected = api.getLinkSelection();
                    api.insertLinkFromPopover('Link', 'https://example.com', selected.from, selected.to);
                } else {
                    cell.blur();
                    api.exec(command);
                }
                return {source: api.getMarkdown(), value: document.querySelector(selector).textContent};
                """, arguments: ["command": command], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertTrue((result?["source"] as? String)?.hasPrefix("Before\n\n") == true, command)
            XCTAssertEqual(result?["value"] as? String,
                           command == "link" ? "[Link](https://example.com)" : "****", command)
        }
    }

    func testTableFormattingRejectsTargetAfterDocumentReplacement() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let source = "Before\n\n| Name |\n| --- |\n| Ada |"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const api = window.__mdEditor;
                api.select(0, 6);
                const cell = document.querySelector('[data-table-row="1"]');
                cell.focus();
                window.getSelection().setBaseAndExtent(cell.firstChild, 0, cell.firstChild, 3);
                const oldLink = api.getLinkSelection();
                const replacement = 'Updated before\\n\\n| Name |\\n| --- |\\n| Grace |';
                api.replaceMarkdown(replacement);
                api.exec('bold');
                const rejectedBold = api.getMarkdown() === replacement;
                const rejectedLink = api.insertLinkFromPopover('Ada', 'https://example.com', oldLink.from, oldLink.to) === false;
                const selected = api.getLinkSelection();
                const untouched = api.getMarkdown() === replacement;
                api.select(0, 7);
                api.exec('italic');
                const resumed = api.getMarkdown().startsWith('*Updated* before');
                return {rejectedBold, rejectedLink, invalidSelection: selected === null, untouched, resumed};
            })()
            """) as? [String: Any]
        for key in ["rejectedBold", "rejectedLink", "invalidSelection", "untouched", "resumed"] {
            XCTAssertEqual(result?[key] as? Bool, true, key)
        }
    }

    func testTableClickAnchorsBeforeRevealingSyntax() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for cell in ["**target words**", "*target words*", "~~target words~~",
                     "`target words`", "`` target words ``", "==target words==",
                     "[target words](https://example.com)", "**before *target words***"] {
            for drag in [false, true] {
                let source = "| Name |\n| --- |\n| \(cell) |"
                let editor = WebViewLayoutHarness(
                    html: EditorHTML.render(markdown: source, editorJavaScript: script),
                    width: 500, isEditor: true, height: 400)
                defer { editor.close() }
                _ = try await editor.layout(texts: [], imageCount: 0)
                let result = try await editor.webView.callAsyncJavaScript("""
                    const cell = document.querySelector('[data-table-row="1"][data-table-column="0"]');
                    const walker = document.createTreeWalker(cell, NodeFilter.SHOW_TEXT);
                    while (walker.nextNode()) {
                        if (walker.currentNode.textContent.includes('target')) break;
                    }
                    const node = walker.currentNode;
                    const start = node.textContent.indexOf('target') + 2;
                    const range = document.createRange();
                    range.setStart(node, start); range.setEnd(node, start + 1);
                    const rect = range.getBoundingClientRect();
                    const x = rect.x + rect.width * 0.25, y = rect.y + rect.height / 2;
                    const hit = document.caretRangeFromPoint(x, y);
                    const expected = sourceCell.indexOf('target') + hit.startOffset - node.textContent.indexOf('target');
                    const mouse = (type, target, dx = 0) => target.dispatchEvent(new MouseEvent(type,
                        {bubbles: true, cancelable: true, button: 0, buttons: type === 'mouseup' ? 0 : 1,
                         detail: 1, clientX: x + dx, clientY: y, view: window}));
                    mouse('mousedown', document.elementFromPoint(x, y));
                    const selection = window.getSelection();
                    const anchor = selection.anchorOffset;
                    mouse('mousemove', document, drag ? 65 : 0.1);
                    mouse('mouseup', document, drag ? 65 : 0.1);
                    return {expected, anchor, finalAnchor: selection.anchorOffset,
                        collapsed: selection.isCollapsed, text: cell.textContent,
                        source: window.__mdEditor.getMarkdown()};
                    """, arguments: ["sourceCell": cell, "drag": drag], in: nil, contentWorld: .page)
                let values = try XCTUnwrap(result as? [String: Any])
                XCTAssertEqual(values["anchor"] as? Int, values["expected"] as? Int, cell)
                XCTAssertEqual(values["finalAnchor"] as? Int, values["expected"] as? Int, cell)
                XCTAssertEqual(values["collapsed"] as? Bool, !drag, cell)
                XCTAssertEqual(values["text"] as? String, cell)
                XCTAssertEqual(values["source"] as? String, source)
            }
        }
    }

    func testTablePointerSelectionKeepsNativeTextRangeAndFormattingTarget() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "Before\n\n| Name | Status |\n| --- | --- |\n| Ada Lovelace | Ready |", editorJavaScript: script),
            width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const cell = document.querySelector('[data-table-row="1"][data-table-column="0"]');
                const down = new MouseEvent('mousedown', { button: 0, buttons: 1, bubbles: true, cancelable: true });
                cell.dispatchEvent(down);
                const sourceFocused = document.activeElement === cell && !down.defaultPrevented;
                // Model WebKit's native drag selection between down and up.
                // The table handlers must not collapse or prevent this range.
                window.getSelection().setBaseAndExtent(cell.firstChild, 0, cell.firstChild, 3);
                const up = new MouseEvent('mouseup', { button: 0, bubbles: true, cancelable: true });
                cell.dispatchEvent(up);
                const click = new MouseEvent('click', { button: 0, bubbles: true, cancelable: true });
                cell.dispatchEvent(click);
                const retained = window.getSelection().toString() === 'Ada'
                    && !up.defaultPrevented && !click.defaultPrevented;
                const doubleDown = new MouseEvent('mousedown', { button: 0, detail: 2, bubbles: true, cancelable: true });
                cell.dispatchEvent(doubleDown);
                const doubleAllowed = !doubleDown.defaultPrevented;
                cell.dispatchEvent(new MouseEvent('mouseup', { button: 0, bubbles: true }));
                window.__mdEditor.exec('bold');
                return sourceFocused && retained && doubleAllowed
                    && window.__mdEditor.getMarkdown().includes('**Ada** Lovelace')
                    && window.__mdEditor.getMarkdown().startsWith('Before\\n\\n');
            })()
            """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testFormattingToolbarTargetsTableCellSelectionAfterBlur() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for (command, marker) in [("bold", "**"), ("italic", "*"), ("strikethrough", "~~"), ("highlight", "=="), ("code", "`")] {
            let markdown = "Unrelated paragraph\n\n| Name | Status |\n| --- | --- |\n| Ada Lovelace | Ready |\n\nAfter table"
            let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: markdown, editorJavaScript: script),
                                              width: 650, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const api = window.__mdEditor;
                const cell = document.querySelector('[data-table-row="1"][data-table-column="0"]');
                cell.focus();
                window.getSelection().setBaseAndExtent(cell.firstChild, 0, cell.firstChild, 3);
                document.dispatchEvent(new Event('selectionchange'));
                // Native toolbar focus must not redirect the action to the paragraph.
                cell.blur();
                api.exec(command);
                let current = document.querySelector('[data-table-row="1"][data-table-column="0"]');
                const applied = current.textContent === marker + 'Ada' + marker + ' Lovelace'
                    && document.activeElement === current && window.getSelection().toString() === 'Ada';
                api.exec(command);
                current = document.querySelector('[data-table-row="1"][data-table-column="0"]');
                const toggledOff = current.textContent === 'Ada Lovelace';
                const beforeBlock = api.getMarkdown();
                api.exec('h2');
                api.setListStyle('bullet');
                return applied && toggledOff && api.getMarkdown() === beforeBlock
                    && api.getMarkdown().startsWith('Unrelated paragraph\\n\\n')
                    && api.getMarkdown().endsWith('\\n\\nAfter table')
                    && document.querySelector('[data-table-row="1"][data-table-column="1"]').textContent === 'Ready';
                """, arguments: ["command": command, "marker": marker], in: nil, contentWorld: .page)
            XCTAssertEqual(result as? Bool, true, command)
        }
    }

    func testTableLinkPopoverAndKeyboardFormattingPreservePendingTyping() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let markdown = "Before\n\n| Name |\n| --- |\n| Ada |"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: markdown, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const api = window.__mdEditor;
                let cell = document.querySelector('[data-table-row="1"]');
                cell.focus();
                cell.textContent = 'New Ada';
                window.getSelection().setBaseAndExtent(cell.firstChild, 4, cell.firstChild, 7);
                const selected = api.getLinkSelection(true);
                const correctLabel = selected.text === 'Ada';
                const linked = api.insertLinkFromPopover(selected.text, 'https://example.com', selected.from, selected.to);
                cell = document.querySelector('[data-table-row="1"]');
                const linkSource = cell.textContent === 'New [Ada](https://example.com)';
                window.getSelection().setBaseAndExtent(cell.firstChild, 0, cell.firstChild, 3);
                cell.dispatchEvent(new KeyboardEvent('keydown', { key: 'b', metaKey: true, bubbles: true, cancelable: true }));
                cell = document.querySelector('[data-table-row="1"]');
                const keyboard = cell.textContent === '**New** [Ada](https://example.com)';
                cell.blur();
                return correctLabel && linked && linkSource && keyboard
                    && api.getMarkdown().startsWith('Before\\n\\n')
                    && api.getMarkdown().includes('**New** [Ada](https://example.com)');
            })()
            """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTableFormattingMapsPendingPipesWhitespaceUnicodeAndEmptyCells() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for (text, start, end, expected) in [
            ("left | Ada", 7, 10, "left \\| **Ada**"),
            ("  Ada  ", 2, 5, "**Ada**"),
            ("🙂 Ada", 3, 6, "🙂 **Ada**"),
            ("", 0, 0, "****")
        ] {
            let editor = WebViewLayoutHarness(
                html: EditorHTML.render(markdown: "Before\n\n| First | Second |\n| --- | --- |\n| Same | Same |\n| Same |  |", editorJavaScript: script),
                width: 650, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const api = window.__mdEditor;
                const selector = '[data-table-row="2"][data-table-column="1"]';
                const cell = document.querySelector(selector);
                cell.focus();
                cell.replaceChildren(document.createTextNode(text));
                window.getSelection().setBaseAndExtent(cell.firstChild, start, cell.firstChild, end);
                api.exec('bold');
                const value = document.querySelector(selector).textContent;
                const neighbor = document.querySelector('[data-table-row="2"][data-table-column="0"]').textContent;
                api.select(0, 6);
                api.exec('italic');
                return JSON.stringify({ value, neighbor, outside: api.getMarkdown().startsWith('*Before*\\n\\n') });
                """, arguments: ["text": text, "start": start, "end": end], in: nil, contentWorld: .page)
            let json = try XCTUnwrap(result as? String)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(values["value"] as? String, expected, json)
            XCTAssertEqual(values["neighbor"] as? String, "Same", json)
            XCTAssertEqual(values["outside"] as? Bool, true, json)
        }
    }

    func testTaskSeparatorStaysStableOnContinuationLines() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let source = "- [ ] First\n\n- [ ] Second\n  continuation\n\n  Later paragraph"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 500)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            document.hasFocus = () => true;
            const api = window.__mdEditor;
            const positions = [];
            api.focus();
            for (const text of ['Second', 'continuation', 'Later paragraph', 'Second']) {
                api.select(api.getMarkdown().indexOf(text)); api.focus();
                for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                const line = [...document.querySelectorAll('.cm-line')].find(line => line.textContent.includes('Second'));
                positions.push(line.getBoundingClientRect().top);
            }
            return {positions, source: api.getMarkdown()};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let positions = try XCTUnwrap(result?["positions"] as? [Double])
        XCTAssertEqual(positions.count, 4)
        for position in positions { XCTAssertEqual(position, positions[0], accuracy: 0.5) }
        XCTAssertEqual(result?["source"] as? String, source)
    }

    func testNewTaskAfterDoubleEnterKeepsBlankLineAndCaretPosition() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: "- [ ] First", editorJavaScript: script),
                                          width: 650, isEditor: true, height: 500)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            const api = window.__mdEditor;
            document.hasFocus = () => true;
            const settle = async () => {
                for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            };
            api.select(api.getMarkdown().length); api.focus();
            const enter = async () => {
                document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',
                    {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true}));
                await settle();
            };
            await enter(); await enter();
            const lastLineTop = () => [...document.querySelectorAll('.cm-line')].at(-1).getBoundingClientRect().top;
            const before = lastLineTop();
            const positions = [];
            for (const character of '- [ ] Second') {
                const range = api.getLinkSelection();
                api.insertTextAt(character, range.from, range.to);
                await settle();
                positions.push(lastLineTop());
            }
            const lines = [...document.querySelectorAll('.cm-line')];
            return {before, positions, source: api.getMarkdown(),
                blankHeight: lines[1].getBoundingClientRect().height,
                caret: api.getLinkSelection().from};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let before = try XCTUnwrap(result?["before"] as? Double)
        for top in try XCTUnwrap(result?["positions"] as? [Double]) {
            XCTAssertGreaterThanOrEqual(top, before - 0.5, "Starting a new task must not collapse the separator above it")
        }
        XCTAssertGreaterThan(try XCTUnwrap(result?["blankHeight"] as? Double), 0)
        let source = "- [ ] First\n\n- [ ] Second"
        XCTAssertEqual(result?["source"] as? String, source)
        XCTAssertEqual(result?["caret"] as? Int, source.utf16.count)
    }

    func testCheckboxTogglePreservesKeyboardFocus() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: "- [ ] First\n- [ ] Second", editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const checkbox = document.querySelector('.cm-md-task-marker input');
                checkbox.focus(); checkbox.click();
                const retained = document.activeElement === checkbox && checkbox.isConnected;
                const label = checkbox.getAttribute('aria-label');
                checkbox.click();
                return {retained, label, unchecked: !checkbox.checked,
                        retainedAgain: document.activeElement === checkbox && checkbox.isConnected,
                        source: window.__mdEditor.getMarkdown()};
            })()
            """) as? [String: Any]
        for key in ["retained", "retainedAgain", "unchecked"] {
            XCTAssertEqual(result?[key] as? Bool, true, key)
        }
        XCTAssertEqual(result?["label"] as? String, "Mark task incomplete")
        XCTAssertEqual(result?["source"] as? String, "- [ ] First\n- [ ] Second")
    }

    func testCompletedParentDoesNotStrikeNestedUncheckedItems() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let source = "- [x] Parent\n  continuation\n    - [ ] Child\n      child continuation\n    - [x] Done child\n        - [ ] Grandchild\n\n  Parent after children\n- [ ] Sibling"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 600)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const lines = [...document.querySelectorAll('.cm-line')];
                return Object.fromEntries(lines.filter(line => line.textContent.trim()).map(line =>
                    [line.textContent.trim(), getComputedStyle(line).textDecorationLine.includes('line-through')]));
            })()
            """) as? [String: Bool]
        for label in ["Parent", "continuation", "Done child", "Parent after children"] {
            XCTAssertEqual(result?[label], true, label)
        }
        for label in ["Child", "child continuation", "Grandchild", "Sibling"] {
            XCTAssertEqual(result?[label], false, label)
        }
    }

    func testCompletedTaskStyleTracksCheckboxToggles() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let source = "- [x] Done **bold**\n  continuation\n- [ ] Pending"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const lines = () => [...document.querySelectorAll('.cm-line')];
                const struck = line => getComputedStyle(line).textDecorationLine.includes('line-through');
                const initial = struck(lines()[0]) && struck(lines()[1]) && !struck(lines()[2]);
                const muted = getComputedStyle(lines()[0]).color !== getComputedStyle(lines()[2]).color;
                document.querySelector('.cm-md-task-marker input').click();
                const cleared = !struck(lines()[0]) && !struck(lines()[1]);
                document.querySelector('.cm-md-task-marker input').click();
                return {initial, muted, cleared, restored: struck(lines()[0]),
                        source: window.__mdEditor.getMarkdown()};
            })()
            """) as? [String: Any]
        for key in ["initial", "muted", "cleared", "restored"] {
            XCTAssertEqual(result?[key] as? Bool, true, key)
        }
        XCTAssertEqual(result?["source"] as? String, source)
    }

    func testFreshTaskTypingWaitsForCaretToLeaveAutoClosedBracket() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let html = EditorHTML.render(markdown: "", editorJavaScript: script)
            .replacingOccurrences(of: "editor = window.MDEditor.create(",
                                  with: "editor = window.__typingEditor = window.MDEditor.create(")
        let editor = WebViewLayoutHarness(html: html, width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            document.hasFocus = () => true;
            const api = window.__typingEditor;
            api.focus();
            const settle = async () => {
                for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            };
            const results = [];
            for (const marker of ['- [ ]', '- [x]', '- [X]', '- [ x ]']) {
                api.replaceMarkdown(''); api.select(0); api.focus();
                let premature = false;
                for (const char of marker) {
                    api.insert(char); await settle();
                    const caret = api.getLinkSelection().from;
                    const closing = api.getMarkdown().indexOf(']');
                    if (caret <= closing && document.querySelector('.cm-md-task-marker')) premature = true;
                }
                const boxes = document.querySelectorAll('.cm-md-task-marker input').length;
                for (const char of ' New task') { api.insert(char); await settle(); }
                results.push({marker, premature, boxes, source: api.getMarkdown(), caret: api.getLinkSelection().from});
            }
            return results;
            """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        XCTAssertEqual(result?.count, 4)
        for item in result ?? [] {
            let marker = try XCTUnwrap(item["marker"] as? String)
            XCTAssertEqual(item["premature"] as? Bool, false, marker)
            XCTAssertEqual(item["boxes"] as? Int, marker == "- [ x ]" ? 0 : 1, marker)
            XCTAssertEqual(item["source"] as? String, marker + " New task", marker)
            XCTAssertEqual(item["caret"] as? Int, (marker + " New task").utf16.count, marker)
        }
    }

    func testTypedTaskCheckboxContinuesAndExitsOnEmptyItem() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: "", editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            try {
            document.hasFocus = () => true;
            const api = window.__mdEditor;
            const settle = async () => {
                for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            };
            const type = async text => {
                for (const char of text) {
                    const selection = api.getLinkSelection();
                    api.insertTextAt(char, selection.from, selection.to);
                    await settle();
                }
            };
            const enter = async () => {
                document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',
                    {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true}));
                await settle();
            };
            await type('- [ ] First');
            const rendered = document.querySelectorAll('.cm-md-task-marker input').length;
            document.querySelector('.cm-md-task-marker input').click();
            await settle();
            const toggled = api.getMarkdown();
            api.select(toggled.length); api.focus();
            await enter();
            const continued = api.getMarkdown();
            const emptyRendered = document.querySelectorAll('.cm-md-task-marker input').length;
            await enter();
            const exited = api.getMarkdown();
            await type('Outside');
            await enter(); await enter();
            await type('- [ ] Second');
            const final = api.getMarkdown();
            const boxes = [...document.querySelectorAll('.cm-md-task-marker input')];
            boxes.at(-1)?.click(); await settle();
            return {rendered, toggled, continued, emptyRendered, exited, final,
                    checkedSecond: api.getMarkdown(), count: boxes.length};
            } catch (error) { return {error: String(error), stack: error.stack}; }
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertNil(result?["error"], String(describing: result))
        XCTAssertEqual(result?["rendered"] as? Int, 1)
        XCTAssertEqual(result?["toggled"] as? String, "- [x] First")
        XCTAssertEqual(result?["continued"] as? String, "- [x] First\n- [ ] ")
        XCTAssertEqual(result?["emptyRendered"] as? Int, 2)
        XCTAssertEqual(result?["exited"] as? String, "- [x] First\n\n")
        XCTAssertEqual(result?["final"] as? String, "- [x] First\n\nOutside\n\n- [ ] Second")
        XCTAssertEqual(result?["checkedSecond"] as? String, "- [x] First\n\nOutside\n\n- [x] Second")
        XCTAssertEqual(result?["count"] as? Int, 2)
    }

    func testTaskEnterPreservesMarkersAndMarkdownContext() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let examples = [
            ("+ [X] One", "+ [X] One\n+ [ ] ", "+ [X] One\n\n"),
            ("* [ ] One", "* [ ] One\n* [ ] ", "* [ ] One\n\n"),
            ("- [ ] One\n- [ ] Two", "- [ ] One\n- [ ] Two\n- [ ] ", "- [ ] One\n- [ ] Two\n\n"),
            ("> - [ ] One", "> - [ ] One\n> - [ ] ", "> - [ ] One\n> "),
            ("- [ ] Parent\n    - [x] Child", "- [ ] Parent\n    - [x] Child\n    - [ ] ",
             "- [ ] Parent\n    - [x] Child\n- [ ] ")
        ]
        for (source, continued, exited) in examples {
            let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                              width: 650, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.evaluateJavaScript("""
                (() => {
                    const api = window.__mdEditor;
                    api.select(api.getMarkdown().length); api.focus();
                    const enter = () => document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',
                        {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true}));
                    enter(); const continued = api.getMarkdown();
                    enter(); return {continued, exited: api.getMarkdown()};
                })()
                """) as? [String: Any]
            XCTAssertEqual(result?["continued"] as? String, continued, source)
            XCTAssertEqual(result?["exited"] as? String, exited, source)
        }
        let source = "```markdown\n- [ ] Literal"
        let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                          width: 650, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let literal = try await editor.webView.evaluateJavaScript("""
            (() => {
                const api = window.__mdEditor;
                api.select(api.getMarkdown().length); api.focus();
                document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',
                    {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true, cancelable: true}));
                return {source: api.getMarkdown(), boxes: document.querySelectorAll('.cm-md-task-marker input').length};
            })()
            """) as? [String: Any]
        XCTAssertEqual(literal?["source"] as? String, source + "\n")
        XCTAssertEqual(literal?["boxes"] as? Int, 0)
    }

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
