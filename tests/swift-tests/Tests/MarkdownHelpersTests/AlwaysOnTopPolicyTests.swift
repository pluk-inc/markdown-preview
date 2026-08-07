import CoreGraphics
import XCTest
@testable import MarkdownHelpers

final class AlwaysOnTopPolicyTests: XCTestCase {
    func testPinnedWindowSitsAtTheFloatingLevel() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: true),
                       Int(CGWindowLevelForKey(.floatingWindow)))
    }

    func testUnpinnedWindowReturnsToTheNormalLevel() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: false),
                       Int(CGWindowLevelForKey(.normalWindow)))
    }

    func testPinningRaisesTheWindowAboveItsUnpinnedLevel() {
        XCTAssertGreaterThan(AlwaysOnTopPolicy.windowLevel(isPinned: true),
                             AlwaysOnTopPolicy.windowLevel(isPinned: false))
    }

    func testUntabbedWindowIsTheOnlyOneAffected() {
        XCTAssertEqual(AlwaysOnTopPolicy.affectedWindows(toggling: "doc", tabGroup: nil),
                       ["doc"])
    }

    func testTabbedWindowPinsEveryWindowInItsGroup() {
        let group = ["notes", "readme", "changelog"]
        XCTAssertEqual(AlwaysOnTopPolicy.affectedWindows(toggling: "readme", tabGroup: group),
                       group)
    }

    // AppKit hands back an empty array rather than nil in some teardown
    // orderings; the toggle must still reach the window the reader clicked.
    func testEmptyTabGroupStillAffectsTheToggledWindow() {
        XCTAssertEqual(AlwaysOnTopPolicy.affectedWindows(toggling: "doc", tabGroup: []),
                       ["doc"])
    }
}
