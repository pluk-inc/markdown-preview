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
}
