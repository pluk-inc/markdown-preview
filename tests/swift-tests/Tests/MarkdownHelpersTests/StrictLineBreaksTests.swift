import XCTest
import WebKit
@testable import MarkdownHelpers

final class StrictLineBreaksTests: XCTestCase {
    private let sample = "# Title goes here\n\nThis is a test\nof the emergency broadcasting\nsystem.  I repeat: this is\nonly a test.\n"

    func testPreferenceDefaultsOffAndPersistsAcrossReaders() throws {
        let suite = "StrictLineBreaksTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(StrictLineBreaksSetting.read(from: nil))
        XCTAssertFalse(StrictLineBreaksSetting.read(from: defaults))
        StrictLineBreaksSetting.write(true, to: defaults)
        XCTAssertTrue(StrictLineBreaksSetting.read(from: UserDefaults(suiteName: suite)))
        StrictLineBreaksSetting.write(false, to: defaults)
        XCTAssertFalse(StrictLineBreaksSetting.read(from: defaults))
        XCTAssertNil(defaults.object(forKey: StrictLineBreaksSetting.defaultsKey))
    }

    func testExplicitBreaksAndParagraphsSurviveBothModes() {
        for strict in [false, true] {
            let html = EscapingHTMLFormatter.format(
                "First  \nSecond\\\nThird\n\nAnother paragraph.", strictLineBreaks: strict)
            XCTAssertEqual(html.components(separatedBy: "<br />").count - 1, 2)
            XCTAssertEqual(html.components(separatedBy: "<p ").count - 1, 2)
        }
    }

    func testSoftBreakPolicyReachesNestedBlocksAndFootnotes() {
        let markdown = "> Quote first\n> quote second\n\n- List first\n  list second\n\nNote[^1]\n\n[^1]: Footnote first\n    footnote second\n"
        for strict in [false, true] {
            let html = MarkdownHTML.render(markdown: markdown, strictLineBreaks: strict).articleHTML
            XCTAssertEqual(html.components(separatedBy: "<br />").count - 1, strict ? 0 : 3)
        }
    }

    func testCodeAndRawHTMLBreaksAreUnaffected() {
        let markdown = "```text\nfirst\nsecond\n```\n\nFirst<br>Second"
        XCTAssertEqual(
            MarkdownHTML.render(markdown: markdown, strictLineBreaks: false).articleHTML,
            MarkdownHTML.render(markdown: markdown, strictLineBreaks: true).articleHTML)
    }

    @MainActor
    func testIssue446FlowsOnlyInStrictModeAtBothWidths() async throws {
        for strict in [false, true] {
            for width in [640.0, 1200.0] {
                // The same entry point and scrolling configuration used by Quick Look.
                let html = MarkdownHTML.makeHTML(from: sample, allowsScroll: true,
                                                 strictLineBreaks: strict)
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 500))
                webView.loadHTMLString(html, baseURL: nil)
                let deadline = Date().addingTimeInterval(10)
                while webView.isLoading && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertFalse(webView.isLoading)
                let result = try await webView.evaluateJavaScript("""
                    (() => {
                        const p = document.querySelector('article p');
                        const tops = [...p.childNodes].filter(n => n.nodeType === 3 && n.textContent.trim()).flatMap(n => {
                            const range = document.createRange();
                            range.selectNodeContents(n);
                            return [...range.getClientRects()].filter(r => r.width > 0).map(r => Math.round(r.top));
                        });
                        return {breaks: p.querySelectorAll('br').length, lines: [...new Set(tops)].length};
                    })()
                    """) as! [String: Any]
                XCTAssertEqual(result["breaks"] as? Int, strict ? 0 : 3)
                let lines = try XCTUnwrap(result["lines"] as? Int)
                if strict {
                    XCTAssertLessThan(lines, 4, "Paragraph should flow at width \(width)")
                } else {
                    XCTAssertEqual(lines, 4)
                }
            }
        }
    }
}
