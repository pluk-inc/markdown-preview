import XCTest

@testable import MarkdownHelpers

final class MarkdownExportAssetsTests: XCTestCase {

    func testStylesheetHidesInteractiveChrome() {
        let css = MarkdownExportAssets.stylesheet
        XCTAssertTrue(css.contains(".md-code-copy"))
        XCTAssertTrue(css.contains(".mermaid-hud"))
        XCTAssertTrue(css.contains("md-search-highlight"))
    }

    func testStylesheetSetsPageAndColorAdjust() {
        let css = MarkdownExportAssets.stylesheet
        XCTAssertTrue(css.contains("@page"))
        XCTAssertTrue(css.contains("print-color-adjust: exact"))
        XCTAssertTrue(css.contains("break-inside: avoid"))
    }

    func testReadinessScriptReflectsExpectedRenderers() {
        let all = MarkdownExportAssets.readinessScript(
            containsMath: true, containsMermaid: true, containsCode: true)
        XCTAssertTrue(all.contains("expectMath = true"))
        XCTAssertTrue(all.contains("expectMermaid = true"))
        XCTAssertTrue(all.contains("expectCode = true"))
        XCTAssertTrue(all.contains("renderComplete"))

        let none = MarkdownExportAssets.readinessScript(
            containsMath: false, containsMermaid: false, containsCode: false)
        XCTAssertTrue(none.contains("expectMath = false"))
        XCTAssertTrue(none.contains("expectMermaid = false"))
        XCTAssertTrue(none.contains("expectCode = false"))
        XCTAssertTrue(none.contains("renderComplete"))
    }

    func testReadinessScriptChecksRendererDoneMarkers() {
        let all = MarkdownExportAssets.readinessScript(
            containsMath: true, containsMermaid: true, containsCode: true)
        XCTAssertTrue(all.contains("data-math-done"))
        XCTAssertTrue(all.contains("data-hljs-done"))
        XCTAssertTrue(all.contains("mmDone"))
    }

    func testHeadInjectionSetsEagerRenderFlagAndStyle() {
        let head = MarkdownExportAssets.headInjection(
            containsMath: false, containsMermaid: true, containsCode: false)
        XCTAssertTrue(head.contains("__mdPreviewRenderAll = true"))
        XCTAssertTrue(head.contains("<style>"))
        XCTAssertTrue(head.contains(".md-code-copy"))
        XCTAssertTrue(head.contains("renderComplete"))
    }
}
