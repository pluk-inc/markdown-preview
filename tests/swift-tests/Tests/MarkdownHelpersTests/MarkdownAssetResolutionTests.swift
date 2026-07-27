import XCTest
@testable import MarkdownHelpers

final class MarkdownAssetResolutionTests: XCTestCase {

    // MARK: baseHref(forFolder:)

    func testBaseHrefMirrorsFolderPathWithTrailingSlash() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        XCTAssertEqual(
            MarkdownAssetResolution.baseHref(forFolder: folder),
            "md-asset:///Users/me/notes/sub/"
        )
    }

    func testBaseHrefPercentEncodesSpecialCharacters() {
        let folder = URL(fileURLWithPath: "/Users/me/My Notes", isDirectory: true)
        XCTAssertEqual(
            MarkdownAssetResolution.baseHref(forFolder: folder),
            "md-asset:///Users/me/My%20Notes/"
        )
    }

    // MARK: fileURL(for:)

    func testFileURLMapsAssetPathToAbsoluteFilePath() {
        let asset = URL(string: "md-asset:///Users/me/notes/img.png")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset)?.path,
            "/Users/me/notes/img.png"
        )
    }

    func testFileURLDecodesPercentEncoding() {
        let asset = URL(string: "md-asset:///Users/me/My%20Notes/a%20b.md")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset)?.path,
            "/Users/me/My Notes/a b.md"
        )
    }

    func testFileURLStandardizesTraversalSegments() {
        let asset = URL(string: "md-asset:///Users/me/notes/sub/../sibling.md")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset)?.path,
            "/Users/me/notes/sibling.md"
        )
    }

    func testFileURLRejectsRootAndEmptyPaths() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset:///")!))
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset://")!))
    }

    func testFileURLRejectsNonEmptyHost() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset://example.com/etc/hosts")!))
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset://__vendor/katex.min.js")!))
    }

    func testFileURLRejectsOtherSchemes() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "file:///etc/hosts")!))
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "https://example.com/a.md")!))
    }

    // MARK: End-to-end relative resolution

    /// Mirrors what WebKit does with a relative href against the page
    /// `<base>`: a `../` link climbs into the parent folder and maps back to
    /// the right file — the behaviour the base-href design exists to enable.
    func testParentRelativeLinkResolvesAgainstBaseHref() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        let base = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder))!
        let clicked = URL(string: "../sibling.md", relativeTo: base)!.absoluteURL
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: clicked)?.path,
            "/Users/me/notes/sibling.md"
        )
    }

    func testSameFolderRelativeLinkResolvesAgainstBaseHref() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        let base = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder))!
        let clicked = URL(string: "images/pic.png", relativeTo: base)!.absoluteURL
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: clicked)?.path,
            "/Users/me/notes/sub/images/pic.png"
        )
    }
}
