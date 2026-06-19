import XCTest
@testable import QuickLookHelpers

final class InlineLocalAssetsTests: XCTestCase {

    private let baseDir = URL(fileURLWithPath: "/tmp/qltest-fixture/", isDirectory: true)

    private func reader(_ files: [String: Data]) -> (URL) throws -> Data {
        return { url in
            if let data = files[url.path] { return data }
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    private let red = Data([0xDE, 0xAD, 0xBE, 0xEF])
    private let blue = Data([0xCA, 0xFE, 0xBA, 0xBE])

    // MARK: - Rewriting

    func testRelativePathBecomesCID() {
        let html = #"<p><img src="images/local.png" alt="x"></p>"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/images/local.png": red,
            ])
        )
        XCTAssertEqual(result.attachments.count, 1)
        let cid = result.attachments.keys.first!
        XCTAssertEqual(result.attachments[cid]?.data, red)
        XCTAssertEqual(result.attachments[cid]?.pathExtension, "png")
        XCTAssertTrue(
            result.html.contains(#"src="cid:\#(cid)""#),
            "expected rewritten src=cid:\(cid) in: \(result.html)"
        )
    }

    func testPercentEncodedSpacesAreDecodedBeforeReading() {
        let html = #"<img src="images%20dir/two%20words.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/images dir/two words.png": blue,
            ])
        )
        XCTAssertEqual(result.attachments.count, 1)
        XCTAssertEqual(result.attachments.values.first?.data, blue)
        XCTAssertEqual(result.attachments.values.first?.pathExtension, "png")
        XCTAssertTrue(result.html.contains("src=\"cid:"))
    }

    func testPathExtensionIsLowercased() {
        let html = #"<img src="UPPER.JPG">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(["/tmp/qltest-fixture/UPPER.JPG": red])
        )
        XCTAssertEqual(result.attachments.values.first?.pathExtension, "jpg")
    }

    // MARK: - Untouched cases

    func testHTTPSrcLeftAlone() {
        let html = #"<img src="https://example.com/a.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called"); return Data() }
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testDataURIUntouched() {
        let html = #"<img src="data:image/png;base64,iVBOR">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail(); return Data() }
        )
        XCTAssertEqual(result.html, html)
    }

    func testCIDUntouched() {
        let html = #"<img src="cid:already">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail(); return Data() }
        )
        XCTAssertEqual(result.html, html)
    }

    func testHostAbsolutePathUntouched() {
        let html = #"<img src="/etc/passwd">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail(); return Data() }
        )
        XCTAssertEqual(result.html, html)
    }

    func testParentDirectoryTraversalIsLeftAlone() {
        let html = #"<img src="../secret.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called for parent traversal"); return Data() }
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testPercentEncodedAbsolutePathIsLeftAlone() {
        let html = #"<img src="%2Fetc%2Fpasswd">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called for encoded absolute path"); return Data() }
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testPercentEncodedSchemeIsLeftAlone() {
        let html = #"<img src="file%3A%2F%2F%2Fetc%2Fpasswd">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called for encoded URL scheme"); return Data() }
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testSingleQuotedRawHTMLImageLeftAlone() {
        let html = #"<img src='images/local.png'>"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called"); return Data() }
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    // MARK: - Failure tolerance

    func testReadFailureLeavesSrcAlone() {
        let html = #"<img src="missing.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([:])
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    // MARK: - Budgets

    func testPerImageByteCapSkipsOversizedAsset() {
        let big = Data(repeating: 0xAA, count: 10_000)
        let html = #"<img src="big.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(["/tmp/qltest-fixture/big.png": big]),
            perImageByteCap: 1_000,
            cumulativeByteCap: 1_000_000
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testCumulativeByteCapStopsEmbedding() {
        let threeKB = Data(repeating: 0xBB, count: 3_000)
        let html = """
        <img src="a.png">
        <img src="b.png">
        <img src="c.png">
        """
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a.png": threeKB,
                "/tmp/qltest-fixture/b.png": threeKB,
                "/tmp/qltest-fixture/c.png": threeKB,
            ]),
            perImageByteCap: 5_000,
            cumulativeByteCap: 5_000
        )
        XCTAssertEqual(
            result.attachments.count, 1,
            "second image already exceeds budget; only first embeds"
        )
        XCTAssertTrue(result.html.contains(#"src="cid:"#))
        XCTAssertTrue(result.html.contains(#"src="b.png""#))
        XCTAssertTrue(result.html.contains(#"src="c.png""#))
    }

    // MARK: - Determinism / dedupe

    func testIdenticalSrcReusesSameCID() {
        let html = #"<img src="x.png"> and <img src="x.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(["/tmp/qltest-fixture/x.png": red])
        )
        XCTAssertEqual(result.attachments.count, 1, "dedupe identical paths")
        let cid = result.attachments.keys.first!
        let occurrences = result.html.components(separatedBy: "cid:\(cid)").count - 1
        XCTAssertEqual(occurrences, 2)
    }

    func testDistinctSrcGetDistinctCIDs() {
        let html = #"<img src="a.png"><img src="b.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a.png": red,
                "/tmp/qltest-fixture/b.png": blue,
            ])
        )
        XCTAssertEqual(result.attachments.count, 2)
        XCTAssertEqual(
            Set(result.attachments.values.map { $0.data }),
            Set([red, blue])
        )
    }
}
