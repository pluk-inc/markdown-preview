import Foundation
import XCTest
@testable import MarkdownHelpers

/// End to end against a running share Worker. Skipped unless
/// MDP_SHARE_WORKER_URL is set, e.g. to http://localhost:8787 while
/// `npm run dev` runs in server/share-worker.
final class ShareLinkWorkerRoundTripTests: XCTestCase {

    func testRenderSealUploadFetchAndOpen() async throws {
        guard let base = ProcessInfo.processInfo.environment["MDP_SHARE_WORKER_URL"]
            .flatMap(URL.init(string:))
        else { throw XCTSkip("MDP_SHARE_WORKER_URL is not set") }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareLinkWorkerRoundTrip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("img"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try png.write(to: directory.appendingPathComponent("img/dot.png"))

        let markdown = "# Shared\n\n**Bold** and ![dot](img/dot.png) and ![r](https://example.com/r.png)\n"
        let html = MarkdownHTML.render(markdown: markdown).articleHTML
        let assets = ShareLinkAssets.collect(articleHTML: html, directory: directory)
        XCTAssertEqual(assets.map(\.path), ["img/dot.png"])

        let payload = SharePayload(title: "Shared.md", markdown: markdown, html: html, assets: assets)
        let key = ShareLinkCrypto.randomKey()
        let envelope = try ShareLinkCrypto.seal(payload.encoded(), key: key, password: nil)

        let client = ShareLinkClient(baseURL: base)
        let created = try await client.create(envelope, expiry: .hour)
        let link = try XCTUnwrap(ShareLink(id: created.id, key: key, hasPassword: false))
        let parsed = try XCTUnwrap(ShareLink.parse(link.webURL(base: base), webBase: base))

        let fetched = try await client.fetch(id: parsed.id)
        let opened = try SharePayload.decode(ShareLinkCrypto.open(fetched, key: parsed.key, password: nil))
        XCTAssertEqual(opened, payload)
        XCTAssertTrue(opened.html.contains("<strong>Bold</strong>"))

        _ = try await client.update(id: created.id, envelope: envelope,
                                    ownerToken: created.ownerToken, expiry: .day)
        try await client.delete(id: created.id, ownerToken: created.ownerToken)
        do {
            _ = try await client.fetch(id: created.id)
            XCTFail("a deleted share should be gone")
        } catch {
            XCTAssertEqual(error as? ShareLinkClient.Failure, .notFound)
        }
    }
}
