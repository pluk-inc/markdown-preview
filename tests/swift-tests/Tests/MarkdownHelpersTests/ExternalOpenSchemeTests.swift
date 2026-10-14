import Foundation
import XCTest
@testable import MarkdownHelpers

final class ExternalOpenSchemeTests: XCTestCase {

    // MARK: - Other schemes pass through

    func testPassesThroughFileURL() {
        let url = URL(fileURLWithPath: "/Users/me/a.md")
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: url), url)
    }

    func testPassesThroughForeignSchemes() {
        let https = URL(string: "https://example.com/a.md")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: https), https)

        let cursor = URL(string: "cursor://file/Users/me/a.md")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: cursor), cursor)
    }

    // MARK: - Accepted forms

    func testResolvesFileHostForm() {
        let url = URL(string: "md-preview://file/Users/me/project/README.md")!
        let resolved = ExternalOpenScheme.resolvedURL(opening: url)
        XCTAssertEqual(resolved?.path, "/Users/me/project/README.md")
        XCTAssertEqual(resolved?.isFileURL, true)
    }

    func testResolvesEmptyHostForm() {
        let url = URL(string: "md-preview:///Users/me/project/README.md")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: url)?.path,
                       "/Users/me/project/README.md")
    }

    func testSchemeAndHostAreCaseInsensitive() {
        let url = URL(string: "MD-PREVIEW://FILE/Users/me/a.md")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: url)?.path,
                       "/Users/me/a.md")
    }

    func testDecodesPercentEncodedPath() {
        let url = URL(string: "md-preview://file/Users/me/My%20Notes/%E8%AF%B4%E6%98%8E.md")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: url)?.path,
                       "/Users/me/My Notes/说明.md")
    }

    func testStandardizesDotSegments() {
        let url = URL(string: "md-preview://file/Users/me/docs/../README.md")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: url)?.path,
                       "/Users/me/README.md")
    }

    func testAcceptsFolderPathWithTrailingSlash() {
        let url = URL(string: "md-preview://file/Users/me/docs/")!
        XCTAssertEqual(ExternalOpenScheme.resolvedURL(opening: url)?.path,
                       "/Users/me/docs")
    }

    // MARK: - Malformed links

    func testRejectsUnknownHost() {
        let url = URL(string: "md-preview://open/Users/me/a.md")!
        XCTAssertNil(ExternalOpenScheme.resolvedURL(opening: url))
    }

    func testRejectsEmptyPath() {
        XCTAssertNil(ExternalOpenScheme.resolvedURL(opening: URL(string: "md-preview://file")!))
        XCTAssertNil(ExternalOpenScheme.resolvedURL(opening: URL(string: "md-preview://file/")!))
        XCTAssertNil(ExternalOpenScheme.resolvedURL(opening: URL(string: "md-preview://")!))
    }

    // MARK: - Fragment

    func testFragmentIsReturnedDecoded() {
        XCTAssertEqual(ExternalOpenScheme.fragment(opening: URL(string: "md-preview://file/Users/me/a.md#install-steps")!),
                       "install-steps")
        XCTAssertEqual(ExternalOpenScheme.fragment(opening: URL(string: "MD-PREVIEW://file/Users/me/a.md#caf%C3%A9")!),
                       "café")
    }

    func testNoFragmentForOtherSchemesOrEmptyFragment() {
        XCTAssertNil(ExternalOpenScheme.fragment(opening: URL(string: "md-preview://file/Users/me/a.md")!))
        XCTAssertNil(ExternalOpenScheme.fragment(opening: URL(string: "md-preview://file/Users/me/a.md#")!))
        XCTAssertNil(ExternalOpenScheme.fragment(opening: URL(string: "file:///Users/me/a.md#x")!))
    }

    // MARK: - Quick Look hand-off

    func testQuickLookNotificationIsPerApp() {
        XCTAssertEqual(ExternalOpenScheme.quickLookOpenNotification(appBundleIdentifier: "doc.md-preview").rawValue,
                       "doc.md-preview.quick-look.open")
        XCTAssertNotEqual(ExternalOpenScheme.quickLookOpenNotification(appBundleIdentifier: "doc.md-preview"),
                          ExternalOpenScheme.quickLookOpenNotification(appBundleIdentifier: "doc.md-preview.dev"))
    }

    func testQuickLookHandsOffOnlyWebAndAppLinks() {
        for string in ["https://example.com", "HTTP://example.com", "md-preview://file/Users/me/a.md"] {
            XCTAssertTrue(ExternalOpenScheme.isQuickLookHandOff(URL(string: string)!), string)
        }
        for string in ["mailto:a@b.c", "unlisted-app://x", "file:///etc/hosts", "javascript:alert(1)", "guide.md"] {
            XCTAssertFalse(ExternalOpenScheme.isQuickLookHandOff(URL(string: string)!), string)
        }
    }
}
