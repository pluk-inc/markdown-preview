import Foundation
import XCTest
@testable import MarkdownHelpers

final class ShareLinkAssetsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareLinkAssetsTests-\(UUID().uuidString)/doc")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("img"),
                                                withIntermediateDirectories: true)
        for name in ["img/a.png", "img/My Photo.jpg", "img/b.svg", "notes.txt"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        try Data("outside".utf8).write(to: directory.deletingLastPathComponent()
            .appendingPathComponent("outside.png"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func collect(_ html: String) -> [SharePayload.Asset] {
        ShareLinkAssets.collect(articleHTML: html, directory: directory)
    }

    func testCollectsRelativeImagesWithTheirTypes() {
        let assets = collect(#"<p><img src="img/a.png" alt="a"><img alt='x' src='img/b.svg'></p>"#)
        XCTAssertEqual(assets.map(\.path), ["img/a.png", "img/b.svg"])
        XCTAssertEqual(assets.map(\.type), ["image/png", "image/svg+xml"])
        XCTAssertEqual(assets.first?.data, Data("img/a.png".utf8))
    }

    func testDecodesPercentEscapesAndNormalizesDotSegments() {
        let assets = collect(#"<img src="./img/My%20Photo.jpg"><img src="img/../img/a.png">"#)
        XCTAssertEqual(assets.map(\.path), ["img/My Photo.jpg", "img/a.png"])
    }

    func testSkipsRemoteAbsoluteEscapingAndNonImageSources() {
        let html = """
        <img src="https://example.com/x.png"><img src="//cdn.example/x.png">
        <img src="data:image/png;base64,AAAA"><img src="/etc/x.png">
        <img src="../outside.png"><img src="notes.txt"><img src="missing.png">
        <img data-src="img/a.png" src="https://example.com/lazy.png">
        """
        XCTAssertEqual(collect(html), [])
    }

    func testCollectsEachFileOnce() {
        let assets = collect(#"<img src="img/a.png"><img src="./img/a.png?v=2">"#)
        XCTAssertEqual(assets.map(\.path), ["img/a.png"])
    }

    func testSkipsSymlinksThatLeaveTheFolder() throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("img/link.png"),
            withDestinationURL: directory.deletingLastPathComponent().appendingPathComponent("outside.png"))
        XCTAssertEqual(collect(#"<img src="img/link.png">"#), [])
    }

    func testSkipsImagesThePreviewDoesNotShow() {
        let html = """
        <!-- <img src="img/a.png"> -->
        <template><img src="img/a.png"></template>
        <noscript><img src="img/b.svg"></noscript>
        <img hidden src="img/My Photo.jpg">
        <!-- unterminated <img src="img/a.png">
        """
        XCTAssertEqual(collect(html), [])
    }

    func testKeepsTheAuthoredNameOfASymlinkInsideTheFolder() throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("img/alias.png"),
            withDestinationURL: directory.appendingPathComponent("img/a.png"))
        let assets = collect(#"<img src="img/alias.png">"#)
        XCTAssertEqual(assets.map(\.path), ["img/alias.png"])
        XCTAssertEqual(assets.first?.data, Data("img/a.png".utf8))
    }

    func testCollectsFromTheAppRenderer() {
        let html = MarkdownHTML.render(markdown: "![a](img/a.png)\n\n![p](<img/My Photo.jpg>)\n").articleHTML
        XCTAssertEqual(collect(html).map(\.path), ["img/a.png", "img/My Photo.jpg"])
    }
}
