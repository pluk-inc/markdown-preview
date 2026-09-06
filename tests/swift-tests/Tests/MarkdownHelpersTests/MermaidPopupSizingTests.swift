import XCTest
@testable import MarkdownHelpers

final class MermaidPopupSizingTests: XCTestCase {
    func testInitialSizePreservesWidescreenAspectRatio() {
        let screen = CGSize(width: 1440, height: 900)
        let size = MermaidPopupSizing.preferredContentSize(screen: screen)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(size.width, screen.width * MermaidPopupSizing.screenFraction + 1)
        XCTAssertLessThanOrEqual(size.height, screen.height * MermaidPopupSizing.screenFraction + 1)
    }

    func testInitialSizeFitsSmallScreenWithoutUsingDiagramAspectRatio() {
        let size = MermaidPopupSizing.preferredContentSize(
            screen: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(size.width, 720, accuracy: 0.5)
        XCTAssertEqual(size.height, 405, accuracy: 0.5)
    }

    func testSmallScreenTakesPrecedenceOverMinimumSize() {
        let size = MermaidPopupSizing.preferredContentSize(screen: CGSize(width: 640, height: 480))
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(size.width, 576)
        XCTAssertLessThanOrEqual(size.height, 432)
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
        XCTAssertTrue(safe.hasPrefix("<svg>"))
        XCTAssertTrue(safe.hasSuffix("</svg>"))
    }

    /// The popup CSP permits only its nonce-authorized interaction script.
    func testSanitizedSVGHTMLDoesNotStripEventHandlerAttributes() {
        let raw = #"<svg onload="alert(1)"><rect onclick="alert(2)"/></svg>"#
        let safe = MermaidPopupSizing.sanitizedSVGHTML(raw)
        XCTAssertTrue(safe.contains(#"onload="alert(1)"#))
        XCTAssertTrue(safe.contains(#"onclick="alert(2)"#))
    }
}
