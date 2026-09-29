import XCTest
@testable import MarkdownHelpers

final class FileSearchPanelPlacementTests: XCTestCase {
    func testSavedDragFollowsDocumentToAnotherDisplay() {
        let first = CGRect(x: 100, y: 100, width: 900, height: 700)
        let second = first.offsetBy(dx: -1920, dy: 400)
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let a = FileSearchPanelPlacement.frame(contentSize: CGSize(width: 480, height: 52),
            parentFrame: first, visibleFrame: screen, savedOffset: [120, 150])
        let b = FileSearchPanelPlacement.frame(contentSize: a.size,
            parentFrame: second, visibleFrame: screen.offsetBy(dx: -1920, dy: 400),
            savedOffset: [120, 150])
        XCTAssertEqual(b, a.offsetBy(dx: -1920, dy: 400))
    }

    func testOutlyingOffsetFitsCurrentScreen() {
        let screen = CGRect(x: 1920, y: 80, width: 1280, height: 720)
        let frame = FileSearchPanelPlacement.frame(contentSize: CGSize(width: 480, height: 400),
            parentFrame: screen, visibleFrame: screen, savedOffset: [-4000, 3000])
        XCTAssertTrue(screen.insetBy(dx: 16, dy: 16).contains(frame))
    }

    func testInvalidOffsetsUseDefaultPlacement() {
        let parent = CGRect(x: 100, y: 100, width: 1000, height: 800)
        func frame(_ offset: [Double]?) -> CGRect {
            FileSearchPanelPlacement.frame(contentSize: CGSize(width: 480, height: 52),
                parentFrame: parent, visibleFrame: parent, savedOffset: offset)
        }
        XCTAssertEqual(frame(nil).midX, parent.midX)
        XCTAssertEqual(frame(nil).maxY, parent.maxY - parent.height * 0.26)
        XCTAssertEqual(frame([1]), frame(nil))
        XCTAssertEqual(frame([.nan, 0]), frame(nil))
        XCTAssertEqual(frame([0, .infinity]), frame(nil))
    }
}
