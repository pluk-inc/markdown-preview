import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorScrollAnchorTests: XCTestCase {
    func testCodeCardCopyRespectsParsedIndentation() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for (source, expected) in [("  ```\n  x\n  ```", "x"),
                                   ("        x\n    y", "    x\ny"),
                                   ("```\n\nx\n\n```", "\nx\n")] {
            let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                              width: 650, isEditor: true, height: 400)
            _ = try await editor.layout(texts: [], imageCount: 0)
            let copied = try await editor.webView.callAsyncJavaScript("""
                let copied = null;
                Object.defineProperty(window, 'webkit', { configurable: true, value: { messageHandlers: {
                    mdEditorHost: { postMessage: message => { if (message.kind === 'copyCode') copied = message.value; } }
                } } });
                document.querySelector('.cm-md-code-copy').click();
                await Promise.resolve();
                return copied;
                """, arguments: [:], in: nil, contentWorld: .page) as? String
            XCTAssertEqual(copied, expected)
            editor.close()
        }
    }

    func testCodeWrappingFollowsInsertionAndDoesNotSurviveDeletion() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for source in ["```text\nlong code\n```", "    long code"] {
            let editor = WebViewLayoutHarness(html: EditorHTML.render(markdown: source, editorJavaScript: script),
                                              width: 650, isEditor: true, height: 400)
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const settle = async () => { for(let i=0;i<12;i++) { window.__layoutTestFrame(); await Promise.resolve(); } };
                const wrapped = () => document.querySelector('.cm-md-code-toggle-wrap')?.getAttribute('aria-pressed');
                document.querySelector('.cm-md-code-toggle-wrap').click();
                await settle();
                window.__mdEditor.insertTextAt('Before\\n\\n', 0, 0);
                await settle();
                const preserved = wrapped() === 'true';
                window.__mdEditor.insertTextAt('', 0, window.__mdEditor.getMarkdown().length);
                window.__mdEditor.insertTextAt(source, 0, 0);
                await settle();
                return preserved && wrapped() === 'false';
                """, arguments: ["source": source], in: nil, contentWorld: .page) as? Bool
            XCTAssertEqual(result, true)
            editor.close()
        }
    }

    func testFloatingToolbarClearanceRemainsConstantAcrossZoom() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for zoom in [0.5, 1.0, 2.0] {
            for editing in [false, true] {
                let html = editing
                    ? EditorHTML.render(markdown: "Text", editorJavaScript: script,
                                        configuration: .init(usesPageScrolling: true))
                    : "<style>\(MarkdownHTML.stylesheet)</style><style>:root { --mdp-page-top-clearance: \(MarkdownHTML.appPageTopClearance)px; }</style><article class='markdown-body'>Text</article>"
                let page = WebViewLayoutHarness(html: html, width: 650, isEditor: editing, zoom: zoom, height: 400)
                _ = try await page.layout(texts: [], imageCount: 0)
                let value = try await page.webView.callAsyncJavaScript("""
                    document.documentElement.style.setProperty('--mdp-chrome-zoom', zoom);
                    return parseFloat(getComputedStyle(document.querySelector(editing ? '.cm-scroller' : 'body')).paddingTop) * zoom;
                    """, arguments: ["zoom": zoom, "editing": editing], in: nil, contentWorld: .page)
                XCTAssertEqual(try XCTUnwrap(value as? Double),
                               Double(MarkdownHTML.pagePaddingTop + MarkdownHTML.appPageTopClearance), accuracy: 1)
                page.close()
            }
        }
    }

    func testPreviewCodeScrollbarIsNotHiddenByInnerScrollerRule() async throws {
        let html = "<style>\(MarkdownHTML.stylesheet)</style><article class='markdown-body'><pre><code>"
            + String(repeating: "long_argument_", count: 100) + "</code></pre></article>"
        let preview = WebViewLayoutHarness(html: html, width: 650, isEditor: false, height: 400)
        defer { preview.close() }
        _ = try await preview.layout(texts: [], imageCount: 0)
        let result = try await preview.webView.evaluateJavaScript("""
            (() => {
                const pre = document.querySelector('pre');
                return pre.scrollWidth > pre.clientWidth
                    && getComputedStyle(pre, '::-webkit-scrollbar').display !== 'none';
            })()
            """)
        XCTAssertEqual(result as? Bool, true)
    }

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

    func testCodeCardWrapControlsPreserveSourceAndHeaderPosition() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let code = "let message = \"" + String(repeating: "long code text ", count: 30) + "\"\nprint(message)"
        let markdown = "```swift\n" + code + "\n```"
        for isEditor in [false, true] {
            let html = isEditor
                ? EditorHTML.render(markdown: markdown, editorJavaScript: script)
                : MarkdownHTML.render(markdown: markdown, allowsScroll: true).html
            let harness = WebViewLayoutHarness(html: html, width: 500, isEditor: isEditor, height: 600)
            defer { harness.close() }
            _ = try await harness.layout(texts: [], imageCount: 0)
            let result = try await harness.webView.callAsyncJavaScript("""
                const settle = async () => { for (let i = 0; i < 8; i++) {
                    window.__layoutTestFrame(); await new Promise(r => setTimeout(r, 15));
                }};
                const toggle = () => document.querySelector(isEditor ? '.cm-md-code-toggle-wrap' : '.md-code-toggle-wrap');
                const line = () => document.querySelector(isEditor ? '[data-code-scroll-group]' : '.md-code-wrap pre');
                const copy = () => document.querySelector(isEditor ? '.cm-md-code-copy' : '.md-code-copy');
                // Measure text layout independently of the native scrollport.
                // WebKit can add/remove scrollbar space during wrap changes.
                const contentHeight = () => {
                    const range = document.createRange();
                    range.selectNodeContents(isEditor ? line() : line().querySelector('code'));
                    return range.getBoundingClientRect().height;
                };
                const before = isEditor ? window.__mdEditor.getMarkdown() : line().textContent;
                let copied = null;
                Object.defineProperty(navigator, 'clipboard', { configurable: true,
                    value: { writeText: async text => { copied = text; } } });
                if (isEditor) Object.defineProperty(window, 'webkit', { configurable: true,
                    value: { messageHandlers: { mdEditorHost: { postMessage: message => {
                        if (message.kind === 'copyCode') copied = message.value;
                    } } } } });
                copy().click();
                await settle();
                const exactCopy = copied !== null && copied.replace(/\\n$/, '') === code;
                const height = contentHeight();
                const buttonX = copy().getBoundingClientRect().x;
                line().scrollLeft = 80;
                await settle();
                const pinned = Math.abs(copy().getBoundingClientRect().x - buttonX) < 1;
                toggle().click();
                await settle();
                const wrapped = toggle().getAttribute('aria-pressed') === 'true'
                    && contentHeight() > height + 20
                    && line().scrollWidth <= line().clientWidth + 1;
                toggle().click();
                await settle();
                return { pinned, wrapped, exactCopy,
                    restored: Math.abs(contentHeight() - height) < 1,
                    heights: { before: height, after: contentHeight(), scrollport: line().clientHeight },
                    unchanged: before === (isEditor ? window.__mdEditor.getMarkdown() : line().textContent),
                    iconOnly: copy().textContent === '' && !!copy().querySelector('svg'),
                    unwrapped: toggle().getAttribute('aria-pressed') === 'false' };
                """, arguments: ["isEditor": isEditor, "code": code], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            for name in ["pinned", "wrapped", "exactCopy", "restored", "unchanged", "iconOnly", "unwrapped"] {
                XCTAssertEqual(values[name] as? Bool, true,
                               "\(isEditor ? "Editor" : "Reader"): \(name); \(values)")
            }
        }
    }

    func testEditorSyntaxColorsMatchPreviewTokenClassesInBothPalettes() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "```javascript\nfunction demo() { return true; }\n```", editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        for palette in [MarkdownHTML.lightCodePaletteCSS, MarkdownHTML.darkCodePaletteCSS] {
            let result = try await editor.webView.callAsyncJavaScript("""
                const style = document.createElement('style');
                style.textContent = ':root {' + palette + '}' + previewRules;
                document.head.append(style);
                const pairs = [
                    ['hl-keyword', 'hljs-keyword'], ['hl-string', 'hljs-string'],
                    ['hl-comment', 'hljs-comment'], ['hl-number', 'hljs-number'],
                    ['hl-function', 'hljs-title function_'], ['hl-property', 'hljs-property'],
                    ['hl-attribute', 'hljs-attr'], ['hl-builtin', 'hljs-built_in'],
                    ['hl-declaration', 'hljs-title class_'], ['hl-meta', 'hljs-meta'],
                    ['hl-plain', 'hljs-punctuation']
                ];
                const matches = pairs.every(([edit, read]) => {
                    const a = document.createElement('span'), b = document.createElement('span');
                    a.className = edit; b.className = read;
                    a.textContent = b.textContent = 'token';
                    document.body.append(a, b);
                    const same = getComputedStyle(a).color === getComputedStyle(b).color;
                    a.remove(); b.remove();
                    return same;
                });
                style.remove();
                return matches;
                """, arguments: ["palette": palette, "previewRules": MarkdownHTML.highlightThemeCSS],
                in: nil, contentWorld: .page)
            XCTAssertEqual(result as? Bool, true)
        }
    }

    func testLanguageInputTextUsesPreviewHeaderInsets() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "```swift\nlet value = 1\n```", editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const input = document.querySelector('.cm-md-code-language-input');
                const block = input.closest('.cm-line');
                const a = input.getBoundingClientRect(), b = block.getBoundingClientRect();
                const s = getComputedStyle(input), bs = getComputedStyle(block);
                return {
                    x: a.left - b.left + parseFloat(s.paddingLeft) + parseFloat(s.borderLeftWidth) - parseFloat(bs.borderLeftWidth),
                    y: a.top - b.top + parseFloat(s.paddingTop) + parseFloat(s.borderTopWidth) - parseFloat(bs.borderTopWidth),
                    font: parseFloat(s.fontSize), line: parseFloat(s.lineHeight),
                    width: a.width,
                    actionGap: block.querySelector('.cm-md-code-toggle-wrap').getBoundingClientRect().left - a.right
                };
            })()
            """)
        let values = try XCTUnwrap(result as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(values["x"]), 16, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(values["y"]), 15, accuracy: 0.1)
        XCTAssertEqual(values["font"], 11)
        XCTAssertEqual(values["line"], 14)
        XCTAssertEqual(try XCTUnwrap(values["width"]), 154, accuracy: 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(values["actionGap"]), 100)
    }

    func testTableInlineCodeRendersAndPreservesMarkdownWhileEditing() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let markdown = "| Value |\n| --- |\n| `sadf` |\n| `` a`b `` |"
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: markdown, editorJavaScript: script),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.evaluateJavaScript("""
            (() => {
                const cell = document.querySelector('[data-table-row="1"]');
                const rendered = cell.querySelector('code')?.textContent === 'sadf';
                const nested = document.querySelector('[data-table-row="2"] code')?.textContent === 'a`b';
                const before = window.__mdEditor.getMarkdown();
                cell.focus();
                const sourceVisible = cell.textContent === '`sadf`';
                cell.blur();
                return rendered && nested && sourceVisible
                    && cell.querySelector('code')?.textContent === 'sadf'
                    && window.__mdEditor.getMarkdown() === before;
            })()
            """)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTopClearanceIsNonEditingAndScrollsAwayWithDocument() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let markdown = String(repeating: "Editable text under the floating controls.\n\n", count: 80)
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: markdown, editorJavaScript: script,
                                    configuration: .init(usesPageScrolling: true)),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            const top = document.elementFromPoint(450, 18);
            const nonEditingTop = !top.isContentEditable && getComputedStyle(top).cursor === 'default';
            document.scrollingElement.scrollTop = 150;
            for (let i = 0; i < 8; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            const line = [...document.querySelectorAll('.cm-line')].find(el => {
                const r = el.getBoundingClientRect();
                return r.top >= 0 && r.top < 36;
            });
            if (!line) return false;
            const rect = line.getBoundingClientRect();
            const target = document.elementFromPoint(rect.left + 5, rect.top + 2);
            return nonEditingTop && target.isContentEditable
                && getComputedStyle(target).cursor === 'text'
                && !document.getElementById('formatting-cursor-shield');
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testTableAnchorUsesItsWholeSourceRange() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let markdown = "Before\n\n| Key | Value |\n| --- | --- |\n"
            + (1...10).map { "| Row \($0) | Value |" }.joined(separator: "\n")
            + "\n\n" + String(repeating: "After\n\n", count: 40)
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: markdown, editorJavaScript: script,
                                    configuration: .init(usesPageScrolling: true)),
            width: 900, isEditor: true, height: 400)
        defer { editor.close() }
        _ = try await editor.layout(texts: ["Before"], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            const table = document.querySelector('.cm-md-table-widget').getBoundingClientRect();
            const scroller = document.scrollingElement;
            const offset = table.top + scroller.scrollTop + table.height / 2;
            scroller.scrollTop = offset;
            for (let i = 0; i < 8; i++) window.__layoutTestFrame();
            const anchor = window.__mdEditor.getScrollAnchor();
            scroller.scrollTop = 0;
            const restored = window.__mdEditor.setScrollPosition(0, anchor.position, anchor.gap);
            for (let i = 0; i < 8; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            await restored;
            return { position: anchor.position, drift: Math.abs(scroller.scrollTop - offset) };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Double])
        XCTAssertEqual(try XCTUnwrap(values["position"]), 9, accuracy: 0.2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values["drift"]), 1)
    }

    func testLongCodeLinesScrollTogetherWithoutWrappingOrChangingSource() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let longLine = "echo " + String(repeating: "long_argument_", count: 14)
        let markdown = "Before\n\n```bash\n\(longLine)\necho short\n```\n\nAfter"
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: markdown, editorJavaScript: script),
            width: 650, isEditor: true, height: 500)
        defer { editor.close() }
        _ = try await editor.layout(texts: ["Before", "After"], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            for (let i = 0; i < 8; i++) window.__layoutTestFrame();
            const lines = [...document.querySelectorAll('[data-code-scroll-group]')];
            const first = lines[0], last = lines.at(-1);
            const text = first.querySelector('.cm-md-code-scroll-text');
            const height = text.getBoundingClientRect().height;
            const lineHeight = parseFloat(getComputedStyle(first).lineHeight);
            first.scrollLeft = 120;
            first.dispatchEvent(new Event('scroll'));
            const originalSource = window.__mdEditor.getMarkdown();
            // Editing before the block changes its group key. Editing inside
            // it must also preserve the shared horizontal position.
            window.__mdEditor.insertTextAt('x', 0, 0);
            for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            const inside = window.__mdEditor.getMarkdown().indexOf('long_argument_') + 30;
            window.__mdEditor.insertTextAt('x', inside, inside);
            for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            const updated = [...document.querySelectorAll('[data-code-scroll-group]')];
            return { count: lines.length, overflow: first.scrollWidth - first.clientWidth,
                height, lineHeight, firstOffset: first.scrollLeft, lastOffset: last.scrollLeft,
                updatedOffsets: updated.map(line => line.scrollLeft),
                source: originalSource };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["count"] as? Int, 2)
        XCTAssertGreaterThan(try XCTUnwrap(values["overflow"] as? Double), 120)
        XCTAssertEqual(try XCTUnwrap(values["height"] as? Double), try XCTUnwrap(values["lineHeight"] as? Double), accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(values["firstOffset"] as? Double), 120, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(values["lastOffset"] as? Double), 120, accuracy: 1)
        XCTAssertEqual(values["source"] as? String, markdown)
        for offset in try XCTUnwrap(values["updatedOffsets"] as? [Double]) {
            XCTAssertEqual(offset, 120, accuracy: 1)
        }
    }

    func testSmallScrollPreservesPagePaddingInBothScrollModes() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for pageScrolling in [false, true] {
            let markdown = (1...80).map { "Paragraph \($0)." }.joined(separator: "\n\n")
            let html = EditorHTML.render(
                markdown: markdown, editorJavaScript: script,
                configuration: .init(usesPageScrolling: pageScrolling))
            let editor = WebViewLayoutHarness(html: html, width: 900, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: ["Paragraph 1."], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const scroller = pageScrolling ? document.scrollingElement : document.querySelector('.cm-scroller');
                const events = pageScrolling ? window : scroller;
                const frame = async () => { window.__layoutTestFrame(); await Promise.resolve(); };
                const first = document.querySelector('.cm-line');
                const origin = pageScrolling ? 0 : scroller.getBoundingClientRect().top;
                const initialGap = first.getBoundingClientRect().top - origin + scroller.scrollTop;
                // Restore a preview anchor 20px into the leading page padding.
                const restore = window.__mdEditor.setScrollPosition(0, 1, initialGap - 20);
                for (let i = 0; i < 8; i++) await frame();
                await restore;
                const restored = scroller.scrollTop;
                // Then scroll another 5px so capture must measure, not reuse
                // the preserved incoming source anchor.
                // Native scrolling can change the offset without delivering
                // any DOM input event. Do not manufacture scroll intent here.
                scroller.scrollTop = 25;
                events.dispatchEvent(new Event('scroll'));
                for (let i = 0; i < 4; i++) await frame();
                const anchor = window.__mdEditor.getScrollAnchor();
                let maximumDrift = 0;
                for (const offset of [25, 160, 600]) {
                    scroller.scrollTop = offset;
                    events.dispatchEvent(new Event('scroll'));
                    for (let i = 0; i < 4; i++) await frame();
                    const captured = window.__mdEditor.getScrollAnchor();
                    for (let round = 0; round < 3; round++) {
                        scroller.scrollTop = 0;
                        const restoredAnchor = window.__mdEditor.setScrollPosition(0, captured.position, captured.gap);
                        for (let i = 0; i < 8; i++) await frame();
                        await Promise.race([restoredAnchor, new Promise((_, reject) =>
                            setTimeout(() => reject(new Error('Restore did not finish at ' + offset)), 2000))]);
                        maximumDrift = Math.max(maximumDrift, Math.abs(scroller.scrollTop - offset));
                    }
                }
                return { restored, position: anchor.position, gap: anchor.gap, expectedGap: initialGap - 25, maximumDrift };
                """, arguments: ["pageScrolling": pageScrolling], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(values["restored"]), 20, accuracy: 1, "pageScrolling=\(pageScrolling)")
            XCTAssertEqual(try XCTUnwrap(values["position"]), 1, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(values["gap"]), try XCTUnwrap(values["expectedGap"]), accuracy: 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(values["maximumDrift"]), 1)
        }
    }
}
