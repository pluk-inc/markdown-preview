import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorScrollAnchorTests: XCTestCase {
    func testDocumentControlsFollowThemeAccentInReaderAndEditor() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let source = "Introduction\n\n- Bullet\n\n1. Number\n\n[Link](https://example.com)"
        for isEditor in [false, true] {
            for dark in [false, true] {
                let html = isEditor
                    ? EditorHTML.render(markdown: source, editorJavaScript: script)
                    : MarkdownHTML.render(markdown: source, allowsScroll: true).html
                let harness = WebViewLayoutHarness(html: html, width: 650, isEditor: isEditor, height: 500)
                defer { harness.close() }
                harness.webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                _ = try await harness.layout(texts: [], imageCount: 0)
                // Exercise live changes and returning to Original, not only initial rendering.
                for name in ["Paper", "Graphite", "Original"] {
                    let preset = try XCTUnwrap(ThemePreset.builtIn.first { $0.name == name })
                    let css = isEditor ? preset.setting.editorOverrideCSS
                        : (preset.setting.markdownThemeOverrides?.css ?? "")
                    let matches = try await harness.webView.callAsyncJavaScript("""
                        document.getElementById(styleID).textContent = css;
                        const link = document.querySelector(isEditor ? '.cm-md-link' : 'a');
                        const bullet = document.querySelector(isEditor ? '.cm-md-bullet' : 'ul > li');
                        const number = document.querySelector(isEditor ? '.cm-md-ordered' : 'ol > li');
                        if (!link || !bullet || !number) return false;
                        const accent = getComputedStyle(link).color;
                        const listsMatch = getComputedStyle(bullet, isEditor ? '::after' : '::before').borderTopColor === accent
                            && getComputedStyle(number, isEditor ? null : '::marker').color === accent;
                        const table = document.createElement('table');
                        table.className = isEditor ? 'cm-md-table-grid' : 'md-table-editor';
                        const header = document.createElement('th');
                        header.textContent = 'Header';
                        table.createTHead().insertRow().append(header);
                        const td = table.insertRow().insertCell();
                        const cell = isEditor ? td.appendChild(document.createElement('div')) : td;
                        cell.className = isEditor ? 'cm-md-table-cell' : 'is-editing';
                        cell.contentEditable = 'true';
                        document.body.append(table);
                        const headerClear = getComputedStyle(header).backgroundColor === 'rgba(0, 0, 0, 0)';
                        // This harness has no key window, so WebKit does not apply :focus.
                        // Evaluate the actual production focus declaration through a test class.
                        const focusStyle = document.createElement('style');
                        if (isEditor) {
                            const rule = [...document.styleSheets].flatMap(sheet => [...sheet.cssRules])
                                .find(rule => rule.selectorText === '.cm-md-table-cell:focus');
                            if (!rule) return 'missing focus rule';
                            focusStyle.textContent = '.theme-focus-probe {' + rule.style.cssText + '}';
                            document.head.append(focusStyle);
                            cell.classList.add('theme-focus-probe');
                        }
                        const expected = document.createElement('span');
                        expected.style.background = 'color-mix(in srgb, var(--link) 8%, transparent)';
                        document.body.append(expected);
                        const focusMatches = getComputedStyle(cell).outlineColor === accent
                            && getComputedStyle(cell).backgroundColor === getComputedStyle(expected).backgroundColor;
                        focusStyle.remove();
                        cell.classList.remove('theme-focus-probe');
                        cell.classList.remove('is-editing');
                        cell.classList.add('is-table-part-selected', 'is-table-selection-top',
                            'is-table-selection-right', 'is-table-selection-bottom', 'is-table-selection-left');
                        expected.style.background = 'color-mix(in srgb, var(--link) 14%, Canvas)';
                        expected.style.boxShadow = [
                            'inset 0 1px', 'inset -1px 0', 'inset 0 -1px', 'inset 1px 0'
                        ].map(edge => edge + ' color-mix(in srgb, var(--link) 52%, transparent)').join(',');
                        const selectionMatches = getComputedStyle(cell).backgroundColor === getComputedStyle(expected).backgroundColor
                            && getComputedStyle(cell).boxShadow === getComputedStyle(expected).boxShadow;
                        let checkboxMatches = true;
                        if (!isEditor) {
                            const checkbox = document.createElement('input');
                            checkbox.type = 'checkbox'; checkbox.checked = true;
                            checkbox.className = 'task-list-item-checkbox';
                            document.body.append(checkbox);
                            checkboxMatches = getComputedStyle(checkbox).backgroundColor === accent
                                && getComputedStyle(checkbox).borderTopColor === accent;
                            checkbox.remove();
                        }
                        const details = JSON.stringify({listsMatch, focusMatches, selectionMatches, checkboxMatches, headerClear});
                        table.remove(); expected.remove();
                        return listsMatch && focusMatches && selectionMatches && checkboxMatches && headerClear ? 'pass' : details;
                        """, arguments: ["styleID": MarkdownHTML.themeStyleElementID,
                                           "css": css, "isEditor": isEditor],
                        in: nil, contentWorld: .page) as? String
                    XCTAssertEqual(matches, "pass", "\(name), dark=\(dark), editor=\(isEditor)")
                }
            }
        }
    }

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
                const line = () => document.querySelector(isEditor ? '.cm-md-code-card' : '.md-code-wrap pre');
                const copy = () => document.querySelector(isEditor ? '.cm-md-code-copy' : '.md-code-copy');
                // Measure text layout independently of the native scrollport.
                // WebKit can add/remove scrollbar space during wrap changes.
                const contentHeight = () => {
                    const texts = isEditor ? [...line().querySelectorAll('.cm-md-code-scroll-text')]
                        : [line().querySelector('code')];
                    const bounds = texts.map(text => {
                        const range = document.createRange();
                        range.selectNodeContents(text);
                        return range.getBoundingClientRect();
                    });
                    return Math.max(...bounds.map(rect => rect.bottom)) - Math.min(...bounds.map(rect => rect.top));
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
                const pinnedImmediately = Math.abs(copy().getBoundingClientRect().x - buttonX) < 1;
                await settle();
                const pinned = Math.abs(copy().getBoundingClientRect().x - buttonX) < 1;
                toggle().click();
                await settle();
                const wrapped = toggle().getAttribute('aria-pressed') === 'true'
                    && contentHeight() > height + 20
                    && line().scrollWidth <= line().clientWidth + 1;
                toggle().click();
                await settle();
                return { pinned, pinnedImmediately, wrapped, exactCopy,
                    restored: Math.abs(contentHeight() - height) < 1,
                    heights: { before: height, after: contentHeight(), scrollport: line().clientHeight },
                    unchanged: before === (isEditor ? window.__mdEditor.getMarkdown() : line().textContent),
                    iconOnly: copy().textContent === '' && !!copy().querySelector('svg'),
                    unwrapped: toggle().getAttribute('aria-pressed') === 'false' };
                """, arguments: ["isEditor": isEditor, "code": code], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            for name in ["pinned", "pinnedImmediately", "wrapped", "exactCopy", "restored", "unchanged", "iconOnly", "unwrapped"] {
                XCTAssertEqual(values[name] as? Bool, true,
                               "\(isEditor ? "Editor" : "Reader"): \(name); \(values)")
            }
        }
    }

    func testCodeCardBackgroundStaysInsideScrollport() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for multiline in [false, true] {
            let code = String(repeating: "long code text ", count: 30)
                + (multiline ? "\nshort last line" : "")
            let editor = WebViewLayoutHarness(html: EditorHTML.render(
                markdown: "```text\n" + code + "\n```", editorJavaScript: script),
                width: 500, isEditor: true, height: 600)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                const settle = async () => { for (let i = 0; i < 8; i++) {
                    window.__layoutTestFrame(); await new Promise(r => setTimeout(r, 15));
                }};
                const card = () => document.querySelector('.cm-md-code-card');
                const origin = card().getBoundingClientRect().left;
                const measurements = [];
                const measure = () => {
                    const bounds = card().getBoundingClientRect();
                    const style = getComputedStyle(card());
                    measurements.push({
                        widthError: Math.abs(bounds.width - document.querySelector('.cm-content').clientWidth),
                        offsetError: Math.abs(bounds.left - origin),
                        rounded: parseFloat(style.borderTopRightRadius) > 0
                            && parseFloat(style.borderBottomRightRadius) > 0
                    });
                };
                const overflow = card().scrollWidth - card().clientWidth;
                for (const offset of [0, 120, overflow]) {
                    card().scrollLeft = offset;
                    await settle();
                    measure();
                }
                document.querySelector('.cm-md-code-toggle-wrap').click();
                await settle();
                measure();
                document.querySelector('.cm-md-code-toggle-wrap').click();
                await settle();
                measure();
                return { overflow, measurements };
                """, arguments: [:], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            XCTAssertGreaterThan(try XCTUnwrap(values["overflow"] as? Double), 120)
            for measurement in try XCTUnwrap(values["measurements"] as? [[String: Any]]) {
                XCTAssertLessThanOrEqual(try XCTUnwrap(measurement["widthError"] as? Double), 1)
                XCTAssertLessThanOrEqual(try XCTUnwrap(measurement["offsetError"] as? Double), 1)
                XCTAssertEqual(measurement["rounded"] as? Bool, true)
            }
        }
    }

    func testCodeCardScrollingKeepsControlsAndPageFixed() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for pageScrolling in [false, true] {
            let editor = WebViewLayoutHarness(html: EditorHTML.render(
                markdown: "```text\n" + String(repeating: "long code ", count: 100) + "\n```",
                editorJavaScript: script, configuration: .init(usesPageScrolling: pageScrolling)),
                width: 500, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.evaluateJavaScript("""
                (() => {
                    // Exercise space-consuming scrollbars as on the macOS 15 CI runner.
                    const style = document.createElement('style');
                    style.textContent = '.cm-md-code-card::-webkit-scrollbar { width: 15px; height: 15px; }';
                    document.head.appendChild(style);
                    const line = document.querySelector('.cm-md-code-card');
                    const button = line.querySelector('.cm-md-code-copy');
                    const x = button.getBoundingClientRect().x;
                    const scrollers = [document.scrollingElement, document.querySelector('.cm-scroller')];
                    const max = line.scrollWidth - line.clientWidth;
                    let pinned = max > 120;
                    const positions = [];
                    for (const offset of [1, 8, 120, max, 0]) {
                        line.scrollLeft = offset;
                        positions.push({offset, x: button.getBoundingClientRect().x, expected: x});
                        pinned &&= Math.abs(button.getBoundingClientRect().x - x) < 1;
                    }
                    return { pinned, positions, pageFixed: scrollers.every(s => s.scrollWidth <= s.clientWidth + 1 && s.scrollLeft === 0),
                        scrollers: scrollers.map(s => [s.scrollWidth, s.clientWidth, s.scrollLeft]) };
                })()
                """)
            let values = try XCTUnwrap(result as? [String: Any])
            for key in ["pinned", "pageFixed"] {
                XCTAssertEqual(values[key] as? Bool, true, "Page scrolling: \(pageScrolling); \(values)")
            }
        }
    }

    func testEmptyCodeLinesKeepCaretAndHeaderInsets() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for body in ["", "first\n\nlast"] {
            let markdown = "```text\n" + body + "\n```"
            let position = body.isEmpty ? 8 : 14
            let editor = WebViewLayoutHarness(html: EditorHTML.render(
                markdown: markdown, editorJavaScript: script), width: 500, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.callAsyncJavaScript("""
                window.__mdEditor.select(position);
                window.__mdEditor.focus();
                for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                const card = document.querySelector('.cm-md-code-card');
                const blank = [...card.querySelectorAll('.cm-md-codeblock')]
                    .find(line => !line.querySelector('.cm-md-code-scroll-text'));
                const bounds = card.getBoundingClientRect();
                const border = parseFloat(getComputedStyle(card).borderLeftWidth);
                const range = document.createRange();
                range.selectNode(blank.querySelector('br'));
                const inset = range.getBoundingClientRect().left - bounds.left - border;
                const headerX = card.querySelector('.cm-md-code-language').getBoundingClientRect().left;
                window.__mdEditor.insertTextAt('x', position, position);
                for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
                const text = [...card.querySelectorAll('.cm-md-code-scroll-text')].find(node => node.textContent === 'x');
                const typed = document.createRange();
                typed.selectNodeContents(text);
                return { inset, typedInset: typed.getBoundingClientRect().left - bounds.left - border,
                    headerShift: card.querySelector('.cm-md-code-language').getBoundingClientRect().left - headerX,
                    overflow: card.scrollWidth - card.clientWidth };
                """, arguments: ["position": position], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Double])
            XCTAssertEqual(try XCTUnwrap(values["inset"]), 16, accuracy: 1, "\(values)")
            XCTAssertEqual(try XCTUnwrap(values["typedInset"]), 16, accuracy: 1, "\(values)")
            XCTAssertEqual(try XCTUnwrap(values["headerShift"]), 0, accuracy: 1, "\(values)")
            XCTAssertLessThanOrEqual(try XCTUnwrap(values["overflow"]), 1, "\(values)")
        }
    }

    func testReaderWideHTMLRemainsReachableAndLongTextWraps() async throws {
        let longText = String(repeating: "longword", count: 120)
        let html = MarkdownHTML.render(markdown: longText + "\n\n<video width=\"1200\" controls></video>",
                                       allowsScroll: true).html
        let reader = WebViewLayoutHarness(html: html, width: 500, isEditor: false, height: 400)
        defer { reader.close() }
        _ = try await reader.layout(texts: [], imageCount: 0)
        let result = try await reader.webView.evaluateJavaScript("""
            (() => {
                const article = document.querySelector('article.markdown-body');
                const text = document.createRange();
                text.selectNodeContents(article.querySelector('p'));
                const wrapped = [...text.getClientRects()].every(rect => rect.width <= article.clientWidth + 1);
                article.scrollLeft = article.scrollWidth;
                const video = article.querySelector('video').getBoundingClientRect();
                return { wrapped, reachable: article.scrollLeft > 0 && video.right <= article.getBoundingClientRect().right + 1,
                    pageLocked: getComputedStyle(document.scrollingElement).overflowX === 'hidden' };
            })()
            """)
        let values = try XCTUnwrap(result as? [String: Bool])
        for key in ["wrapped", "reachable", "pageLocked"] { XCTAssertEqual(values[key], true, "\(values)") }
    }

    func testLongEditorParagraphRemainsWithinPage() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        for pageScrolling in [false, true] {
            let editor = WebViewLayoutHarness(html: EditorHTML.render(
                markdown: String(repeating: "longword", count: 120), editorJavaScript: script,
                configuration: .init(usesPageScrolling: pageScrolling)), width: 500, isEditor: true, height: 400)
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0)
            let result = try await editor.webView.evaluateJavaScript("""
                (() => {
                    const line = document.querySelector('.cm-line');
                    const text = document.createRange();
                    text.selectNodeContents(line);
                    return [...text.getClientRects()].every(rect => rect.width <= line.clientWidth + 1)
                        && document.scrollingElement.scrollWidth <= window.innerWidth + 1;
                })()
                """)
            XCTAssertEqual(result as? Bool, true, "Page scrolling: \(pageScrolling)")
        }
    }

    func testCodeScrollPolicyMatchesReadMode() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let markdown = "```text\n" + String(repeating: "long code ", count: 100) + "\n```"
        var policies: [[String: String]] = []
        for isEditor in [false, true] {
            let html = isEditor
                ? EditorHTML.render(markdown: markdown, editorJavaScript: script)
                : MarkdownHTML.render(markdown: markdown, allowsScroll: true).html
            let harness = WebViewLayoutHarness(html: html, width: 500, isEditor: isEditor, height: 400)
            defer { harness.close() }
            _ = try await harness.layout(texts: [], imageCount: 0)
            let result = try await harness.webView.evaluateJavaScript("""
                (() => {
                    const style = getComputedStyle(document.querySelector('\(isEditor ? ".cm-md-code-card" : ".md-code-wrap pre")'));
                    return Object.fromEntries(['overflowX', 'overscrollBehaviorX', 'scrollbarWidth', 'scrollBehavior']
                        .map(property => [property, style[property]]));
                })()
                """)
            policies.append(try XCTUnwrap(result as? [String: String]))
        }
        XCTAssertEqual(policies[0], policies[1])
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

    func testMarkdownMarkersDoNotUseCodePaletteInOriginalDarkAppearance() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let editor = WebViewLayoutHarness(
            html: EditorHTML.render(markdown: "## [Unreleased]\n\n[Real link](https://example.com)\n\n```c\n#include <stdio.h>\n```",
                                    editorJavaScript: script),
            width: 900, isEditor: true, height: 600)
        defer { editor.close() }
        editor.webView.appearance = NSAppearance(named: .darkAqua)
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            const heading = [...document.querySelectorAll('.cm-line')]
                .find(node => node.textContent.includes('[Unreleased]'));
            const link = document.querySelector('.cm-md-link');
            const metadata = [...document.querySelectorAll('.hl-meta')];
            return {
                markdownClean: !heading?.querySelector('.hl-meta') && !!heading,
                linkBlue: !!link && getComputedStyle(link).color === 'rgb(65, 156, 255)',
                codeOrange: metadata.some(node => node.textContent.includes('#include')
                    && getComputedStyle(node).color === 'rgb(253, 143, 63)')
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Bool]
        XCTAssertEqual(result?["markdownClean"], true)
        XCTAssertEqual(result?["linkBlue"], true)
        XCTAssertEqual(result?["codeOrange"], true)
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
            const card = first.closest('.cm-md-code-card');
            const initialX = lines.map(line => line.getBoundingClientRect().left);
            const overflow = card.scrollWidth - card.clientWidth;
            card.scrollLeft = 120;
            const deltas = lines.map((line, index) => initialX[index] - line.getBoundingClientRect().left);
            const originalSource = window.__mdEditor.getMarkdown();
            // Editing before the block changes its group key. Editing inside
            // it must also preserve the shared horizontal position.
            window.__mdEditor.insertTextAt('x', 0, 0);
            for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            const inside = window.__mdEditor.getMarkdown().indexOf('long_argument_') + 30;
            window.__mdEditor.insertTextAt('x', inside, inside);
            for (let i = 0; i < 12; i++) { window.__layoutTestFrame(); await Promise.resolve(); }
            const updated = [...document.querySelectorAll('[data-code-scroll-group]')];
            return { count: lines.length, overflow,
                height, lineHeight, deltas, singleScrollport: lines.every(line => line.scrollLeft === 0),
                updatedOffset: document.querySelector('.cm-md-code-card').scrollLeft,
                source: originalSource };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["count"] as? Int, 2)
        XCTAssertGreaterThan(try XCTUnwrap(values["overflow"] as? Double), 120)
        XCTAssertEqual(try XCTUnwrap(values["height"] as? Double), try XCTUnwrap(values["lineHeight"] as? Double), accuracy: 1)
        XCTAssertEqual(values["singleScrollport"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(values["updatedOffset"] as? Double), 120, accuracy: 1)
        XCTAssertEqual(values["source"] as? String, markdown)
        for offset in try XCTUnwrap(values["deltas"] as? [Double]) {
            XCTAssertEqual(offset, 120, accuracy: 1)
        }
    }

    func testMainPageOnlyScrollsVerticallyWhileCodeAndTablesScrollHorizontally() async throws {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let columns = Array(repeating: "LongColumnName", count: 12).joined(separator: " | ")
        let divider = Array(repeating: "---", count: 12).joined(separator: " | ")
        let markdown = "```text\n" + String(repeating: "long code ", count: 100)
            + "\n```\n\n| " + columns + " |\n| " + divider + " |\n| " + columns + " |\n\n"
            + String(repeating: "Paragraph.\n\n", count: 80)
        for mode in ["reader", "editor-page", "editor-internal"] {
            let isEditor = mode != "reader"
            let pageScrolling = mode != "editor-internal"
            let html = isEditor
                ? EditorHTML.render(markdown: markdown, editorJavaScript: script,
                                    configuration: .init(usesPageScrolling: pageScrolling))
                : MarkdownHTML.render(markdown: markdown, allowsScroll: true).html
            let harness = WebViewLayoutHarness(html: html, width: 500, isEditor: isEditor, height: 400)
            defer { harness.close() }
            _ = try await harness.layout(texts: [], imageCount: 0)
            let result = try await harness.webView.evaluateJavaScript("""
                (() => {
                    const page = \(pageScrolling ? "document.scrollingElement" : "document.querySelector('.cm-scroller')");
                    const style = getComputedStyle(page);
                    const nested = [...document.querySelectorAll('\(isEditor ? ".cm-md-code-card, .cm-md-table-scroll" : ".md-code-wrap pre, table")')];
                    const innerScrolling = nested.length === 2 && nested.every(element => {
                        element.scrollLeft = 80;
                        return element.scrollLeft > 0;
                    });
                    page.scrollTop = 100;
                    return { locked: style.overflowX === 'hidden' && style.overscrollBehaviorX === 'none',
                        vertical: page.scrollTop > 0, innerScrolling, pageLeft: page.scrollLeft,
                        // A direct scrollTop assignment still passes when the article steals wheel
                        // gestures through a 1px vertical overflow. Check its user-scroll axis too.
                        verticalGesturesReachPage: \(isEditor ? "true" : "getComputedStyle(document.querySelector('article.markdown-body')).overflowY === 'hidden'") };
                })()
                """)
            let values = try XCTUnwrap(result as? [String: Any])
            for key in ["locked", "vertical", "innerScrolling", "verticalGesturesReachPage"] {
                XCTAssertEqual(values[key] as? Bool, true, "\(mode): \(values)")
            }
            XCTAssertEqual(values["pageLeft"] as? Double, 0, "\(mode): \(values)")
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
