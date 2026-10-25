import Foundation
import XCTest

/// Release builds sign with md-preview.release.entitlements, which adds
/// Associated Domains (Universal Links) for the share links. Debug builds
/// cannot carry it, so the two files exist side by side; this test fails
/// when anything else drifts between them.
final class EntitlementsParityTests: XCTestCase {

    private static let appFolder = TestVendor.repositoryRoot.appendingPathComponent("md-preview")

    private static let releaseOnlyKey = "com.apple.developer.associated-domains"

    private func entitlements(_ name: String) throws -> NSDictionary {
        let data = try Data(contentsOf: Self.appFolder.appendingPathComponent(name))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary)
    }

    func testReleaseOnlyAddsAssociatedDomains() throws {
        let shared = try entitlements("md-preview.entitlements")
        let release = try entitlements("md-preview.release.entitlements")

        XCTAssertNil(shared[Self.releaseOnlyKey], "Debug builds cannot get a profile for it")
        XCTAssertEqual(release[Self.releaseOnlyKey] as? [String], ["applinks:md-preview.app"])

        let releaseRest = release.mutableCopy() as! NSMutableDictionary
        releaseRest.removeObject(forKey: Self.releaseOnlyKey)
        XCTAssertEqual(releaseRest, shared)
    }
}
