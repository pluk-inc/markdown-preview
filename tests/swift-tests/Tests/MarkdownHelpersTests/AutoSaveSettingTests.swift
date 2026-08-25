import Foundation
import XCTest
@testable import MarkdownHelpers

final class AutoSaveSettingTests: XCTestCase {
    func testMissingValueDisablesAutomaticSaving() throws {
        let defaults = try makeDefaults()

        XCTAssertEqual(
            AutoSaveSetting.currentMinutes(from: defaults),
            AutoSaveSetting.disabledMinutes
        )
    }

    func testStoredValueIsClampedToSupportedRange() throws {
        let defaults = try makeDefaults()

        defaults.set(0, forKey: AutoSaveSetting.defaultsKey)
        XCTAssertEqual(
            AutoSaveSetting.currentMinutes(from: defaults),
            AutoSaveSetting.disabledMinutes
        )

        defaults.set(120, forKey: AutoSaveSetting.defaultsKey)
        XCTAssertEqual(AutoSaveSetting.currentMinutes(from: defaults), 60)
    }

    func testStoreNormalizesValueBeforePersisting() throws {
        let defaults = try makeDefaults()

        AutoSaveSetting.store(minutes: 0, in: defaults)
        XCTAssertEqual(
            defaults.integer(forKey: AutoSaveSetting.defaultsKey),
            AutoSaveSetting.disabledMinutes
        )

        AutoSaveSetting.store(minutes: 12, in: defaults)
        XCTAssertEqual(AutoSaveSetting.currentMinutes(from: defaults), 12)
    }

    func testThirtySecondIntervalUsesDedicatedValue() throws {
        let defaults = try makeDefaults()

        defaults.set(AutoSaveSetting.thirtySeconds, forKey: AutoSaveSetting.defaultsKey)

        XCTAssertEqual(
            AutoSaveSetting.currentMinutes(from: defaults),
            AutoSaveSetting.thirtySeconds
        )
        XCTAssertEqual(AutoSaveSetting.interval(for: AutoSaveSetting.thirtySeconds), 30)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AutoSaveSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
