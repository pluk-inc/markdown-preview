import Foundation
import XCTest
@testable import MarkdownHelpers

final class SharePayloadTests: XCTestCase {

    private func json(_ assets: String, version: Int = 1) -> Data {
        Data(##"{"v":\##(version),"title":"a.md","markdown":"# A","html":"<h1>A</h1>","assets":\##(assets)}"##.utf8)
    }

    // MARK: - Encoding

    func testRoundTrips() throws {
        let payload = SharePayload(title: "README.md",
                                   markdown: "![x](img/x.png)",
                                   html: "<p><img src=\"img/x.png\"></p>",
                                   assets: [.init(path: "img/x.png", type: "image/png", data: Data([1, 2, 3]))])
        XCTAssertEqual(try SharePayload.decode(payload.encoded()), payload)
    }

    func testEncodesTheDocumentedFieldNames() throws {
        let payload = SharePayload(title: "t", markdown: "m", html: "h",
                                   assets: [.init(path: "a.png", type: "image/png", data: Data([0xFF]))])
        XCTAssertEqual(String(decoding: try payload.encoded(), as: UTF8.self),
                       #"{"assets":[{"data":"/w==","path":"a.png","type":"image/png"}],"html":"h","markdown":"m","title":"t","v":1}"#)
    }

    func testDecodesTheVectorPlaintexts() throws {
        for vector in try ShareLinkVectors.load() {
            XCTAssertNoThrow(try SharePayload.decode(Data(vector.plaintext.utf8)), vector.name)
        }
    }

    // MARK: - Validation

    func testRejectsAnotherVersion() {
        XCTAssertThrowsError(try SharePayload.decode(json("[]", version: 2))) {
            XCTAssertEqual($0 as? SharePayload.Failure, .unsupportedVersion(2))
        }
    }

    func testNormalizesAssetPathsAndTypes() throws {
        let payload = try SharePayload.decode(json(#"[{"path":"./img//x.png","type":"IMAGE/PNG","data":""}]"#))
        XCTAssertEqual(payload.assets.first?.path, "img/x.png")
        XCTAssertEqual(payload.assets.first?.type, "image/png")
    }

    func testRejectsEscapingAssetPaths() {
        for path in ["../x.png", "img/../../x.png", "/etc/x.png", "img\\\\x.png", "", "./", "a/\\u0000.png"] {
            XCTAssertThrowsError(try SharePayload.decode(json(#"[{"path":"\#(path)","type":"image/png","data":""}]"#)),
                                 path) {
                guard case .invalidAssetPath = $0 as? SharePayload.Failure else {
                    return XCTFail("\(path): \($0)")
                }
            }
        }
    }

    func testRejectsUnsupportedAssetTypes() {
        XCTAssertThrowsError(try SharePayload.decode(json(#"[{"path":"x.html","type":"text/html","data":""}]"#))) {
            XCTAssertEqual($0 as? SharePayload.Failure, .unsupportedAssetType("text/html"))
        }
    }

    func testRejectsDuplicateAssetPaths() {
        let assets = #"[{"path":"x.png","type":"image/png","data":""},{"path":"./x.png","type":"image/png","data":""}]"#
        XCTAssertThrowsError(try SharePayload.decode(json(assets))) {
            XCTAssertEqual($0 as? SharePayload.Failure, .duplicateAssetPath("x.png"))
        }
    }

    // MARK: - Hostile strings

    func testDisplayTitleDropsControlCharactersAndSeparators() {
        let payload = SharePayload(title: " ../evil\n/name:\u{7}.md ", markdown: "", html: "", assets: [])
        XCTAssertEqual(payload.displayTitle, "..evilname.md")
        let long = SharePayload(title: String(repeating: "a", count: 500), markdown: "", html: "", assets: [])
        XCTAssertEqual(long.displayTitle.count, 200)
    }

    func testAssetFileURLStaysInsideTheDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("share")
        let url = try XCTUnwrap(SharePayload.fileURL(forAssetPath: "img/x.png", in: directory))
        XCTAssertTrue(url.path.hasSuffix("/share/img/x.png"))
        XCTAssertNil(SharePayload.fileURL(forAssetPath: "../x.png", in: directory))
        XCTAssertNil(SharePayload.fileURL(forAssetPath: "/x.png", in: directory))
    }

    func testUnpacksIntoAFolderNamedAfterTheTitle() throws {
        let shareFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shareFolder) }
        let stale = shareFolder.appendingPathComponent("Old/Old.md")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("old".utf8).write(to: stale)

        let payload = SharePayload(title: "Plan", markdown: "# Plan\n", html: "", assets: [
            .init(path: "img/a.png", type: "image/png", data: Data("png".utf8)),
            .init(path: "../outside.png", type: "image/png", data: Data("x".utf8)),
        ])
        let file = try payload.unpack(into: shareFolder)

        XCTAssertEqual(file.lastPathComponent, "Plan.md")
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "Plan")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Plan\n")
        let image = file.deletingLastPathComponent().appendingPathComponent("img/a.png")
        XCTAssertEqual(try Data(contentsOf: image), Data("png".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareFolder.appendingPathComponent("outside.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testUnpacksAnUntitledShareUnderAFallbackName() throws {
        let shareFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: shareFolder) }
        for title in ["", ".env"] {
            let file = try SharePayload(title: title, markdown: "x", html: "", assets: [])
                .unpack(into: shareFolder)
            XCTAssertEqual(file.lastPathComponent, "Shared Document.md", title)
        }
        let kept = try SharePayload(title: "notes.markdown", markdown: "x", html: "", assets: [])
            .unpack(into: shareFolder)
        XCTAssertEqual(kept.lastPathComponent, "notes.markdown")
    }
}
