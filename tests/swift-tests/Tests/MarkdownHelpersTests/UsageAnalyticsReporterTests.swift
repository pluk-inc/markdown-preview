import Foundation
import XCTest
@testable import MarkdownHelpers

final class UsageAnalyticsReporterTests: XCTestCase {
    func testAnalyticsIsEnabledByDefaultAndPersistsAnOptOut() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(UsageAnalyticsReporter.isEnabled(defaults: defaults))

        UsageAnalyticsReporter.setEnabled(false, defaults: defaults)
        XCTAssertFalse(UsageAnalyticsReporter.isEnabled(defaults: defaults))

        UsageAnalyticsReporter.setEnabled(true, defaults: defaults)
        XCTAssertTrue(UsageAnalyticsReporter.isEnabled(defaults: defaults))
    }

    func testInstallationIDIsRandomValidAndStable() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = UsageAnalyticsReporter.installationID(defaults: defaults)
        let second = UsageAnalyticsReporter.installationID(defaults: defaults)

        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, second)
    }

    func testInvalidStoredInstallationIDIsReplaced() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("not-a-uuid", forKey: UsageAnalyticsReporter.installationIDDefaultsKey)

        let replacement = UsageAnalyticsReporter.installationID(defaults: defaults)

        XCTAssertNotNil(UUID(uuidString: replacement))
        XCTAssertNotEqual(replacement, "not-a-uuid")
    }

    func testCaptureIsLimitedToOncePerUTCDay() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstDay = Date(timeIntervalSince1970: 1_787_529_600)
        let laterThatDay = firstDay.addingTimeInterval(60 * 60)
        let nextDay = firstDay.addingTimeInterval(24 * 60 * 60)

        XCTAssertTrue(UsageAnalyticsReporter.shouldCapture(on: firstDay, defaults: defaults))
        UsageAnalyticsReporter.markCaptureAttempt(on: firstDay, defaults: defaults)
        XCTAssertFalse(UsageAnalyticsReporter.shouldCapture(on: laterThatDay, defaults: defaults))
        XCTAssertTrue(UsageAnalyticsReporter.shouldCapture(on: nextDay, defaults: defaults))
    }

    func testRequestContainsOnlyTheAnonymousActiveEventFields() throws {
        let installationID = UUID().uuidString.lowercased()
        let request = try XCTUnwrap(UsageAnalyticsReporter.makeRequest(
            projectToken: "phc_test-token",
            installationID: installationID,
            appVersion: "0.0.49",
            macOSMajorVersion: 26,
            architecture: "arm64",
            localeRegion: "MY"
        ))

        XCTAssertEqual(request.url?.absoluteString, "https://us.i.posthog.com/i/v0/e/")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(Set(payload.keys), ["api_key", "event", "distinct_id", "properties"])
        XCTAssertEqual(payload["api_key"] as? String, "phc_test-token")
        XCTAssertEqual(payload["event"] as? String, UsageAnalyticsReporter.eventName)
        XCTAssertEqual(payload["distinct_id"] as? String, installationID)

        let properties = try XCTUnwrap(payload["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), [
            "$geoip_disable",
            "$process_person_profile",
            "app_version",
            "macos_major_version",
            "architecture",
            "locale_region"
        ])
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertEqual(properties["$process_person_profile"] as? Bool, false)
        XCTAssertEqual(properties["app_version"] as? String, "0.0.49")
        XCTAssertEqual(properties["macos_major_version"] as? Int, 26)
        XCTAssertEqual(properties["architecture"] as? String, "arm64")
        XCTAssertEqual(properties["locale_region"] as? String, "MY")
    }

    func testRequestRejectsMissingTokenPlaceholderAndInvalidID() {
        let validID = UUID().uuidString
        XCTAssertNil(UsageAnalyticsReporter.makeRequest(
            projectToken: "",
            installationID: validID,
            appVersion: "0.0.49",
            macOSMajorVersion: 26,
            architecture: "arm64",
            localeRegion: "MY"
        ))
        XCTAssertNil(UsageAnalyticsReporter.makeRequest(
            projectToken: "$(POSTHOG_PROJECT_TOKEN)",
            installationID: validID,
            appVersion: "0.0.49",
            macOSMajorVersion: 26,
            architecture: "arm64",
            localeRegion: "MY"
        ))
        XCTAssertNil(UsageAnalyticsReporter.makeRequest(
            projectToken: "phc_test-token",
            installationID: "not-a-uuid",
            appVersion: "0.0.49",
            macOSMajorVersion: 26,
            architecture: "arm64",
            localeRegion: "MY"
        ))
    }

    func testArchitectureIsCoarsenedToASupportedValue() {
        XCTAssertTrue(["arm64", "x86_64", "unknown"].contains(
            UsageAnalyticsReporter.currentArchitecture
        ))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
