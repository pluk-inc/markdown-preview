import Foundation
import XCTest
@testable import MarkdownHelpers

final class AutoSaveSettingTests: XCTestCase {
    func testMissingValueUsesFiveMinutes() throws {
        let defaults = try makeDefaults()

        XCTAssertEqual(AutoSaveSetting.currentMinutes(from: defaults), 5)
    }

    func testStoredValueIsClampedToSupportedRange() throws {
        let defaults = try makeDefaults()

        defaults.set(0, forKey: AutoSaveSetting.defaultsKey)
        XCTAssertEqual(AutoSaveSetting.currentMinutes(from: defaults), 1)

        defaults.set(120, forKey: AutoSaveSetting.defaultsKey)
        XCTAssertEqual(AutoSaveSetting.currentMinutes(from: defaults), 60)
    }

    func testStoreNormalizesValueBeforePersisting() throws {
        let defaults = try makeDefaults()

        AutoSaveSetting.store(minutes: 0, in: defaults)
        XCTAssertEqual(defaults.integer(forKey: AutoSaveSetting.defaultsKey), 1)

        AutoSaveSetting.store(minutes: 12, in: defaults)
        XCTAssertEqual(AutoSaveSetting.currentMinutes(from: defaults), 12)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AutoSaveSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
