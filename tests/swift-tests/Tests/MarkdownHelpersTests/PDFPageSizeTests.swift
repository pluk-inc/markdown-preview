import XCTest

@testable import MarkdownHelpers

final class PDFPageSizeTests: XCTestCase {

    /// Mirrors `PaperSize.letterRegions` in md-preview/PaperSize.swift.
    private static let letterRegions = [
        "US", "CA", "MX", "CL", "CO", "CR", "GT", "DO",
        "PH", "SV", "NI", "PA", "VE", "PR"
    ]

    func testAllLetterRegionsSelectUSLetter() {
        for code in Self.letterRegions {
            XCTAssertEqual(
                PaperSize.forRegion(code),
                .usLetter,
                "Expected US Letter for region \(code)"
            )
        }
    }

    func testAllLetterRegionsAreCaseInsensitive() {
        for code in Self.letterRegions {
            XCTAssertEqual(
                PaperSize.forRegion(code.lowercased()),
                .usLetter,
                "Expected US Letter for lowercased region \(code.lowercased())"
            )
        }
    }

    func testUSRegionsSelectLetter() {
        XCTAssertEqual(PaperSize.forRegion("US"), .usLetter)
        XCTAssertEqual(PaperSize.forRegion("CA"), .usLetter)
        XCTAssertEqual(PaperSize.forRegion("MX"), .usLetter)
    }

    func testRegionCodeIsCaseInsensitive() {
        XCTAssertEqual(PaperSize.forRegion("us"), .usLetter)
    }

    func testInternationalRegionsSelectA4() {
        XCTAssertEqual(PaperSize.forRegion("GB"), .a4)
        XCTAssertEqual(PaperSize.forRegion("DE"), .a4)
        XCTAssertEqual(PaperSize.forRegion("JP"), .a4)
        XCTAssertEqual(PaperSize.forRegion("AU"), .a4)
        XCTAssertEqual(PaperSize.forRegion("FR"), .a4)
        XCTAssertEqual(PaperSize.forRegion("IN"), .a4)
    }

    func testNilRegionFallsBackToA4() {
        XCTAssertEqual(PaperSize.forRegion(nil), .a4)
    }

    func testEmptyStringRegionFallsBackToA4() {
        XCTAssertEqual(PaperSize.forRegion(""), .a4)
    }

    func testUnknownRegionFallsBackToA4() {
        XCTAssertEqual(PaperSize.forRegion("ZZ"), .a4)
    }

    func testPointSizesArePortrait() {
        XCTAssertEqual(PaperSize.usLetter.pointSize.width, 612, accuracy: 0.01)
        XCTAssertEqual(PaperSize.usLetter.pointSize.height, 792, accuracy: 0.01)
        XCTAssertEqual(PaperSize.a4.pointSize.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(PaperSize.a4.pointSize.height, 841.89, accuracy: 0.01)
    }

    func testPointSizesArePortraitOrientation() {
        for size in [PaperSize.usLetter, PaperSize.a4] {
            let points = size.pointSize
            XCTAssertLessThan(
                points.width,
                points.height,
                "Expected portrait orientation (width < height) for \(size)"
            )
        }
    }
}
