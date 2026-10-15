import XCTest
import WebKit
@testable import MarkdownHelpers

/// Ordered-list markers of three or more digits must stay on one line beside
/// their item in both surfaces (pluk-inc/markdown-preview#522): the preview
/// widens the list gutter and the editor widens the marker's hanging box.
@MainActor
final class OrderedListMarkerTests: XCTestCase {
    private final class HostBridge: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    static let markdown: String = {
        var lines = ["# Long list", ""]
        for index in 1...120 { lines.append("\(index). Item \(index)") }
        lines += ["", "## Short list", ""]
        for index in 1...99 { lines.append("\(index). Short \(index)") }
        lines += ["", "## Big start", "", "998. Big a", "999. Big b", "1000. Big c", "1001. Big d"]
        return lines.joined(separator: "\n")
    }()

    func testPreviewGutterGrowsByOneDigitWidthPerExtraDigit() async throws {
        for scrolling in [false, true] {
            let html = scrolling
                ? MarkdownHTML.makeHTML(from: Self.markdown, allowsScroll: true)
                : MarkdownHTML.render(markdown: Self.markdown, contentWidth: .full).html
            let harness = WebViewLayoutHarness(html: html, width: 700, isEditor: false, height: 900)
            defer { harness.close() }
            _ = try await harness.layout(texts: ["Item 100", "Short 99", "Big c"], imageCount: 0)
            let result = try await harness.webView.evaluateJavaScript("""
                (() => {
                    const lists = [...document.querySelectorAll('article ol')];
                    const probe = document.createElement('span');
                    probe.style.display = 'inline-block';
                    probe.style.width = '1ch';
                    lists[0].appendChild(probe);
                    const ch = probe.getBoundingClientRect().width;
                    probe.remove();
                    const em = parseFloat(getComputedStyle(lists[0]).fontSize);
                    const info = list => {
                        const items = [...list.querySelectorAll(':scope > li')];
                        return {
                            digits: list.getAttribute('data-mdp-digits'),
                            padding: parseFloat(getComputedStyle(list).paddingInlineStart),
                            itemHeights: [...new Set(items.map(li => li.getBoundingClientRect().height))],
                            lineHeight: parseFloat(getComputedStyle(items[0]).lineHeight)
                        };
                    };
                    return { ch, em, lists: lists.map(info) };
                })()
                """) as! [String: Any]
            let ch = try XCTUnwrap(result["ch"] as? Double)
            let em = try XCTUnwrap(result["em"] as? Double)
            let lists = try XCTUnwrap(result["lists"] as? [[String: Any]])
            XCTAssertEqual(lists.count, 3)
            let expected: [(digits: String?, extra: Double)] = [("3", 1), (nil, 0), ("4", 2)]
            for (list, expectation) in zip(lists, expected) {
                XCTAssertEqual(list["digits"] as? String, expectation.digits, "\(scrolling)")
                let padding = try XCTUnwrap(list["padding"] as? Double)
                XCTAssertEqual(padding, 2.1 * em + expectation.extra * ch, accuracy: 0.5, "\(scrolling)")
                // Every item stays a single line: the marker never wraps.
                let heights = try XCTUnwrap(list["itemHeights"] as? [Double])
                let lineHeight = try XCTUnwrap(list["lineHeight"] as? Double)
                XCTAssertEqual(heights.count, 1, "\(scrolling)")
                XCTAssertEqual(heights.first ?? 0, lineHeight, accuracy: 0.5, "\(scrolling)")
            }
        }
    }

    func testEditorMarkerBoxGrowsAndMarkersStayOnOneLine() async throws {
        let editorScript = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        TestVendor.installHighlighterGrammar()
        let html = EditorHTML.render(markdown: Self.markdown, editorJavaScript: editorScript,
                                     mermaidJavaScript: nil,
                                     configuration: .init(fullWidth: false, usesPageScrolling: true))
        let host = HostBridge()
        // Tall enough that CodeMirror materializes every line.
        let harness = WebViewLayoutHarness(html: html, width: 700, isEditor: true, height: 6500, messageHandler: host)
        defer { harness.close() }
        _ = try await harness.layout(texts: ["Item 100", "Short 99", "Big c"], imageCount: 0)
        let result = try await harness.webView.evaluateJavaScript("""
            (() => {
                const markers = [...document.querySelectorAll('.cm-md-ordered')];
                const byText = text => markers.find(marker => marker.textContent === text);
                const probe = document.createElement('span');
                probe.style.display = 'inline-block';
                probe.style.width = '1ch';
                const line = byText('100.').closest('.cm-line');
                line.appendChild(probe);
                const ch = probe.getBoundingClientRect().width;
                probe.remove();
                const em = parseFloat(getComputedStyle(line).fontSize);
                const info = marker => {
                    const rect = marker.getBoundingClientRect();
                    const line = marker.closest('.cm-line');
                    return {
                        width: rect.width, height: rect.height,
                        lineHeight: parseFloat(getComputedStyle(line).lineHeight),
                        // Item text follows the hanging box directly.
                        textX: rect.right
                    };
                };
                const short99 = markers.filter(marker => marker.textContent === '99.')[1];
                return { ch, em, item99: info(byText('99.')), item100: info(byText('100.')),
                         item120: info(byText('120.')), short99: info(short99), big1000: info(byText('1000.')) };
            })()
            """) as! [String: Any]
        let ch = try XCTUnwrap(result["ch"] as? Double)
        let em = try XCTUnwrap(result["em"] as? Double)
        func marker(_ key: String) throws -> [String: Any] { try XCTUnwrap(result[key] as? [String: Any]) }
        // The long list shares one box width, one digit wider than the default.
        for key in ["item99", "item100", "item120"] {
            let info = try marker(key)
            XCTAssertEqual(try XCTUnwrap(info["width"] as? Double), 2.1 * em + ch, accuracy: 0.5, key)
            XCTAssertEqual(try XCTUnwrap(info["height"] as? Double), try XCTUnwrap(info["lineHeight"] as? Double),
                           accuracy: 0.5, "\(key) marker wrapped onto a second line")
        }
        let short = try marker("short99")
        XCTAssertEqual(try XCTUnwrap(short["width"] as? Double), 2.1 * em, accuracy: 0.5)
        let big = try marker("big1000")
        XCTAssertEqual(try XCTUnwrap(big["width"] as? Double), 2.1 * em + 2 * ch, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(big["height"] as? Double), try XCTUnwrap(big["lineHeight"] as? Double), accuracy: 0.5)
        // Item text starts at the same column for every item of a list.
        XCTAssertEqual(try XCTUnwrap(try marker("item99")["textX"] as? Double),
                       try XCTUnwrap(try marker("item100")["textX"] as? Double), accuracy: 0.5)

        // The caret's own marker stays editable source in the same box: same
        // width, one line, and the item text does not shift on activation.
        let active = try await harness.webView.callAsyncJavaScript("""
            const markdown = window.__mdEditor.getMarkdown();
            const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
            // A command-line test has no key window, so the document never reports focus.
            document.hasFocus = () => true;
            const measure = async (needle) => {
                window.__mdEditor.select(markdown.indexOf(needle) + needle.length);
                // Source markers are revealed only while the editor has focus.
                window.__mdEditor.focus();
                for (let frame = 0; frame < 12; frame++) { window.__layoutTestFrame(); await delay(20); }
                const mark = needle.split(' ')[0];
                const source = [...document.querySelectorAll('.cm-md-ordered-source')].find(el => el.textContent === mark);
                if (!source) throw new Error('No editable marker for ' + needle);
                const rect = source.getBoundingClientRect();
                const line = source.closest('.cm-line');
                return { width: rect.width, height: rect.height,
                         lineHeight: parseFloat(getComputedStyle(line).lineHeight), textX: rect.right };
            };
            return { active100: await measure('100. Item 100'), active1000: await measure('1000. Big c') };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        func activeMarker(_ key: String) throws -> [String: Any] { try XCTUnwrap(try XCTUnwrap(active)[key] as? [String: Any]) }
        let active100 = try activeMarker("active100")
        XCTAssertEqual(try XCTUnwrap(active100["width"] as? Double), 2.1 * em + ch, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(active100["height"] as? Double), try XCTUnwrap(active100["lineHeight"] as? Double),
                       accuracy: 0.5, "editable 100. wrapped onto a second line")
        XCTAssertEqual(try XCTUnwrap(active100["textX"] as? Double),
                       try XCTUnwrap(try marker("item100")["textX"] as? Double), accuracy: 0.5, "item text shifted on activation")
        let active1000 = try activeMarker("active1000")
        XCTAssertEqual(try XCTUnwrap(active1000["width"] as? Double), 2.1 * em + 2 * ch, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(active1000["height"] as? Double), try XCTUnwrap(active1000["lineHeight"] as? Double),
                       accuracy: 0.5, "editable 1000. wrapped onto a second line")
        XCTAssertEqual(try XCTUnwrap(active1000["textX"] as? Double),
                       try XCTUnwrap(try marker("big1000")["textX"] as? Double), accuracy: 0.5, "item text shifted on activation")
    }
}
