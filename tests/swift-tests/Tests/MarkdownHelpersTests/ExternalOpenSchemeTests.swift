import Foundation
import XCTest
@testable import MarkdownHelpers

final class ExternalOpenSchemeTests: XCTestCase {

    // MARK: - Scheme detection

    func testRecognizesSchemeURL() {
        XCTAssertTrue(ExternalOpenScheme.isSchemeURL(URL(string: "md-preview://file/Users/me/a.md")!))
        XCTAssertTrue(ExternalOpenScheme.isSchemeURL(URL(string: "MD-PREVIEW://file/Users/me/a.md")!))
    }

    func testRejectsOtherSchemes() {
        XCTAssertFalse(ExternalOpenScheme.isSchemeURL(URL(fileURLWithPath: "/Users/me/a.md")))
        XCTAssertFalse(ExternalOpenScheme.isSchemeURL(URL(string: "https://example.com/a.md")!))
        XCTAssertFalse(ExternalOpenScheme.isSchemeURL(URL(string: "cursor://file/Users/me/a.md")!))
    }

    // MARK: - Accepted forms

    func testResolvesFileHostForm() {
        let url = URL(string: "md-preview://file/Users/me/project/README.md")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.path,
                       "/Users/me/project/README.md")
    }

    func testResolvesEmptyHostForm() {
        let url = URL(string: "md-preview:///Users/me/project/README.md")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.path,
                       "/Users/me/project/README.md")
    }

    func testResolvedURLIsFileURL() {
        let url = URL(string: "md-preview://file/Users/me/a.md")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.isFileURL, true)
    }

    func testHostIsCaseInsensitive() {
        let url = URL(string: "md-preview://FILE/Users/me/a.md")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.path, "/Users/me/a.md")
    }

    func testDecodesPercentEncodedPath() {
        let url = URL(string: "md-preview://file/Users/me/My%20Notes/%E8%AF%B4%E6%98%8E.md")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.path,
                       "/Users/me/My Notes/说明.md")
    }

    func testStandardizesDotSegments() {
        let url = URL(string: "md-preview://file/Users/me/docs/../README.md")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.path,
                       "/Users/me/README.md")
    }

    func testAcceptsFolderPathWithTrailingSlash() {
        let url = URL(string: "md-preview://file/Users/me/docs/")!
        XCTAssertEqual(ExternalOpenScheme.fileURL(from: url)?.path, "/Users/me/docs")
    }

    // MARK: - Rejected forms

    func testRejectsUnknownHost() {
        let url = URL(string: "md-preview://open/Users/me/a.md")!
        XCTAssertNil(ExternalOpenScheme.fileURL(from: url))
    }

    func testRejectsEmptyPath() {
        XCTAssertNil(ExternalOpenScheme.fileURL(from: URL(string: "md-preview://file")!))
        XCTAssertNil(ExternalOpenScheme.fileURL(from: URL(string: "md-preview://file/")!))
        XCTAssertNil(ExternalOpenScheme.fileURL(from: URL(string: "md-preview://")!))
    }

    func testRejectsOtherSchemeURL() {
        let url = URL(string: "cursor://file/Users/me/a.md")!
        XCTAssertNil(ExternalOpenScheme.fileURL(from: url))
    }
}
