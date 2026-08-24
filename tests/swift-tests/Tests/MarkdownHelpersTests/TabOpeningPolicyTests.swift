import Foundation
import XCTest
@testable import MarkdownHelpers

final class TabOpeningPolicyTests: XCTestCase {
    private func joins(explicit: Bool = false,
                       inTabs: Bool = false,
                       system: TabOpeningPolicy.SystemPreference = .manual,
                       hostIsFullScreen: Bool = false) -> Bool {
        TabOpeningPolicy.joinsExistingTabGroup(isExplicitTabRequest: explicit,
                                               opensDocumentsInTabs: inTabs,
                                               systemPreference: system,
                                               hostIsFullScreen: hostIsFullScreen)
    }

    func testAPlainOpenGetsItsOwnWindowByDefault() {
        XCTAssertFalse(joins())
    }

    func testAnExplicitTabRequestAlwaysJoins() {
        XCTAssertTrue(joins(explicit: true))
        XCTAssertTrue(joins(explicit: true, system: .manual))
    }

    func testThePreferenceMakesAPlainOpenJoinTheFrontWindow() {
        XCTAssertTrue(joins(inTabs: true))
        XCTAssertTrue(joins(inTabs: true, system: .manual))
    }

    // The app preference is additive to the system one, so nothing about the
    // existing behaviour changes for readers who never turn it on.
    func testSystemPreferenceStillDecidesWhenTheAppPreferenceIsOff() {
        XCTAssertTrue(joins(system: .always))
        XCTAssertFalse(joins(system: .inFullScreen, hostIsFullScreen: false))
        XCTAssertTrue(joins(system: .inFullScreen, hostIsFullScreen: true))
    }

    func testPreferenceIsOffWhenNothingHasBeenStored() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(TabOpeningPolicy.read(from: defaults))
        XCTAssertFalse(TabOpeningPolicy.read(from: nil))
    }

    func testPreferenceRoundTripsAndClearsItsKeyWhenOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TabOpeningPolicy.write(true, to: defaults)
        XCTAssertTrue(TabOpeningPolicy.read(from: defaults))

        TabOpeningPolicy.write(false, to: defaults)
        XCTAssertFalse(TabOpeningPolicy.read(from: defaults))
        XCTAssertNil(defaults.object(forKey: TabOpeningPolicy.defaultsKey))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
