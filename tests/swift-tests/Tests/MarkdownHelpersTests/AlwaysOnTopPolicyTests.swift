import CoreGraphics
import XCTest
@testable import MarkdownHelpers

final class AlwaysOnTopPolicyTests: XCTestCase {
    func testPinnedWindowSitsAtTheFloatingLevel() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: true, isFullScreen: false),
                       Int(CGWindowLevelForKey(.floatingWindow)))
    }

    func testUnpinnedWindowReturnsToTheNormalLevel() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: false, isFullScreen: false),
                       Int(CGWindowLevelForKey(.normalWindow)))
    }

    func testPinningRaisesTheWindowAboveItsUnpinnedLevel() {
        XCTAssertGreaterThan(AlwaysOnTopPolicy.windowLevel(isPinned: true, isFullScreen: false),
                             AlwaysOnTopPolicy.windowLevel(isPinned: false, isFullScreen: false))
    }

    // AppKit refuses full screen to any window above the normal level, which is
    // what silently greyed out Enter Full Screen once a window was pinned.
    func testPinnedWindowDropsToTheNormalLevelInFullScreen() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: true, isFullScreen: true),
                       Int(CGWindowLevelForKey(.normalWindow)))
    }

    func testUnpinnedWindowStaysAtTheNormalLevelInFullScreen() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: false, isFullScreen: true),
                       Int(CGWindowLevelForKey(.normalWindow)))
    }

    // The pin is intent, not the level itself: leaving full screen while still
    // pinned has to float the window again rather than strand it at normal.
    func testLeavingFullScreenWhilePinnedFloatsTheWindowAgain() {
        XCTAssertEqual(AlwaysOnTopPolicy.windowLevel(isPinned: true, isFullScreen: false),
                       Int(CGWindowLevelForKey(.floatingWindow)))
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
