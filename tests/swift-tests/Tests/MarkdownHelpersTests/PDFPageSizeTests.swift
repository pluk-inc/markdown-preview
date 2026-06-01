import XCTest

@testable import MarkdownHelpers

final class PDFPageSizeTests: XCTestCase {

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
    }

    func testNilRegionFallsBackToA4() {
        XCTAssertEqual(PaperSize.forRegion(nil), .a4)
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
}
