import CoreGraphics
import Foundation
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

    // Settings is where the pin is turned off again, so a floating document
    // window that could cover it would leave no way back.
    func testSettingsSitsAboveAPinnedPreviewWindow() {
        XCTAssertGreaterThan(AlwaysOnTopPolicy.settingsWindowLevel(isPinned: true),
                             AlwaysOnTopPolicy.windowLevel(isPinned: true, isFullScreen: false))
    }

    func testSettingsStaysAtTheNormalLevelWhileNothingIsPinned() {
        XCTAssertEqual(AlwaysOnTopPolicy.settingsWindowLevel(isPinned: false),
                       Int(CGWindowLevelForKey(.normalWindow)))
    }

    func testSettingIsOffWhenNothingHasBeenStored() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AlwaysOnTopPolicy.read(from: defaults))
        XCTAssertFalse(AlwaysOnTopPolicy.read(from: nil))
    }

    func testSettingRoundTripsThroughDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AlwaysOnTopPolicy.write(true, to: defaults)
        XCTAssertTrue(AlwaysOnTopPolicy.read(from: defaults))

        AlwaysOnTopPolicy.write(false, to: defaults)
        XCTAssertFalse(AlwaysOnTopPolicy.read(from: defaults))
    }

    // Off is the default, so it leaves no key behind — the same shape as
    // appearance and content width.
    func testTurningTheSettingOffClearsItsKey() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AlwaysOnTopPolicy.write(true, to: defaults)
        XCTAssertNotNil(defaults.object(forKey: AlwaysOnTopPolicy.defaultsKey))

        AlwaysOnTopPolicy.write(false, to: defaults)
        XCTAssertNil(defaults.object(forKey: AlwaysOnTopPolicy.defaultsKey))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
