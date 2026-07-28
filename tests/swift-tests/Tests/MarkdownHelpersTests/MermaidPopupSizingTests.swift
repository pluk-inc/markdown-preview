import XCTest
@testable import MarkdownHelpers

final class MermaidPopupSizingTests: XCTestCase {
    func testFitsLargeDiagramIntoScreen() {
        let size = MermaidPopupSizing.preferredContentSize(
            natural: CGSize(width: 2400, height: 1600),
            display: CGSize(width: 600, height: 400),
            screen: CGSize(width: 1440, height: 900)
        )
        XCTAssertLessThanOrEqual(size.width, 1440 * MermaidPopupSizing.screenFraction + 0.5)
        XCTAssertLessThanOrEqual(size.height, 900 * MermaidPopupSizing.screenFraction + 0.5)
        // Aspect roughly preserved (2400/1600 = 1.5).
        XCTAssertEqual(size.width / size.height, 1.5, accuracy: 0.08)
    }

    func testPrefersNaturalSizeOverCappedDisplay() {
        // Document capped a tall diagram; popup should open closer to natural.
        let size = MermaidPopupSizing.preferredContentSize(
            natural: CGSize(width: 400, height: 1200),
            display: CGSize(width: 400, height: 500),
            screen: CGSize(width: 1600, height: 1200)
        )
        XCTAssertGreaterThan(size.height, 500)
        XCTAssertLessThanOrEqual(size.height, 1200 * MermaidPopupSizing.screenFraction + 0.5)
    }

    func testCappedDisplayDoesNotOverrideNaturalAspectRatio() {
        // A tall figure remains full-width after CSS caps its height, so its
        // displayed box can be much wider than the SVG's natural aspect.
        let size = MermaidPopupSizing.preferredContentSize(
            natural: CGSize(width: 400, height: 1200),
            display: CGSize(width: 800, height: 720),
            screen: CGSize(width: 1600, height: 1200)
        )
        XCTAssertLessThan(size.width, 500)
        XCTAssertEqual(size.width / size.height, 1.0 / 3.0, accuracy: 0.03)
    }

    func testUpscalesTinyDiagramsToReadableMinimum() {
        let size = MermaidPopupSizing.preferredContentSize(
            natural: CGSize(width: 120, height: 80),
            display: CGSize(width: 120, height: 80),
            screen: CGSize(width: 1600, height: 1000)
        )
        XCTAssertGreaterThanOrEqual(size.width, MermaidPopupSizing.minimumWidth - 1)
        XCTAssertGreaterThanOrEqual(size.height, 100)
    }

    func testFallsBackToDisplayWhenNaturalMissing() {
        let size = MermaidPopupSizing.preferredContentSize(
            natural: .zero,
            display: CGSize(width: 500, height: 300),
            screen: CGSize(width: 1600, height: 1000)
        )
        XCTAssertGreaterThanOrEqual(size.width, 500)
        XCTAssertGreaterThanOrEqual(size.height, 300)
    }

    func testCanPresentRejectsEmptySVG() {
        XCTAssertFalse(MermaidPopupSizing.canPresent(svgHTML: ""))
        XCTAssertTrue(MermaidPopupSizing.canPresent(svgHTML: "<svg></svg>"))
    }

    func testSanitizedSVGHTMLNeutralizesScriptTags() {
        let raw = #"<svg><script>alert(1)</script><SCRIPT src="x"></SCRIPT></svg>"#
        let safe = MermaidPopupSizing.sanitizedSVGHTML(raw)
        XCTAssertFalse(safe.lowercased().contains("<script"))
        XCTAssertTrue(safe.contains("&lt;script"))
        XCTAssertTrue(safe.contains("&lt;/script"))
        // Non-script markup is left intact.
        XCTAssertTrue(safe.hasPrefix("<svg>"))
        XCTAssertTrue(safe.hasSuffix("</svg>"))
    }

    /// sanitizedSVGHTML is defense-in-depth only, not the primary guard: it
    /// neutralizes `<script>` but deliberately leaves `on*` handlers alone.
    /// The popup document's CSP (`default-src 'none'`) is what actually
    /// blocks any script execution, inline or event-handler-based.
    func testSanitizedSVGHTMLDoesNotStripEventHandlerAttributes() {
        let raw = #"<svg onload="alert(1)"><rect onclick="alert(2)"/></svg>"#
        let safe = MermaidPopupSizing.sanitizedSVGHTML(raw)
        XCTAssertTrue(safe.contains(#"onload="alert(1)""#))
        XCTAssertTrue(safe.contains(#"onclick="alert(2)""#))
    }
}
