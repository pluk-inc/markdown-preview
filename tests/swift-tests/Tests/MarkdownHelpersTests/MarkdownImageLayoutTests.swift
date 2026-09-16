import WebKit
import XCTest
@testable import MarkdownHelpers

final class MarkdownImageLayoutTests: XCTestCase {
    @MainActor
    func testReadModeImagesFollowTextAlignmentWithBothVendorLoadingStrategies() async throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="40">
        <rect width="120" height="40" fill="royalblue"/>
        </svg>
        """
        let source = "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
        let markdown = """
        First paragraph.

        Paragraph before the image.

        ![plain](\(source))

        Paragraph after the image.

        [![linked](\(source))](https://example.com)

        <img alt="raw" src="\(source)">

        <p align="center"><img alt="center" src="\(source)"></p>

        <p align="right"><img alt="right" src="\(source)"></p>

        <div align="center"><img alt="nested" src="\(source)"></div>

        <p dir="rtl"><img alt="rtl" src="\(source)"></p>

        <p>Before <img alt="inline" src="\(source)"> after</p>
        """
        for mode: MarkdownHTML.VendorLoading in [.inline, .lazy] {
            let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: mode)
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
            webView.loadHTMLString(rendered.html, baseURL: nil)
            let deadline = Date().addingTimeInterval(10)
            var ready = false
            while Date() < deadline {
                if !webView.isLoading {
                    ready = (try await webView.evaluateJavaScript("""
                        (() => {
                            const images = [...document.querySelectorAll('article img')];
                            return images.length === 8 && images.every(img => img.complete && img.naturalWidth > 0);
                        })()
                        """)) as? Bool == true
                    if ready { break }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(ready, "Image fixtures did not load")
            guard ready else { continue }

            let spacing = try await webView.evaluateJavaScript("""
                (() => {
                    const paragraphs = document.querySelectorAll('article > p');
                    const first = paragraphs[0].getBoundingClientRect();
                    const before = paragraphs[1].getBoundingClientRect();
                    const image = paragraphs[2].querySelector('img').getBoundingClientRect();
                    const after = paragraphs[3].getBoundingClientRect();
                    return {
                        paragraph: before.top - first.bottom,
                        aboveImage: image.top - before.bottom,
                        belowImage: after.top - image.bottom
                    };
                })()
                """)
            let gaps = try XCTUnwrap(spacing as? [String: Double])
            let paragraphGap = try XCTUnwrap(gaps["paragraph"])
            for side in ["aboveImage", "belowImage"] {
                XCTAssertLessThanOrEqual(try XCTUnwrap(gaps[side]), paragraphGap + 4,
                                         "Image spacing should match paragraphs, allowing for inline leading")
            }

            let result = try await webView.evaluateJavaScript("""
                [...document.querySelectorAll('article img')].map((img, index) => {
                    const container = img.closest('p, div') || img.closest('article');
                    const box = img.getBoundingClientRect();
                    const parent = container.getBoundingClientRect();
                    const style = getComputedStyle(container);
                    const left = parent.left + parseFloat(style.paddingLeft);
                    const right = parent.right - parseFloat(style.paddingRight);
                    const textRange = document.createRange();
                    textRange.selectNodeContents(container.firstChild);
                    const textBox = textRange.getBoundingClientRect();
                    return {
                        name: ['plain', 'linked', 'raw', 'center', 'right', 'nested', 'rtl', 'inline'][index],
                        left: box.left - left,
                        right: right - box.right,
                        center: (box.left + box.right - left - right) / 2,
                        inlineOverlap: Math.min(box.bottom, textBox.bottom) - Math.max(box.top, textBox.top)
                    };
                })
                """)
            let metrics = try XCTUnwrap(result as? [[String: Any]])
            for metric in metrics {
                let name = try XCTUnwrap(metric["name"] as? String)
                if name == "inline" {
                    XCTAssertGreaterThan(try XCTUnwrap(metric["inlineOverlap"] as? Double), 0,
                                         "The image should stay on the same line as the surrounding text")
                    continue
                }
                let edge = switch name {
                case "center", "nested": "center"
                case "right", "rtl": "right"
                default: "left"
                }
                XCTAssertEqual(try XCTUnwrap(metric[edge] as? Double), 0, accuracy: 1,
                               "\(name) image should follow its container's alignment")
            }
        }
    }
}
