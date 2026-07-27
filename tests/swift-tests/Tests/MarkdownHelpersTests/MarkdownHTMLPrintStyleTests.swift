import XCTest
@testable import MarkdownHelpers

/// The print stylesheet ships inside the rendered page, and the app overrides
/// only the body size at print time. These guard the parts the export path
/// depends on: that a print block exists, that it is sized in `pt` (which
/// reaches paper 1:1), and that the paper palette can't inherit dark mode.
final class MarkdownHTMLPrintStyleTests: XCTestCase {
    private func printBlock() throws -> String {
        let html = MarkdownHTML.render(markdown: "text", vendorLoading: .lazy).html
        let marker = "@media print {"
        let start = try XCTUnwrap(html.range(of: marker), "no @media print block")
        // Walk to the matching close brace so assertions can't accidentally
        // match screen rules further down the sheet.
        var depth = 0
        var end = start.lowerBound
        for index in html.indices[start.lowerBound...] {
            if html[index] == "{" { depth += 1 }
            if html[index] == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
        }
        return String(html[start.lowerBound...end])
    }

    func testPrintBodyIsSizedInPointsAtTheDefault() throws {
        let block = try printBlock()
        XCTAssertTrue(
            block.contains("font-size: \(MarkdownHTML.defaultPrintPointSize)pt"),
            "print body must be sized in pt so CSS maps 1:1 to paper points"
        )
    }

    func testPrintForcesTheLightPaletteRegardlessOfSystemAppearance() throws {
        let block = try printBlock()
        XCTAssertTrue(block.contains("color-scheme: light"))
        XCTAssertTrue(block.contains("--text: #1d1d1f"),
                      "dark mode must not carry into paper")
        XCTAssertTrue(block.contains("background: #fff"))
    }

    func testPrintAvoidsBreakingBlocksAcrossPages() throws {
        let block = try printBlock()
        XCTAssertTrue(block.contains("break-inside: avoid"))
        XCTAssertTrue(block.contains("break-after: avoid"))
    }

    func testPrintDropsScreenOnlyAffordances() throws {
        let block = try printBlock()
        XCTAssertTrue(block.contains(".md-code-copy"))
        XCTAssertTrue(block.contains("display: none !important"))
    }

    /// Media queries add no specificity, so the print body size only wins by
    /// coming later in the sheet than the screen `body { font-size: 15px }`.
    /// Moving the print block above it would silently restore the old size.
    func testPrintBlockFollowsTheScreenBodyRuleSoItWinsTheCascade() throws {
        let html = MarkdownHTML.render(markdown: "text", vendorLoading: .lazy).html
        let screenRule = try XCTUnwrap(
            html.range(of: "font-size: \(MarkdownHTML.bodyFontSize)px"))
        let printBlock = try XCTUnwrap(html.range(of: "@media print {"))
        XCTAssertLessThan(screenRule.lowerBound, printBlock.lowerBound)
    }

}
