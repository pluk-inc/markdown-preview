import Foundation
import XCTest
@testable import MarkdownHelpers

final class ReleaseNotesPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let build = 80

    override func setUp() {
        super.setUp()
        suiteName = "ReleaseNotesPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func claim(thisBuild: Int, hasUsedAppBefore: Bool = true) -> Bool {
        ReleaseNotesPolicy.claimPresentation(defaults: defaults, thisBuild: thisBuild,
                                             hasUsedAppBefore: hasUsedAppBefore)
    }

    private var recordedBuild: Int? {
        defaults.object(forKey: ReleaseNotesPolicy.lastBuildKey) as? Int
    }

    func testUpdatingFromAnOlderBuildOpensOnce() {
        defaults.set(build - 1, forKey: ReleaseNotesPolicy.lastBuildKey)
        XCTAssertTrue(claim(thisBuild: build))
        XCTAssertFalse(claim(thisBuild: build))
        XCTAssertEqual(recordedBuild, build)
    }

    func testReaderFromBeforeTheBuildWasRecordedOpensOnce() {
        XCTAssertTrue(claim(thisBuild: build, hasUsedAppBefore: true))
        XCTAssertFalse(claim(thisBuild: build, hasUsedAppBefore: true))
    }

    func testFreshInstallStaysQuietAndRecordsItsBuild() {
        XCTAssertFalse(claim(thisBuild: build, hasUsedAppBefore: false))
        XCTAssertEqual(recordedBuild, build)
        XCTAssertTrue(claim(thisBuild: build + 1, hasUsedAppBefore: true))
        XCTAssertEqual(recordedBuild, build + 1)
    }

    func testClaimUpdateReturnsTheVersionUpdatedFrom() {
        defaults.set(build - 1, forKey: ReleaseNotesPolicy.lastBuildKey)
        defaults.set("0.0.9", forKey: ReleaseNotesPolicy.lastVersionKey)
        XCTAssertEqual(ReleaseNotesPolicy.claimUpdate(defaults: defaults, thisBuild: build,
                                                      thisVersion: "0.0.11", hasUsedAppBefore: true), "0.0.9")
        XCTAssertNil(ReleaseNotesPolicy.claimUpdate(defaults: defaults, thisBuild: build,
                                                    thisVersion: "0.0.11", hasUsedAppBefore: true))
        XCTAssertEqual(defaults.string(forKey: ReleaseNotesPolicy.lastVersionKey), "0.0.11")
    }

    func testClaimUpdateFromABuildThatNeverRecordedItsVersion() {
        defaults.set(build - 1, forKey: ReleaseNotesPolicy.lastBuildKey)
        XCTAssertEqual(ReleaseNotesPolicy.claimUpdate(defaults: defaults, thisBuild: build,
                                                      thisVersion: "0.0.11", hasUsedAppBefore: true), "")
    }

    func testAnOlderBuildNeverLowersTheRecordedBuild() {
        defaults.set(build + 5, forKey: ReleaseNotesPolicy.lastBuildKey)
        XCTAssertFalse(claim(thisBuild: build))
        XCTAssertEqual(recordedBuild, build + 5)
    }
}
