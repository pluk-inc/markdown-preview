import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorPreviewLayoutTests: XCTestCase {
    private final class HostBridge: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }
    struct Fixture {
        let name: String
        let markdown: String
        let texts: [String]
        var imageCount = 0
        var editorImageCount: Int? = nil
        var readSelectors: [String: Int] = [:]
        var editorSelectors: [String: Int] = [:]
        var readBoxes: [String: String] = [:]
        var editorBoxes: [String: String] = [:]
        var styles: [String: [String: String]] = [:]
        var editorSourceSnippets: [String] = []
        /// A documented source-editing contract, not a claim of visual parity.
        var sourceRepresentationReason: String? = nil
        /// Shared text still has to match horizontally and within each block.
        var localParityTexts: [String] = []
        var height: CGFloat = 1800
    }

    var image: String {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="80">
        <rect width="240" height="80" fill="royalblue"/></svg>
        """
        return "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
    }

    func testMathRendersWithSharedKaTeX() async throws {
        let source = "Inline $x_1 + x_2$.\n\n$$\nE = mc^2\n$$\n\n```math\nx^2\n```"
        let html = EditorHTML.render(markdown: source,
            editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
        let editor = WebViewLayoutHarness(html: html, width: 900, isEditor: true,
            schemeHandlers: ["md-asset": EditorMathAssets()])
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0,
            selectors: [".katex": 3, ".katex-display": 2, ".katex-error": 0])
        let saved = try await editor.webView.evaluateJavaScript("window.__mdEditor.getMarkdown()")
        XCTAssertEqual(saved as? String, source)
    }

    func testInlineMathSourceUsesInlineCodeStyling() async throws {
        let source = "Code `x^2`; math $x^2$; literal $ x^2 $."
        let html = EditorHTML.render(markdown: source,
            editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
        let editor = WebViewLayoutHarness(html: html, width: 500, isEditor: true,
            schemeHandlers: ["md-asset": EditorMathAssets()])
        let window = NSWindow(contentRect: editor.webView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = editor.webView
        defer { editor.close(); window.contentView = nil }
        _ = try await editor.layout(texts: [], imageCount: 0,
            selectors: [".katex": 1, ".cm-md-inline-code": 1])
        let result = try await editor.webView.callAsyncJavaScript("""
            document.hasFocus = () => true;
            window.__mdEditor.focus();
            window.__mdEditor.select(source.indexOf('$x') + 2);
            for (let i = 0; i < 4; i++) {
                window.__layoutTestFrame();
                await new Promise(resolve => setTimeout(resolve, 10));
            }
            const spans = [...document.querySelectorAll('.cm-md-inline-code')];
            const styles = spans.map(span => {
                const style = getComputedStyle(span);
                return [style.fontFamily, style.fontSize, style.backgroundColor,
                    style.border, style.borderRadius, style.padding];
            });
            return {
                content: spans.map(span => span.textContent),
                sameStyle: styles.length === 2 && JSON.stringify(styles[0]) === JSON.stringify(styles[1]),
                literal: document.querySelector('.cm-content').textContent.includes('$ x^2 $'),
                cards: document.querySelectorAll('.cm-md-code-card').length,
                markdown: window.__mdEditor.getMarkdown()
            };
            """, arguments: ["source": source], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["content"] as? [String], ["x^2", "x^2"])
        XCTAssertEqual(values["sameStyle"] as? Bool, true)
        XCTAssertEqual(values["literal"] as? Bool, true)
        XCTAssertEqual(values["cards"] as? Int, 0)
        XCTAssertEqual(values["markdown"] as? String, source)
        _ = try await editor.webView.evaluateJavaScript("window.__mdEditor.select(\(source.count))")
        _ = try await editor.layout(texts: [], imageCount: 0,
            selectors: [".katex": 1, ".cm-md-inline-code": 1])
    }

    func testMathSourceUsesTheSharedCodeCard() async throws {
        for (formula, fenced, scrolls) in [
            ("$$\n\\frac{1}{x}\n$$", false, false),
            ("$$ \\frac{1}{x} $$", false, false),
            ("> $$\n> \\frac{1}{x}\n> $$", false, false),
            ("- $$\n  \\frac{1}{x}\n  $$", false, false),
            ("$$\n\\frac{1}{" + String(repeating: "x", count: 240) + "}\n$$", false, true),
            ("```math\n\\frac{1}{x}\n```", true, false),
        ] {
            let source = "Before\n\n" + formula + "\n\nAfter"
            let html = EditorHTML.render(markdown: source,
                editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
            let editor = WebViewLayoutHarness(html: html, width: 500, isEditor: true,
                schemeHandlers: ["md-asset": EditorMathAssets()])
            let window = NSWindow(contentRect: editor.webView.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = editor.webView
            defer {
                editor.close()
                window.contentView = nil
            }
            _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
            let result = try await editor.webView.callAsyncJavaScript("""
                // Supply focus for the hidden host, as in the marker-editing tests.
                document.hasFocus = () => true;
                window.__mdEditor.focus();
                window.__mdEditor.select(source.indexOf('frac') + 2);
                for (let i = 0; i < 4; i++) {
                    window.__layoutTestFrame();
                    await new Promise(resolve => setTimeout(resolve, 10));
                }
                const card = document.querySelector('.cm-md-code-card');
                const delimiters = [...document.querySelectorAll('.cm-md-fence-info')];
                return {
                    cards: document.querySelectorAll('.cm-md-code-card').length,
                    language: card?.querySelector('.cm-md-code-language-input')?.value || '',
                    actions: card?.querySelectorAll('.cm-md-code-action').length,
                    rows: card?.querySelectorAll('.cm-line').length,
                    delimiters: delimiters.map(node => node.textContent).join(''),
                    visible: delimiters.every(node => getComputedStyle(node).visibility === 'visible'),
                    scrolls: card && card.scrollWidth > card.clientWidth,
                    widths: card && [card.scrollWidth, card.clientWidth],
                    radius: card && getComputedStyle(card).borderRadius,
                    rendered: !!document.querySelector('.math-display'),
                    markdown: window.__mdEditor.getMarkdown()
                };
                """, arguments: ["source": source], in: nil, contentWorld: .page)
            let values = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(values["cards"] as? Int, 1, formula)
            XCTAssertEqual(values["language"] as? String, fenced ? "math" : "", formula)
            XCTAssertEqual(values["actions"] as? Int, fenced ? 2 : 0, formula)
            XCTAssertEqual(values["rows"] as? Int, fenced ? 1 : formula.components(separatedBy: "\n").count, formula)
            if !fenced {
                XCTAssertEqual(values["delimiters"] as? String, "$$$$", formula)
                XCTAssertEqual(values["visible"] as? Bool, true, formula)
            }
            XCTAssertEqual(values["scrolls"] as? Bool, scrolls, "\(formula) widths: \(values["widths"] ?? "missing")")
            XCTAssertEqual(values["radius"] as? String, "16px", formula)
            XCTAssertEqual(values["rendered"] as? Bool, false, formula)
            XCTAssertEqual(values["markdown"] as? String, source)
            if fenced {
                let wrapped = try await editor.webView.callAsyncJavaScript("""
                    document.querySelector('.cm-md-code-toggle-wrap').click();
                    for (let i = 0; i < 4; i++) {
                        window.__layoutTestFrame();
                        await new Promise(resolve => setTimeout(resolve, 10));
                    }
                    const card = document.querySelector('.cm-md-code-card-wrapped');
                    return !!card && card.scrollWidth <= card.clientWidth
                        && window.__mdEditor.getMarkdown() === source;
                    """, arguments: ["source": source], in: nil, contentWorld: .page)
                XCTAssertEqual(wrapped as? Bool, true, formula)
            }
            _ = try await editor.webView.evaluateJavaScript("window.__mdEditor.select(\(source.count))")
            _ = try await editor.layout(texts: [], imageCount: 0,
                selectors: [".katex": 1, ".cm-md-code-card": 0])
        }
    }

    func testNativeTypingCompletesDollarMath() async throws {
        let html = EditorHTML.render(markdown: "",
            editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
        let editor = WebViewLayoutHarness(html: html, width: 500, isEditor: true,
            schemeHandlers: ["md-asset": EditorMathAssets()])
        let window = NSWindow(contentRect: editor.webView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = editor.webView
        defer { editor.close(); window.contentView = nil }
        _ = try await editor.layout(texts: [], imageCount: 0)
        let result = try await editor.webView.callAsyncJavaScript("""
            document.hasFocus = () => true;
            window.__mdEditor.focus();
            const settle = async () => {
                for (let i = 0; i < 4; i++) {
                    window.__layoutTestFrame();
                    await new Promise(resolve => setTimeout(resolve, 10));
                }
            };
            for (const character of '$$') {
                document.execCommand('insertText', false, character);
                await settle();
            }
            const unpaired = window.__mdEditor.getMarkdown();
            document.execCommand('insertParagraph', false);
            await settle();
            const paired = window.__mdEditor.getMarkdown();
            const caret = window.__mdEditor.getLinkSelection(false).from;
            document.execCommand('insertText', false, 'x');
            await settle();
            return { unpaired, paired, caret, markdown: window.__mdEditor.getMarkdown() };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["unpaired"] as? String, "$$")
        XCTAssertEqual(values["paired"] as? String, "$$\n\n$$")
        XCTAssertEqual(values["caret"] as? Int, 3)
        XCTAssertEqual(values["markdown"] as? String, "$$\nx\n$$")
    }

    func testClickingMathPreservesOpeningDelimiters() async throws {
        for (formula, offset) in [("$x$", 1), ("$$x$$", 2), ("$$\nx\n$$", 3)] {
            let source = "Before\n\n" + formula + "\n\nAfter"
            let html = EditorHTML.render(markdown: source,
                editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
            let editor = WebViewLayoutHarness(html: html, width: 500, isEditor: true,
                schemeHandlers: ["md-asset": EditorMathAssets()])
            let window = NSWindow(contentRect: editor.webView.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = editor.webView
            defer { editor.close(); window.contentView = nil }
            _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
            let result = try await editor.webView.callAsyncJavaScript("""
                document.hasFocus = () => true;
                document.querySelector('.math').dispatchEvent(new MouseEvent('mousedown', {
                    bubbles: true, cancelable: true
                }));
                document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
                for (let i = 0; i < 4; i++) {
                    window.__layoutTestFrame();
                    await new Promise(resolve => setTimeout(resolve, 10));
                }
                document.execCommand('insertText', false, 'z');
                for (let i = 0; i < 4; i++) {
                    window.__layoutTestFrame();
                    await new Promise(resolve => setTimeout(resolve, 10));
                }
                return window.__mdEditor.getMarkdown();
                """, arguments: [:], in: nil, contentWorld: .page)
            var expected = source
            expected.insert("z", at: expected.index(expected.startIndex, offsetBy: 8 + offset))
            XCTAssertEqual(result as? String, expected)
        }
    }

    func testClickingFencedMathHidesRawFences() async throws {
        let source = "Before\n\n```math\n\\frac{1}{x}\n```\n\nAfter"
        let html = EditorHTML.render(markdown: source,
            editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
        let editor = WebViewLayoutHarness(html: html, width: 500, isEditor: true,
            schemeHandlers: ["md-asset": EditorMathAssets()])
        let window = NSWindow(contentRect: editor.webView.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = editor.webView
        defer { editor.close(); window.contentView = nil }
        _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
        let result = try await editor.webView.callAsyncJavaScript("""
            document.hasFocus = () => true;
            document.querySelector('.math-display').dispatchEvent(new MouseEvent('mousedown', {
                bubbles: true, cancelable: true
            }));
            document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            for (let i = 0; i < 4; i++) {
                window.__layoutTestFrame();
                await new Promise(resolve => setTimeout(resolve, 10));
            }
            const raw = [...document.querySelectorAll('.cm-line')].find(line => line.textContent.includes('```math'));
            return {
                rawHeight: raw?.getBoundingClientRect().height || 0,
                language: document.querySelector('.cm-md-code-language-input')?.value,
                caret: window.__mdEditor.getLinkSelection(false).from,
                markdown: window.__mdEditor.getMarkdown()
            };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["rawHeight"] as? Double, 0)
        XCTAssertEqual(values["language"] as? String, "math")
        XCTAssertEqual(values["caret"] as? Int, source.range(of: "\\frac")!.lowerBound.utf16Offset(in: source))
        XCTAssertEqual(values["markdown"] as? String, source)
    }

    func testKeyboardEntryRevealsFencedMathSource() async throws {
        let source = "Before\n\n```math\nx^2\n```\n\nAfter"
        let html = EditorHTML.render(markdown: source,
            editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
        let editor = WebViewLayoutHarness(html: html, width: 900, isEditor: true,
            schemeHandlers: ["md-asset": EditorMathAssets()])
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
        let result = try await editor.webView.callAsyncJavaScript("""
            window.__mdEditor.focus();
            window.__mdEditor.select(7);
            for (let i = 0; i < 2; i++) {
                document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'ArrowRight', code: 'ArrowRight', bubbles: true, cancelable: true
                }));
                window.__layoutTestFrame();
            }
            return {
                rendered: !!document.querySelector('.math-display'),
                sourceVisible: document.querySelector('.cm-content').textContent.includes('x^2'),
                markdown: window.__mdEditor.getMarkdown()
            };
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["rendered"] as? Bool, false)
        XCTAssertEqual(values["sourceVisible"] as? Bool, true)
        XCTAssertEqual(values["markdown"] as? String, source)
    }

    func testQuotedMathDoesNotAddEmptyDelimiterLines() async throws {
        for source in [">$$\n>equation\n>$$", "> $$\n> x^2\n> $$"] {
            let html = EditorHTML.render(markdown: source,
                editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
            let editor = WebViewLayoutHarness(html: html, width: 900, isEditor: true,
                schemeHandlers: ["md-asset": EditorMathAssets()])
            defer { editor.close() }
            _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
            let extraHeight = try await editor.webView.evaluateJavaScript("""
                (() => {
                    const math = document.querySelector('.math-display');
                    const line = math.closest('.cm-line');
                    const style = getComputedStyle(line);
                    return line.getBoundingClientRect().height - math.getBoundingClientRect().height
                        - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
                })()
                """)
            // The line's strut can stand a pixel taller than a short formula;
            // an empty delimiter line would add a whole source line.
            XCTAssertLessThan(try XCTUnwrap(extraHeight as? Double), MarkdownHTML.sourceLineHeight / 2, source)
            let saved = try await editor.webView.evaluateJavaScript("window.__mdEditor.getMarkdown()")
            XCTAssertEqual(saved as? String, source)
        }
    }

    func testDisplayMathSpacingMatchesPreview() async throws {
        for (name, formula) in [
            ("single-line", "$$ x^2 $$"),
            ("multiline", "$$\nx^2\n$$"),
            ("fenced", "```math\nx^2\n```"),
        ] {
            try await check(Fixture(name: "math-spacing-\(name)",
                markdown: "Before equation.\n\n\(formula)\n\nAfter equation.",
                texts: ["Before equation.", "After equation."],
                readSelectors: [".katex": 1], editorSelectors: [".katex": 1]))
        }
    }

    func testArrowKeysEnterRenderedMath() async throws {
        for formula in ["$$x$$", "$$\nx\ny\n$$", "```math\nx\ny\n```",
                        "> $$\n> x\n> $$", "- $$\n  x\n  $$"] {
            let source = "Before\n\n" + formula + "\n\nAfter"
            let html = EditorHTML.render(markdown: source,
                editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
            let editor = WebViewLayoutHarness(html: html, width: 500, isEditor: true,
                schemeHandlers: ["md-asset": EditorMathAssets()])
            let window = NSWindow(contentRect: editor.webView.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.contentView = editor.webView
            defer { editor.close(); window.contentView = nil }
            _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
            let result = try await editor.webView.callAsyncJavaScript("""
                document.hasFocus = () => true;
                const settle = async () => {
                    for (let i = 0; i < 4; i++) window.__layoutTestFrame();
                    await new Promise(resolve => setTimeout(resolve, 10));
                };
                const traces = [];
                for (const [key, start] of [['ArrowDown', 0], ['ArrowUp', source.length]]) {
                    window.__mdEditor.focus();
                    window.__mdEditor.select(start);
                    await settle();
                    const positions = [];
                    for (let i = 0; i < 4; i++) {
                        document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
                            key, code: key, bubbles: true, cancelable: true
                        }));
                        await settle();
                        positions.push({caret: window.__mdEditor.getLinkSelection(false).from,
                            rendered: !!document.querySelector('.math-display')});
                    }
                    traces.push(positions);
                }
                return JSON.stringify(traces);
                """, arguments: ["source": source], in: nil, contentWorld: .page)
            let json = try XCTUnwrap(result as? String)
            let traces = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[[String: Any]]])
            for trace in traces {
                XCTAssertTrue(trace.contains { step in
                    guard let caret = step["caret"] as? Int else { return false }
                    return (8...(8 + formula.utf16.count)).contains(caret) && step["rendered"] as? Bool == false
                }, "Skipped \(formula): \(json)")
            }
        }
    }

    func testArrowUpEntersPreviousMathAtItsClosingDelimiter() async throws {
        let source = "$$\na\n$$\n\n$$\nb"
        let html = EditorHTML.render(markdown: source,
            editorJavaScript: try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js"))
        let editor = WebViewLayoutHarness(html: html, width: 900, isEditor: true,
            schemeHandlers: ["md-asset": EditorMathAssets()])
        defer { editor.close() }
        _ = try await editor.layout(texts: [], imageCount: 0, selectors: [".katex": 1])
        let result = try await editor.webView.callAsyncJavaScript("""
            const settle = async () => {
                for (let i = 0; i < 3; i++) {
                    window.__layoutTestFrame();
                    await new Promise(resolve => setTimeout(resolve, 10));
                }
            };
            window.__mdEditor.focus();
            window.__mdEditor.select(source.length);
            await settle();
            const lines = [];
            for (let i = 0; i < 3; i++) {
                document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'ArrowUp', code: 'ArrowUp', bubbles: true, cancelable: true
                }));
                await settle();
                const selection = window.getSelection();
                lines.push(window.__mdEditor.getLinkSelection(false).from);
            }
            window.__mdEditor.exec('bold');
            return { markdown: window.__mdEditor.getMarkdown(), lines };
            """, arguments: ["source": source], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        let markdown = try XCTUnwrap(values["markdown"] as? String)
        let inserted = try XCTUnwrap(markdown.range(of: "****"))
        let offset = markdown.distance(from: markdown.startIndex, to: inserted.lowerBound)
        XCTAssertEqual(values["lines"] as? [Int], [10, 8, 7])
        XCTAssertTrue((5...7).contains(offset), "Caret landed at \(offset), lines: \(values["lines"] ?? "missing")")
    }

    func testParagraphAndHeadingAlignment() async throws {
        try await check(Fixture(name: "paragraphs-headings", markdown: """
            # First heading

            First paragraph.

            ## Second heading

            Second paragraph.

            Setext heading
            --------------

            Final paragraph.
            """, texts: ["First heading", "First paragraph.", "Second heading", "Second paragraph.",
                           "Setext heading", "Final paragraph."]))
    }

    func testImageAlignmentAndSpacingBeforeAndAfterImages() async throws {
        try await check(Fixture(name: "images", markdown: """
            Before first image.

            ![First](\(image))

            After first image.

            ![Second](\(image))

            After second image.

            Final paragraph.
            """, texts: ["Before first image.", "After first image.", "After second image.", "Final paragraph."],
            imageCount: 2))
    }

    func testLinkedImageAlignment() async throws {
        try await check(Fixture(name: "linked-image", markdown: """
            Before linked image.

            [![Linked](\(image))](https://example.com)

            After linked image.
            """, texts: ["Before linked image.", "After linked image."], imageCount: 1))
    }

    func testWrappedParagraphAlignment() async throws {
        let paragraph = "This paragraph is deliberately long enough to wrap across several lines in a narrow window, so the test checks line breaks and the alignment of every rendered line."
        try await check(Fixture(name: "wrapping", markdown: "\(paragraph)\n\nFollowing paragraph.",
                               texts: [paragraph, "Following paragraph."]))
    }

    func testWrappedInlineCodeKeepsPaddingOnEveryLine() async throws {
        let code = String(repeating: "asdadd-asd-", count: 24)
        try await check(Fixture(
            name: "wrapped-inline-code-padding",
            markdown: "Before code.\n\n`\(code)`\n\nAfter code.",
            texts: ["Before code.", code, "After code."]))
    }

    func testQuotePaddingAcrossWrappedAndHardBreakLines() async throws {
        try await check(Fixture(name: "quote-edges", markdown: """
            Before quotation.

            > This quoted paragraph is long enough to wrap in the narrow viewport and must receive padding only at the start and end of the block.\("  ")
            > Second quoted line.
            ## Following heading

            After quotation.
            """, texts: ["Before quotation.", "This quoted paragraph is long enough to wrap in the narrow viewport and must receive padding only at the start and end of the block.",
                           "Second quoted line.", "Following heading", "After quotation."]))
    }

    func testOversizedImageResizesWithTheContentColumn() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"300\"><rect width=\"1200\" height=\"300\" fill=\"royalblue\"/></svg>"
        let source = "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
        try await check(Fixture(name: "oversized-image", markdown: "Before large image.\n\n![Large](\(source))\n\nAfter large image.",
                               texts: ["Before large image.", "After large image."], imageCount: 1))
    }

    func testListAndQuoteAlignment() async throws {
        try await check(Fixture(name: "lists-quotes", markdown: """
            Intro paragraph.

            - First bullet
            - Second bullet

            1. First ordered item
            2. Second ordered item

            > Quoted paragraph.

            Closing paragraph.
            """, texts: ["Intro paragraph.", "First bullet", "Second bullet", "First ordered item",
                           "Second ordered item", "Quoted paragraph.", "Closing paragraph."]))
    }

    /// A list past 99 items widens its gutter by one digit (#522); both
    /// surfaces must agree on the new text column, the wrapped continuation
    /// lines, and the nested lists' indentation.
    func testLongOrderedListMarkerGutter() async throws {
        var lines = ["Before the list."]
        for index in 1...98 { lines.append("\(index). Entry number \(index)") }
        lines.append("99. Ninety-ninth entry wraps onto a second line because this sentence is deliberately long enough to need it at every width.")
        lines.append("100. Hundredth entry")
        // "100. " is five columns wide, so nested content needs five spaces.
        lines.append("     - Bullet under the hundredth")
        lines.append("     1. First nested")
        lines.append("     2. Second nested")
        lines.append("101. Final entry")
        // A paragraph separates the second list; otherwise "998." would
        // continue the first one and be numbered 102 by the preview.
        lines += ["", "Between the lists.", "", "998. Nine hundred", "999. Nine hundred and one",
                  "1000. One thousand", "", "After the list."]
        try await check(Fixture(name: "long-ordered-list", markdown: lines.joined(separator: "\n"),
                                texts: ["Before the list.", "Entry number 1", "Entry number 98", "Ninety-ninth entry",
                                        "deliberately long enough", "Hundredth entry", "Bullet under the hundredth",
                                        "First nested", "Second nested", "Final entry", "Between the lists.",
                                        "Nine hundred and one", "One thousand", "After the list."],
                                height: 3600))
    }

    func testQuoteAtDocumentStart() async throws {
        try await check(Fixture(name: "leading-quote", markdown: "> Opening quotation.\n> Continuing the same paragraph.\n\nAfter quotation.",
                               texts: ["Opening quotation.", "Continuing the same paragraph.", "After quotation."]))
    }

    func testAlignmentAfterReplacingMarkdownAndResizing() async throws {
        let initial = Fixture(name: "initial", markdown: "Original paragraph.", texts: ["Original paragraph."])
        let updated = Fixture(name: "updated-and-resized", markdown: """
            # Updated heading

            Before inserted image.

            ![Inserted](\(image))

            After inserted image.
            """, texts: ["Updated heading", "Before inserted image.", "After inserted image."], imageCount: 1)
        try await check(updated, updatingFrom: initial)
    }

    func check(_ fixture: Fixture, updatingFrom initial: Fixture? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let editorScript = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        TestVendor.installHighlighterGrammar()
        let mermaid = fixture.markdown.contains("```mermaid")
            ? try TestVendor.script("md-preview/Vendor/Pele/pele.global.js") : nil
        let zoom = try XCTUnwrap(Double(ProcessInfo.processInfo.environment["MDP_LAYOUT_ZOOM"] ?? "1"))
        guard zoom > 0 else { throw WebViewLayoutHarness.Failure("Page zoom must be positive") }
        for (width, fullWidth, pageScrolling) in [
            (CGFloat(500), false, false), (900, false, true),
            (1280, false, true), (1280, true, true)
        ] {
            let name = "\(fixture.name)-\(Int(width))-\(fullWidth ? "full" : "normal")-zoom\(zoom)"
            let readerHTML = MarkdownHTML.render(
                markdown: fixture.markdown, allowsScroll: true,
                contentWidth: fullWidth ? .full : .centered,
                documentFont: .system, readerLayout: ReaderLayoutSetting(),
                pageTopClearance: pageScrolling ? MarkdownHTML.appPageTopClearance : 0
            ).html
            let editorHTML = EditorHTML.render(
                markdown: (initial ?? fixture).markdown, editorJavaScript: editorScript,
                mermaidJavaScript: mermaid,
                configuration: .init(fullWidth: fullWidth, usesPageScrolling: pageScrolling)
            )
            // Both app surfaces have native hosts, including their table controls.
            let host = HostBridge()
            let reader = WebViewLayoutHarness(html: readerHTML, width: width, isEditor: false, zoom: zoom, height: fixture.height, messageHandler: host)
            let editor = WebViewLayoutHarness(html: editorHTML, width: initial == nil ? width : 1100,
                                              isEditor: true, zoom: zoom, height: fixture.height, messageHandler: host,
                                              schemeHandlers: ["md-asset": EditorMathAssets()])
            defer { reader.close(); editor.close() }
            var readLayout: WebViewLayoutHarness.Layout?
            var editLayout: WebViewLayoutHarness.Layout?
            do {
                if let initial {
                    _ = try await editor.layout(texts: initial.texts, imageCount: initial.imageCount)
                    editor.webView.setFrameSize(CGSize(width: width, height: 1800))
                    _ = try await editor.webView.callAsyncJavaScript(
                        "window.__mdEditor.replaceMarkdown(markdown)",
                        arguments: ["markdown": fixture.markdown], in: nil, contentWorld: .page
                    )
                }
                readLayout = try await reader.layout(texts: fixture.texts, imageCount: fixture.imageCount,
                                                     selectors: fixture.readSelectors, boxes: fixture.readBoxes, styles: fixture.styles)
                editLayout = try await editor.layout(texts: fixture.texts,
                                                     imageCount: fixture.editorImageCount ?? fixture.imageCount,
                                                     selectors: fixture.editorSelectors, boxes: fixture.editorBoxes, styles: fixture.styles,
                                                     sourceSnippets: fixture.editorSourceSnippets)
                let source = try await editor.webView.evaluateJavaScript("window.__mdEditor.getMarkdown()")
                guard source as? String == fixture.markdown else {
                    throw WebViewLayoutHarness.Failure("Rendering changed the Markdown source")
                }
                let read = try XCTUnwrap(readLayout)
                let edit = try XCTUnwrap(editLayout)
                var differences: [String] = []
                func compare(_ label: String, _ lhs: Double, _ rhs: Double) {
                    if abs(lhs - rhs) > 1 { differences.append("\(label): read=\(lhs), editor=\(rhs)") }
                }
                func compareRect(_ label: String, _ lhs: WebViewLayoutHarness.Rect, _ rhs: WebViewLayoutHarness.Rect,
                                 editorHeaders: Int = 0) {
                    compare("\(label).x", lhs.x, rhs.x)
                    // Both modes reserve the same language-header height.
                    compare("\(label).y", lhs.y, rhs.y)
                    compare("\(label).width", lhs.width, rhs.width)
                    compare("\(label).height", lhs.height, rhs.height)
                }
                compare("column x", read.columnX, edit.columnX)
                compare("column y", read.columnY, edit.columnY)
                compare("column width", read.columnWidth, edit.columnWidth)
                if fixture.sourceRepresentationReason != nil {
                    // Source-only features have intentionally different block
                    // heights. Shared paragraphs must still wrap and align;
                    // compare their lines relative to each paragraph's top.
                    for name in fixture.localParityTexts {
                        let lhs = try XCTUnwrap(read.elements.first { $0.name == name })
                        let rhs = try XCTUnwrap(edit.elements.first { $0.name == name })
                        compare("\(name).x", lhs.rect.x, rhs.rect.x)
                        compare("\(name).width", lhs.rect.width, rhs.rect.width)
                        compare("\(name).height", lhs.rect.height, rhs.rect.height)
                        if lhs.lines.count != rhs.lines.count {
                            differences.append("\(name): different wrapped line count")
                        }
                        for (index, pair) in zip(lhs.lines, rhs.lines).enumerated() {
                            let label = "\(name) line \(index)"
                            compare("\(label).x", pair.0.x, pair.1.x)
                            compare("\(label).y within block", pair.0.y - lhs.rect.y, pair.1.y - rhs.rect.y)
                            compare("\(label).width", pair.0.width, pair.1.width)
                            compare("\(label).height", pair.0.height, pair.1.height)
                        }
                    }
                    if !differences.isEmpty { throw WebViewLayoutHarness.Failure(differences.joined(separator: "\n")) }
                    continue
                }
                if read.elements.map(\.name) != edit.elements.map(\.name) {
                    differences.append("Different rendered elements or order")
                }
                for (lhs, rhs) in zip(read.elements, edit.elements) {
                    compareRect(lhs.name, lhs.rect, rhs.rect, editorHeaders: rhs.editorHeadersAbove)
                    if lhs.lines.count != rhs.lines.count {
                        differences.append("\(lhs.name): different wrapped line count")
                    }
                    for (index, pair) in zip(lhs.lines, rhs.lines).enumerated() {
                        compareRect("\(lhs.name) line \(index)", pair.0, pair.1, editorHeaders: rhs.editorHeadersAbove)
                    }
                }
                if !differences.isEmpty { throw WebViewLayoutHarness.Failure(differences.joined(separator: "\n")) }
            } catch {
                let directory = await reader.saveDiagnostics(name: name, layout: readLayout)
                _ = await editor.saveDiagnostics(name: name, layout: editLayout)
                XCTFail("\(name): \(error)\nDiagnostics: \(directory.path)", file: file, line: line)
            }
        }
    }
}
