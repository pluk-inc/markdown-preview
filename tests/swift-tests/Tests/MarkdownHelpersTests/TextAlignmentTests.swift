import XCTest
import WebKit
@testable import MarkdownHelpers

final class TextAlignmentTests: XCTestCase {
    func testPersistenceAndInvalidValueFallback() throws {
        let suite = "TextAlignmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TextAlignmentSetting.read(from: nil), .automatic)
        XCTAssertEqual(TextAlignmentSetting.read(from: defaults), .automatic)
        for setting in TextAlignmentSetting.allCases {
            TextAlignmentSetting.write(setting, to: defaults)
            XCTAssertEqual(TextAlignmentSetting.read(from: UserDefaults(suiteName: suite)), setting)
        }
        defaults.set("invalid", forKey: TextAlignmentSetting.defaultsKey)
        XCTAssertEqual(TextAlignmentSetting.read(from: defaults), .automatic)
        TextAlignmentSetting.write(.automatic, to: defaults)
        XCTAssertNil(defaults.object(forKey: TextAlignmentSetting.defaultsKey))
    }

    func testAlignmentDoesNotRewriteMarkdownOrBreakSemantics() {
        let source = "First\nsecond  \nthird\\\nfourth\n\n- Item\n\n```text\n  indented\n```"
        for strict in [false, true] {
            let original = MarkdownHTML.render(markdown: source, strictLineBreaks: strict,
                                               textAlignment: .automatic).articleHTML
            for setting in TextAlignmentSetting.allCases {
                XCTAssertEqual(MarkdownHTML.render(markdown: source, strictLineBreaks: strict,
                                                    textAlignment: setting).articleHTML, original)
            }
        }
    }

    @MainActor
    func testProseAlignmentAndProtectedContentInWebKit() async throws {
        let source = """
        # Heading

        Ordinary paragraph with enough words to wrap onto multiple lines in the narrow preview.

        > Quoted paragraph.

        - List item

          ```text
          nested code
          ```

        مرحبا بالعالم هذا نص عربي لاختبار اتجاه القراءة

        | Left | Center | Right |
        | :--- | :----: | ----: |
        | A | B | C |

        ```text
        first line
            indented line
        ```

        <div align="right"><p id="authored-attribute">Authored right alignment</p></div>

        <center><p id="authored-center">Legacy centered paragraph</p></center>

        <p align="center" id="authored-style">Authored centered alignment</p>
        """
        for setting in TextAlignmentSetting.allCases {
            // App and Quick Look use the same renderer with different scrolling modes.
            for scrolling in [false, true] {
                let web = WKWebView(frame: CGRect(x: 0, y: 0, width: scrolling ? 640 : 1000, height: 700))
                let html = scrolling
                    ? MarkdownHTML.makeHTML(from: source, allowsScroll: true, textAlignment: setting)
                    : MarkdownHTML.render(markdown: source, contentWidth: .full, textAlignment: setting).html
                web.loadHTMLString(html, baseURL: nil)
                try await waitUntilLoaded(web)
                let result = try await web.evaluateJavaScript("""
                    (() => {
                        const style = selector => getComputedStyle(document.querySelector(selector));
                        return {
                            paragraph: style('article > p').textAlign,
                            quote: style('blockquote p').textAlign,
                            list: style('li').textAlign,
                            heading: style('h1').textAlign,
                            rtl: style('p[dir="rtl"]').textAlign,
                            direction: style('p[dir="rtl"]').direction,
                            table: [...document.querySelectorAll('td')].map(e => getComputedStyle(e).textAlign),
                            code: [...document.querySelectorAll('pre')].map(e => getComputedStyle(e).textAlign),
                            codeLabels: [...document.querySelectorAll('.md-code-language')].map(e => getComputedStyle(e).textAlign),
                            attribute: style('#authored-attribute').textAlign,
                            legacyCenter: style('#authored-center').textAlign,
                            inlineStyle: style('#authored-style').textAlign
                        };
                    })()
                    """) as! [String: Any]
                if setting != .automatic {
                    let expected = setting == .justified ? "justify" : setting.rawValue
                    for key in ["paragraph", "quote", "list", "heading", "rtl"] {
                        XCTAssertEqual(result[key] as? String, expected, "\(setting) / \(scrolling) / \(key)")
                    }
                } else {
                    XCTAssertEqual(result["rtl"] as? String, "right")
                }
                XCTAssertEqual(result["direction"] as? String, "rtl")
                XCTAssertEqual(result["table"] as? [String], ["left", "center", "right"])
                let codeAlignments = try XCTUnwrap(result["code"] as? [String])
                XCTAssertEqual(codeAlignments.count, 2)
                XCTAssertTrue(codeAlignments.allSatisfy { ["start", "left"].contains($0) })
                let labels = try XCTUnwrap(result["codeLabels"] as? [String])
                XCTAssertEqual(labels.count, 2)
                XCTAssertTrue(labels.allSatisfy { ["start", "left"].contains($0) })
                XCTAssertTrue(["right", "-webkit-right"].contains(result["attribute"] as? String ?? ""))
                XCTAssertTrue(["center", "-webkit-center"].contains(result["legacyCenter"] as? String ?? ""))
                XCTAssertTrue(["center", "-webkit-center"].contains(result["inlineStyle"] as? String ?? ""))
                web.stopLoading()
            }
        }
    }

    @MainActor
    func testJustificationFillsLinesButNotLastLineAtBothWidths() async throws {
        let source = Array(repeating: "A paragraph with varied words makes alignment measurable in the rendered preview.", count: 9).joined(separator: " ")
        for width in [420.0, 1000.0] {
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            web.loadHTMLString(MarkdownHTML.render(markdown: source, allowsScroll: true,
                textAlignment: .justified).html, baseURL: nil)
            try await waitUntilLoaded(web)
            let result = try await web.evaluateJavaScript("""
                (() => {
                    const p = document.querySelector('article p');
                    const range = document.createRange(); range.selectNodeContents(p);
                    const lines = [...range.getClientRects()].filter(r => r.width > 0);
                    const box = p.getBoundingClientRect();
                    return {count: lines.length, first: lines[0].width, last: lines.at(-1).width, width: box.width};
                })()
                """) as! [String: NSNumber]
            XCTAssertGreaterThan(result["count"]!.intValue, 2)
            XCTAssertEqual(result["first"]!.doubleValue, result["width"]!.doubleValue, accuracy: 2)
            XCTAssertLessThan(result["last"]!.doubleValue, result["width"]!.doubleValue - 5)
        }
    }

    @MainActor
    private func waitUntilLoaded(_ web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while web.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(web.isLoading)
    }
}
