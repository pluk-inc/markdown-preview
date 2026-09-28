import Foundation
import XCTest
@testable import MarkdownHelpers

final class WhatsNewPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let featuresBuild = WhatsNewPolicy.featuresBuild

    override func setUp() {
        super.setUp()
        suiteName = "WhatsNewPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func claim(thisBuild: Int, hasUsedAppBefore: Bool = true) -> Bool {
        WhatsNewPolicy.claimPresentation(defaults: defaults, thisBuild: thisBuild,
                                         hasUsedAppBefore: hasUsedAppBefore)
    }

    private var recordedBuild: Int? {
        defaults.object(forKey: WhatsNewPolicy.lastBuildKey) as? Int
    }

    func testUpdatingFromAnOlderBuildShowsOnce() {
        defaults.set(featuresBuild - 1, forKey: WhatsNewPolicy.lastBuildKey)
        XCTAssertTrue(claim(thisBuild: featuresBuild))
        XCTAssertFalse(claim(thisBuild: featuresBuild))
        XCTAssertEqual(recordedBuild, featuresBuild)
    }

    func testReaderFromBeforeTheBuildWasRecordedShowsOnce() {
        XCTAssertTrue(claim(thisBuild: featuresBuild, hasUsedAppBefore: true))
        XCTAssertFalse(claim(thisBuild: featuresBuild, hasUsedAppBefore: true))
    }

    func testFreshInstallStaysQuietAndRecordsItsBuild() {
        XCTAssertFalse(claim(thisBuild: featuresBuild, hasUsedAppBefore: false))
        XCTAssertEqual(recordedBuild, featuresBuild)
        XCTAssertFalse(claim(thisBuild: featuresBuild + 1, hasUsedAppBefore: true))
        XCTAssertEqual(recordedBuild, featuresBuild + 1)
    }

    func testDevelopmentBuildBelowTheFeaturesBuildShowsOnlyOnce() {
        XCTAssertTrue(claim(thisBuild: featuresBuild - 1))
        XCTAssertFalse(claim(thisBuild: featuresBuild - 1))
    }

    func testAnOlderBuildNeverLowersTheRecordedBuild() {
        defaults.set(featuresBuild + 5, forKey: WhatsNewPolicy.lastBuildKey)
        XCTAssertFalse(claim(thisBuild: featuresBuild))
        XCTAssertEqual(recordedBuild, featuresBuild + 5)
    }
}
