import XCTest
import WebKit
@testable import MarkdownHelpers
@testable import QuickLookHelpers

final class QuickLookErrorPageTests: XCTestCase {

    // MARK: - Markdown escaping

    func testEscapingNeutralizesMarkdownAndHTMLSyntax() {
        XCTAssertEqual(
            QuickLookErrorPage.escaped("(draft) [draft] $x$ <&>"),
            "&#40;draft&#41; &#91;draft&#93; &#36;x&#36; &#60;&#38;&#62;"
        )
    }

    func testEscapingLeavesPlainWordsAlone() {
        XCTAssertEqual(QuickLookErrorPage.escaped("notes 2026 v1 final"), "notes 2026 v1 final")
    }

    @MainActor
    func testErrorDetailsRemainLiteralThroughRenderingPipeline() async throws {
        let details = [
            "notes (draft).md", "notes [draft].md",
            #"notes \(draft\) \[draft\] $x$ $$y$$.md"#,
            #"*_`<script>alert("&")</script> [link](x) &#40; 中文"#,
        ]
        for detail in details {
            let url = URL(fileURLWithPath: "/tmp/" + detail.replacingOccurrences(of: "/", with: "_"))
            let error = NSError(domain: detail, code: 42,
                                userInfo: [NSLocalizedDescriptionKey: detail])
            let html = MarkdownHTML.makeHTML(
                from: QuickLookErrorPage.makeMarkdown(for: error, fileURL: url),
                vendorLoading: .inline
            )
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            webView.loadHTMLString(html, baseURL: nil)
            let deadline = Date().addingTimeInterval(10)
            while webView.isLoading && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(webView.isLoading)
            let name = try await webView.evaluateJavaScript(
                "document.querySelector('article p strong').textContent") as? String
            let rows = try await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('article li')).map(e => e.textContent.trimEnd())") as? [String]
            XCTAssertEqual(name, url.lastPathComponent)
            XCTAssertEqual(rows, ["Error: " + detail, "Domain: " + detail + " (42)", "Path: " + url.path])
            let activeMarkup = try await webView.evaluateJavaScript(
                "document.querySelectorAll('article .math, article .katex, article script, article a, article em, article code').length") as? Int
            XCTAssertEqual(activeMarkup, 0)
        }
    }

    // MARK: - Page content

    private let readError = CocoaError(.fileReadNoPermission)

    func testPageIncludesFileNameErrorAndDomain() {
        let url = URL(fileURLWithPath: "/Users/ada/Documents/notes *draft*.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertTrue(markdown.contains("notes &#42;draft&#42;&#46;md"))
        XCTAssertTrue(markdown.contains(QuickLookErrorPage.escaped(readError.localizedDescription)))
        XCTAssertTrue(markdown.contains("NSCocoaErrorDomain"))
        XCTAssertTrue(markdown.contains("\(readError.errorCode)"))
        XCTAssertTrue(markdown.contains(QuickLookErrorPage.escaped("/Users/ada/Documents")))
    }

    // The hint logic prefixes against the real user's containers root
    // (resolved via getpwuid, as in production), so build test paths from
    // the same home instead of a fabricated one.
    private var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    func testContainerPathGetsContainerHint() {
        let url = URL(fileURLWithPath:
            "\(realHome)/Library/Containers/com.tencent.xinWeChat/Data/Documents/files/report.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertTrue(markdown.contains("sandbox container"))
    }

    func testLookalikeContainerPathGetsGenericHintOnly() {
        // Contains "/Library/Containers/" as a substring but not under the
        // user's real home — must not get the container hint.
        let url = URL(fileURLWithPath: "/tmp/Library/Containers/report.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertFalse(markdown.contains("sandbox container"))
        XCTAssertTrue(markdown.contains("Double-click"))
    }

    func testOtherUsersContainerPathGetsGenericHintOnly() {
        // Under a different user's home — same substring, wrong prefix.
        let url = URL(fileURLWithPath: "/Users/someone-else/Library/Containers/app/report.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertFalse(markdown.contains("sandbox container"))
        XCTAssertTrue(markdown.contains("Double-click"))
    }

    func testRegularPathGetsGenericHintOnly() {
        let url = URL(fileURLWithPath: "\(realHome)/Documents/report.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertFalse(markdown.contains("sandbox container"))
        XCTAssertTrue(markdown.contains("Double-click"))
    }
}
