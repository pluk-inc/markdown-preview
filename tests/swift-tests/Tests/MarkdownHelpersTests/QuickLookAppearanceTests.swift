import Foundation
import XCTest
@testable import MarkdownHelpers

final class AppearanceModeTests: XCTestCase {
    func testMissingAndInvalidValuesDefaultToAutomatic() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppearanceMode.read(from: defaults), .automatic)

        defaults.set("sepia", forKey: AppearanceMode.defaultsKey)
        XCTAssertEqual(AppearanceMode.read(from: defaults), .automatic)
        XCTAssertEqual(AppearanceMode.read(from: nil), .automatic)
    }

    func testEveryModeRoundTripsThroughDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for mode in AppearanceMode.allCases {
            AppearanceMode.write(mode, to: defaults)
            XCTAssertEqual(AppearanceMode.read(from: defaults), mode)
        }

        AppearanceMode.write(.automatic, to: defaults)
        XCTAssertNil(defaults.object(forKey: AppearanceMode.defaultsKey))
    }

    func testLegacyValueMigratesOnlyWhenSharedValueIsMissing() throws {
        let (legacy, legacySuiteName) = try makeDefaults()
        let (shared, sharedSuiteName) = try makeDefaults()
        defer {
            legacy.removePersistentDomain(forName: legacySuiteName)
            shared.removePersistentDomain(forName: sharedSuiteName)
        }

        legacy.set(AppearanceMode.light.rawValue, forKey: AppearanceMode.defaultsKey)
        XCTAssertEqual(
            AppearanceMode.migrateLegacyValue(from: legacy, to: shared),
            .light
        )
        XCTAssertEqual(AppearanceMode.read(from: shared), .light)

        shared.set(AppearanceMode.dark.rawValue, forKey: AppearanceMode.defaultsKey)
        XCTAssertEqual(
            AppearanceMode.migrateLegacyValue(from: legacy, to: shared),
            .dark
        )
        XCTAssertEqual(AppearanceMode.read(from: shared), .dark)
    }

    func testModesResolveExpectedColorScheme() {
        XCTAssertEqual(
            AppearanceMode.light.resolvedColorScheme(systemIsDark: true),
            .light
        )
        XCTAssertEqual(
            AppearanceMode.dark.resolvedColorScheme(systemIsDark: false),
            .dark
        )
        XCTAssertEqual(
            AppearanceMode.automatic.resolvedColorScheme(systemIsDark: false),
            .light
        )
        XCTAssertEqual(
            AppearanceMode.automatic.resolvedColorScheme(systemIsDark: true),
            .dark
        )
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
