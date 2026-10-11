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
    // A real 1×1 PNG: files outside the document folder must decode as images.
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
    private let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)

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

    func testAbsoluteNonImagePathUntouched() {
        let html = #"<img src="/etc/passwd">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail(); return Data() }
        )
        XCTAssertEqual(result.html, html)
    }

    func testProtocolRelativeSrcLeftAlone() {
        let html = #"<img src="//example.com/a.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called for //host refs"); return Data() }
        )
        XCTAssertEqual(result.html, html)
    }

    // #488: the app resolves these, so Quick Look must too.
    func testParentDirectoryImagesBecomeCIDs() {
        let html = #"<img src="../assets/2026/07/monthly.jpg"><img src="../../device%20evidence/x.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: URL(fileURLWithPath: "/tmp/qltest-fixture/report/", isDirectory: true),
            reader: reader([
                "/tmp/qltest-fixture/assets/2026/07/monthly.jpg": png,
                "/tmp/device evidence/x.png": png,
            ])
        )
        XCTAssertEqual(result.attachments.count, 2)
        XCTAssertFalse(result.html.contains("../"))
    }

    func testAbsoluteImagePathBecomesCID() {
        let html = #"<img src="/Users/k/Screenshots/shot%20one.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(["/Users/k/Screenshots/shot one.png": png])
        )
        XCTAssertEqual(result.attachments.values.first?.data, png)
        XCTAssertTrue(result.html.contains("src=\"cid:"))
    }

    func testOutsideSVGWithSVGContentBecomesCID() {
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: #"<img src="../diagram.svg">"#,
            baseDirectory: baseDir,
            reader: reader(["/tmp/diagram.svg": svg])
        )
        XCTAssertEqual(result.attachments.values.first?.data, svg)
    }

    func testOutsideSVGAfterLongCommentBecomesCID() {
        let comment = "<!-- " + String(repeating: "x", count: 2048) + " -->"
        let data = Data((#"<?xml version="1.0"?>"# + comment + #"<svg xmlns="http://www.w3.org/2000/svg"/>"#).utf8)
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: #"<img src="../diagram.svg">"#,
            baseDirectory: baseDir,
            reader: reader(["/tmp/diagram.svg": data])
        )
        XCTAssertEqual(result.attachments.values.first?.data, data)
    }

    func testOutsideSVGNameWithSVGOnlyInCommentIsLeftAlone() {
        let html = #"<img src="../notes.svg">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(["/tmp/notes.svg": Data("<!-- <svg> --><notes>secret</notes>".utf8)])
        )
        XCTAssertEqual(result.html, html)
    }

    func testOutsideImageNameWithNonImageBytesIsLeftAlone() {
        // e.g. `../x.png` is a symlink to a text file, or a renamed one.
        let html = #"<img src="../x.png"><img src="/Users/k/notes.jpg"><img src="../fake.svg">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/x.png": Data("secret token".utf8),
                "/Users/k/notes.jpg": red,
                "/tmp/fake.svg": Data("not a drawing".utf8),
            ])
        )
        XCTAssertEqual(result.html, html)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testParentDirectoryNonImageIsLeftAlone() {
        let html = #"<img src="../secret.txt"><img src="../../.ssh/id_ed25519">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called for non-images outside the folder"); return Data() }
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

    func testSingleQuotedRawHTMLImageBecomesCID() {
        let html = #"<img src='images/local.png' width="40">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(["/tmp/qltest-fixture/images/local.png": red])
        )
        XCTAssertEqual(result.attachments.values.first?.data, red)
        XCTAssertEqual(result.html, #"<img src='cid:md-asset-0' width="40">"#)
        XCTAssertTrue(
            InlineLocalAssets.dataURLHTML(from: result).hasPrefix("<img src='data:image/png;base64,"),
            InlineLocalAssets.dataURLHTML(from: result)
        )
    }

    func testOtherQuoteInsideValueIsPartOfThePath() {
        let html = #"<img src="it's.png"> <img src='say "hi".png'>"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/it's.png": red,
                "/tmp/qltest-fixture/say \"hi\".png": blue,
            ])
        )
        XCTAssertEqual(result.html, #"<img src="cid:md-asset-0"> <img src='cid:md-asset-1'>"#)
        XCTAssertEqual(result.attachments["md-asset-0"]?.data, red)
        XCTAssertEqual(result.attachments["md-asset-1"]?.data, blue)
    }

    func testEscapedAmpersandIsDecodedBeforeReading() {
        // The renderer writes `![x](a&b.png)` as `src="a&amp;b.png"`.
        let html = #"<img src="a&amp;b.png"> <img src="c&#38;d.png"> <img src="e&#x26;f.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a&b.png": red,
                "/tmp/qltest-fixture/c&d.png": blue,
                "/tmp/qltest-fixture/e&f.png": red,
            ])
        )
        XCTAssertEqual(result.attachments.count, 3)
        XCTAssertFalse(result.html.contains("&"), result.html)
    }

    func testBareAmpersandInRawHTMLStaysLiteral() {
        let html = #"<img src='a&b.png'> <img src="x&amp.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a&b.png": red,
                "/tmp/qltest-fixture/x&amp.png": blue,
            ])
        )
        XCTAssertEqual(result.attachments["md-asset-0"]?.data, red)
        XCTAssertEqual(result.attachments["md-asset-1"]?.data, blue)
    }

    func testAngleBracketInsideQuotedValueIsPartOfThePath() {
        let html = #"<img src="chart>v2.png"> <img src='a>b.png'>"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/chart>v2.png": red,
                "/tmp/qltest-fixture/a>b.png": blue,
            ])
        )
        XCTAssertEqual(result.html, #"<img src="cid:md-asset-0"> <img src='cid:md-asset-1'>"#)
    }

    func testSpacedSrcIsMatchedAndDataSrcIsNot() {
        let html = #"<img src = 'a.png'> <img data-src='b.png' src='c.png'>"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a.png": red,
                "/tmp/qltest-fixture/b.png": blue,
                "/tmp/qltest-fixture/c.png": red,
            ])
        )
        XCTAssertEqual(result.html, #"<img src = 'cid:md-asset-0'> <img data-src='b.png' src='cid:md-asset-1'>"#)
    }

    func testSrcTextInsideAnotherAttributeIsSkipped() {
        let html = #"<img title=" src = 'fake.png'" src="real.png"> <img alt="example src='other.png'" src='actual.png'>"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/real.png": red,
                "/tmp/qltest-fixture/actual.png": blue,
                "/tmp/qltest-fixture/fake.png": blue,
                "/tmp/qltest-fixture/other.png": red,
            ])
        )
        XCTAssertEqual(
            result.html,
            #"<img title=" src = 'fake.png'" src="cid:md-asset-0"> <img alt="example src='other.png'" src='cid:md-asset-1'>"#
        )
        XCTAssertEqual(result.attachments["md-asset-0"]?.data, red)
        XCTAssertEqual(result.attachments["md-asset-1"]?.data, blue)
    }

    func testNamedReferencesAreCaseSensitive() {
        // `&AMP;` is valid HTML; `&aMp;` is not, so WebKit keeps it literal.
        let html = #"<img src="a&AMP;b.png"> <img src="c&aMp;d.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a&b.png": red,
                "/tmp/qltest-fixture/c&aMp;d.png": blue,
                "/tmp/qltest-fixture/c&d.png": red,
            ])
        )
        XCTAssertEqual(result.attachments["md-asset-0"]?.data, red)
        XCTAssertEqual(result.attachments["md-asset-1"]?.data, blue)
    }

    func testNumericReferencesFollowHTMLReplacements() {
        let html = #"<img src="price&#x80;.png"> <img src="bad&#xD800;.png">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/price€.png": red,
                "/tmp/qltest-fixture/bad\u{FFFD}.png": blue,
            ])
        )
        XCTAssertEqual(result.attachments["md-asset-0"]?.data, red)
        XCTAssertEqual(result.attachments["md-asset-1"]?.data, blue)
    }

    func testCharacterReferenceAbsolutePathIsStillChecked() {
        // `&#47;` is `/`: the decoded value is absolute, so only image
        // files outside the folder are read.
        let html = #"<img src="&#47;etc&#47;passwd">"#
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: { _ in XCTFail("reader must not be called for a non-image outside the folder"); return Data() }
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

    func testAttachmentsCanBeEmbeddedAsDataURLsForViewBasedPreview() {
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: #"<img src="a.png"><img src="b">"#,
            baseDirectory: baseDir,
            reader: reader([
                "/tmp/qltest-fixture/a.png": red,
                "/tmp/qltest-fixture/b": blue,
            ])
        )

        let html = InlineLocalAssets.dataURLHTML(from: result)

        XCTAssertFalse(html.contains("cid:"))
        XCTAssertTrue(html.contains("data:image/png;base64,\(red.base64EncodedString())"))
        XCTAssertTrue(html.contains(
            "data:application/octet-stream;base64,\(blue.base64EncodedString())"
        ))
    }

    func testDataURLConversionKeepsOverlappingContentIDsDistinct() {
        let sources = (0...10).map { "image-\($0).png" }
        let html = sources.map { #"<img src="\#($0)">"# }.joined()
        let files = Dictionary(uniqueKeysWithValues: sources.enumerated().map { index, source in
            ("/tmp/qltest-fixture/\(source)", Data([UInt8(index)]))
        })
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: baseDir,
            reader: reader(files)
        )

        let converted = InlineLocalAssets.dataURLHTML(from: result)

        XCTAssertEqual(result.attachments.count, 11)
        XCTAssertFalse(converted.contains("cid:"))
        for index in 0...10 {
            let encoded = Data([UInt8(index)]).base64EncodedString()
            XCTAssertTrue(converted.contains(#"src="data:image/png;base64,\#(encoded)""#))
        }
    }

    func testDataURLConversionDoesNotReplaceCIDTextOutsideImageSources() {
        let result = InlineLocalAssets.rewriteRelativeImages(
            html: #"<p>cid:md-asset-0</p><img src="a.png">"#,
            baseDirectory: baseDir,
            reader: reader(["/tmp/qltest-fixture/a.png": red])
        )

        let html = InlineLocalAssets.dataURLHTML(from: result)

        XCTAssertTrue(html.contains("<p>cid:md-asset-0</p>"))
        XCTAssertTrue(html.contains("data:image/png;base64,\(red.base64EncodedString())"))
    }
}
