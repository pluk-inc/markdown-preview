import Foundation
import XCTest
@testable import MarkdownHelpers

final class QuickLookAppearanceTests: XCTestCase {
    func testMissingAndInvalidValuesDefaultToLight() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(QuickLookAppearanceMode.read(from: defaults), .light)

        defaults.set("sepia", forKey: QuickLookAppearanceMode.defaultsKey)
        XCTAssertEqual(QuickLookAppearanceMode.read(from: defaults), .light)
        XCTAssertEqual(QuickLookAppearanceMode.read(from: nil), .light)
    }

    func testEveryModeRoundTripsThroughDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for mode in QuickLookAppearanceMode.allCases {
            QuickLookAppearanceMode.write(mode, to: defaults)
            XCTAssertEqual(QuickLookAppearanceMode.read(from: defaults), mode)
        }
    }

    func testModesResolveExpectedColorScheme() {
        XCTAssertEqual(
            QuickLookAppearanceMode.light.resolvedColorScheme(systemIsDark: true),
            .light
        )
        XCTAssertEqual(
            QuickLookAppearanceMode.dark.resolvedColorScheme(systemIsDark: false),
            .dark
        )
        XCTAssertEqual(
            QuickLookAppearanceMode.automatic.resolvedColorScheme(systemIsDark: false),
            .light
        )
        XCTAssertEqual(
            QuickLookAppearanceMode.automatic.resolvedColorScheme(systemIsDark: true),
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
