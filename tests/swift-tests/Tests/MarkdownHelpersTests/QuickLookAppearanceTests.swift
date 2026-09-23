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
        XCTAssertEqual(defaults.string(forKey: AppearanceMode.defaultsKey), "automatic")
    }

    func testEveryExplicitModeSurvivesRepeatedStartupMigration() throws {
        let (legacy, legacySuiteName) = try makeDefaults()
        let (shared, sharedSuiteName) = try makeDefaults()
        defer {
            legacy.removePersistentDomain(forName: legacySuiteName)
            shared.removePersistentDomain(forName: sharedSuiteName)
        }
        for legacyMode in AppearanceMode.allCases {
            AppearanceMode.write(legacyMode, to: legacy)
            for selectedMode in AppearanceMode.allCases {
                AppearanceMode.write(selectedMode, to: shared)
                for _ in 0..<3 {
                    let reopened = try XCTUnwrap(UserDefaults(suiteName: sharedSuiteName))
                    XCTAssertEqual(AppearanceMode.migrateLegacyValue(from: legacy, to: reopened), selectedMode)
                }
            }
        }
    }

    func testFreshInstallStartsAutomaticWithOriginalColors() throws {
        let (legacy, legacySuiteName) = try makeDefaults()
        let (shared, sharedSuiteName) = try makeDefaults()
        defer {
            legacy.removePersistentDomain(forName: legacySuiteName)
            shared.removePersistentDomain(forName: sharedSuiteName)
        }
        XCTAssertEqual(AppearanceMode.migrateLegacyValue(from: legacy, to: shared), .automatic)
        XCTAssertEqual(ThemeColorsSetting.read(from: shared), ThemePreset.defaultPreset.setting)
        XCTAssertFalse(ThemeColorsSetting.read(from: shared).isCustomized)
    }

    func testAppearanceChangesDoNotResetSavedThemeColors() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var colors = ThemeColorsSetting()
        colors.setHex("#123456", .windowBackground, .dark)
        colors.setHex("#FEDCBA", .textColor, .light)
        ThemeColorsSetting.write(colors, to: defaults)
        for mode in AppearanceMode.allCases {
            AppearanceMode.write(mode, to: defaults)
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            XCTAssertEqual(ThemeColorsSetting.read(from: reopened), colors)
        }
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
