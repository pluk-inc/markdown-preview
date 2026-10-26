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

    func testReadsUnquotedSourcesAndNumericReferences() {
        let assets = collect(#"<img src=img/a.png alt=a><img src="img/My&#32;Photo.jpg"><img src='img&#x2F;b.svg'>"#)
        XCTAssertEqual(assets.map(\.path), ["img/a.png", "img/My Photo.jpg", "img/b.svg"])
    }

    func testReadsSrcOnlyOutsideQuotedValues() {
        // The image shows img/a.png; the alt text's src=… is not an attribute.
        let assets = collect(#"<img alt="example src=img/b.svg" src="img/a.png"><img alt='x src=img/b.svg'>"#)
        XCTAssertEqual(assets.map(\.path), ["img/a.png"])
    }

    func testKeepsEqualsSignsInUnquotedSources() {
        XCTAssertEqual(collect("<img src=img/a.png?v=1 alt=a>").map(\.path), ["img/a.png"])
    }

    func testKeepsTagsWithAnAngleBracketInAQuotedValue() {
        XCTAssertEqual(collect(#"<img src="img/a.png" alt="a > b">"#).map(\.path), ["img/a.png"])
    }

    func testSkipsTagsWithAnUnclosedQuote() {
        XCTAssertEqual(collect(#"<img alt="open src=img/a.png>"#).map(\.path), [])
    }

    func testDecodesCharacterReferencesOnce() {
        try? Data("x".utf8).write(to: directory.appendingPathComponent("img/A&quot;B.png"))
        let assets = collect(#"<img src="img/A&#38;quot;B.png"><img src="img/a.png?v=1&amp;x=2">"#)
        XCTAssertEqual(assets.map(\.path), ["img/A&quot;B.png", "img/a.png"])
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

    func testKeepsImagesWithHiddenInsideAQuotedValue() {
        let html = MarkdownHTML.render(markdown: "![a hidden gem](img/a.png)\n").articleHTML
        XCTAssertEqual(collect(html).map(\.path), ["img/a.png"])
        XCTAssertEqual(collect(#"<img title='x hidden' src="img/a.png">"#).map(\.path), ["img/a.png"])
    }

    func testKeepsTheAuthoredNameOfASymlinkInsideTheFolder() throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("img/alias.png"),
            withDestinationURL: directory.appendingPathComponent("img/a.png"))
        let assets = collect(#"<img src="img/alias.png">"#)
        XCTAssertEqual(assets.map(\.path), ["img/alias.png"])
        XCTAssertEqual(assets.first?.data, Data("img/a.png".utf8))
    }

    // MARK: - Web images

    func testListsShownWebImagesOnceWithReferencesDecoded() {
        let html = """
        <img src="https://example.com/a.png?x=1&amp;y=2"><img src="https://example.com/a.png?x=1&amp;y=2">
        <img src="http://example.com/b.png"><img src="img/a.png"><img src="data:image/png;base64,AA">
        <img src="ftp://example.com/c.png"><img hidden src="https://example.com/hidden.png">
        <!-- <img src="https://example.com/comment.png"> -->
        """
        XCTAssertEqual(ShareLinkAssets.webImageSources(articleHTML: html),
                       ["https://example.com/a.png?x=1&y=2", "http://example.com/b.png"])
    }

    func testDownloadsHTTPImagesOverHTTPSAndKeepsTheirAddress() async {
        let assets = await ShareLinkAssets.downloadWebImages(["http://example.com/a.png"], takenPaths: []) { url in
            XCTAssertEqual(url.absoluteString, "https://example.com/a.png")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])!
            return (Data([1]), response)
        }
        XCTAssertEqual(assets.map(\.source), ["http://example.com/a.png"])
    }

    func testListsAtMostFiftyWebImages() {
        let html = (1...60).map { #"<img src="https://example.com/\#($0).png">"# }.joined()
        let sources = ShareLinkAssets.webImageSources(articleHTML: html)
        XCTAssertEqual(sources.count, ShareLinkAssets.maxWebImages)
        XCTAssertEqual(sources.last, "https://example.com/50.png")
    }

    func testDownloadsSupportedWebImagesUnderTheirSources() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let assets = await ShareLinkAssets.downloadWebImages([
            "https://example.com/ok.png",
            "https://example.com/missing.png",
            "https://example.com/page",
            "https://example.com/photo.jpg",
            "https://example.com/huge.png",
            "https://example.com/error.png",
        ], takenPaths: ["web/1.png"]) { url in
            let (status, type, data): (Int, String, Data) = switch url.lastPathComponent {
            case "ok.png": (200, "image/png", png)
            case "missing.png": (404, "image/png", png)
            case "page": (200, "text/html", Data("<html>".utf8))
            // An error page for a .png address: the extension must not make it an image.
            case "error.png": (200, "text/html", Data("<html>".utf8))
            case "photo.jpg": (200, "application/octet-stream", Data([0xFF, 0xD8]))
            default: (200, "image/png", Data(count: ShareLinkAssets.maxWebImageBytes + 1))
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": type])!
            return (data, response)
        }
        // The document's own web/ folder is taken, so web images go in web_/.
        XCTAssertEqual(assets.map(\.path), ["web_/1.png", "web_/4.jpeg"])
        XCTAssertEqual(assets.map(\.type), ["image/png", "image/jpeg"])
        XCTAssertEqual(assets.map(\.source), ["https://example.com/ok.png", "https://example.com/photo.jpg"])
        XCTAssertEqual(assets.first?.data, png)
    }

    func testKeepsSmallWebImagesBesideLargeLocalOnesAndTheyStillSeal() throws {
        // Like a README: 4.5 MB of screenshots (random bytes do not compress,
        // like PNG data) and seven small badges.
        var screenshots = [UInt8](repeating: 0, count: 4_500_000)
        for index in screenshots.indices { screenshots[index] = UInt8.random(in: 0...255) }
        let local = SharePayload.Asset(path: "docs/shot.png", type: "image/png", data: Data(screenshots))
        let badges = (1...7).map {
            SharePayload.Asset(path: "web/\($0).svg", type: "image/svg+xml", data: Data(count: 2_000),
                               source: "https://img.shields.io/badge/\($0)")
        }
        let first = try XCTUnwrap(ShareLinkAssets.assetsToTry([local] + badges).first)
        XCTAssertEqual(first.count, 8)
        let payload = SharePayload(title: "README.md", markdown: "# R", html: "<h1>R</h1>", assets: first)
        XCTAssertNoThrow(try ShareLinkCrypto.seal(payload.encoded(), key: Data(count: 32), password: nil))
    }

    func testKeepsOnlyTheSmallestWebImagesThatFitTheBudgetWhileDownloading() async {
        let sizes = ["a": 300, "b": 100, "c": 500, "d": 200]
        let assets = await ShareLinkAssets.downloadWebImages(
            ["a", "b", "c", "d"].map { "https://example.com/\($0).png" }, takenPaths: [], budget: 350
        ) { url in
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "image/png"])!
            return (Data(count: sizes[url.deletingPathExtension().lastPathComponent]!), response)
        }
        XCTAssertEqual(assets.map(\.data.count), [100, 200])
    }

    func testFallsBackToTextOnlyWhenOnlyWebImagesWereSent() {
        let web = SharePayload.Asset(path: "web/1.png", type: "image/png", data: Data(count: 10),
                                     source: "https://example.com/a.png")
        XCTAssertEqual(ShareLinkAssets.assetsToTry([web]).map(\.count), [1, 0])
    }

    func testLeavesOutTheLargestWebImagesFirst() {
        let asset = { (path: String, bytes: Int, web: Bool) in
            SharePayload.Asset(path: path, type: "image/png", data: Data(count: bytes),
                               source: web ? "https://example.com/\(path)" : nil)
        }
        let tries = ShareLinkAssets.assetsToTry([
            asset("local.png", 3_000_000, false),
            asset("big.png", 3_000_000, true),
            asset("small.png", 1_000, true),
        ])
        XCTAssertEqual(tries.map { $0.map(\.path) }, [["local.png", "small.png"], ["local.png"], []])
    }

    func testCollectsFromTheAppRenderer() {
        let html = MarkdownHTML.render(markdown: "![a](img/a.png)\n\n![p](<img/My Photo.jpg>)\n").articleHTML
        XCTAssertEqual(collect(html).map(\.path), ["img/a.png", "img/My Photo.jpg"])
    }
}
