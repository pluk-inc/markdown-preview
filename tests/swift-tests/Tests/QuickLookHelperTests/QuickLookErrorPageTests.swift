import XCTest
@testable import QuickLookHelpers

final class QuickLookErrorPageTests: XCTestCase {

    // MARK: - Markdown escaping

    func testEscapingNeutralizesMarkdownAndHTMLSyntax() {
        let hostile = "*_`<script>alert(\"&\")</script> [link](x) #{}end"
        let escaped = QuickLookErrorPage.escaped(hostile)
        XCTAssertEqual(
            escaped,
            "\\*\\_\\`\\<script\\>alert\\(\\\"\\&\\\"\\)\\<\\/script\\> \\[link\\]\\(x\\) \\#\\{\\}end"
        )
        // …so no raw HTML or emphasis markup survives.
        XCTAssertFalse(escaped.contains("<script>"))
        XCTAssertFalse(escaped.contains("[link]"))
    }

    func testEscapingLeavesPlainWordsAlone() {
        XCTAssertEqual(QuickLookErrorPage.escaped("notes 2026 v1 final"), "notes 2026 v1 final")
    }

    // MARK: - Page content

    private let readError = CocoaError(.fileReadNoPermission)

    func testPageIncludesFileNameErrorAndDomain() {
        let url = URL(fileURLWithPath: "/Users/ada/Documents/notes *draft*.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertTrue(markdown.contains("notes \\*draft\\*\\.md"))
        XCTAssertTrue(markdown.contains(QuickLookErrorPage.escaped(readError.localizedDescription)))
        XCTAssertTrue(markdown.contains("NSCocoaErrorDomain"))
        XCTAssertTrue(markdown.contains("\(readError.errorCode)"))
        XCTAssertTrue(markdown.contains(QuickLookErrorPage.escaped("/Users/ada/Documents")))
    }

    func testContainerPathGetsContainerHint() {
        let url = URL(fileURLWithPath:
            "/Users/ada/Library/Containers/com.tencent.xinWeChat/Data/Documents/files/report.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertTrue(markdown.contains("sandbox container"))
    }

    func testRegularPathGetsGenericHintOnly() {
        let url = URL(fileURLWithPath: "/Users/ada/Documents/report.md")
        let markdown = QuickLookErrorPage.makeMarkdown(for: readError, fileURL: url)
        XCTAssertFalse(markdown.contains("sandbox container"))
        XCTAssertTrue(markdown.contains("Double-click"))
    }
}
