import Foundation
import XCTest
@testable import MarkdownHelpers

final class ShareLinkTests: XCTestCase {

    private let base = URL(string: "https://share.example")!
    private let id = "EBESExQVFhcYGRobHB0eHw"
    private let keyString = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    private func parse(_ string: String, webBase: URL? = nil) -> ShareLink? {
        ShareLink.parse(URL(string: string)!, webBase: webBase ?? base)
    }

    // MARK: - Building

    func testBuildsWebAndAppURLs() throws {
        let link = try XCTUnwrap(ShareLink(id: id, key: Base64URL.decode(keyString)!, hasPassword: false))
        XCTAssertEqual(link.webURL(base: base).absoluteString,
                       "https://share.example/s/\(id)#\(keyString)")
        XCTAssertEqual(link.appURL.absoluteString, "md-preview://share/\(id)#\(keyString)")
    }

    func testPasswordLinksCarryThePrefix() throws {
        let link = try XCTUnwrap(ShareLink(id: id, key: Base64URL.decode(keyString)!, hasPassword: true))
        XCTAssertEqual(link.fragment, "p.\(keyString)")
        XCTAssertEqual(ShareLink.parse(link.webURL(base: base), webBase: base), link)
        XCTAssertEqual(ShareLink.parse(link.appURL, webBase: nil), link)
    }

    func testKeepsABasePath() throws {
        let link = try XCTUnwrap(ShareLink(id: id, key: Base64URL.decode(keyString)!, hasPassword: false))
        let pathBase = URL(string: "http://localhost:8787/dev/")!
        let url = link.webURL(base: pathBase)
        XCTAssertEqual(url.absoluteString, "http://localhost:8787/dev/s/\(id)#\(keyString)")
        XCTAssertEqual(ShareLink.parse(url, webBase: pathBase), link)
    }

    func testRejectsInvalidParts() {
        XCTAssertNil(ShareLink(id: "short", key: Data(count: 32), hasPassword: false))
        XCTAssertNil(ShareLink(id: id, key: Data(count: 16), hasPassword: false))
    }

    // MARK: - Parsing

    func testParsesTheVectorLinks() throws {
        for vector in try ShareLinkVectors.load() {
            let link = try XCTUnwrap(parse(vector.link), vector.name)
            XCTAssertEqual(Base64URL.encode(link.key), vector.key)
            XCTAssertEqual(link.hasPassword, vector.password != nil)
        }
    }

    func testStripsTrackingParametersFromTheFragment() {
        let link = parse("https://share.example/s/\(id)#\(keyString)&utm_source=chat")
        XCTAssertEqual(link.map { Base64URL.encode($0.key) }, keyString)
    }

    func testSchemeAndHostAreCaseInsensitive() {
        XCTAssertNotNil(parse("HTTPS://SHARE.EXAMPLE/s/\(id)#\(keyString)"))
        XCTAssertNotNil(parse("MD-PREVIEW://SHARE/\(id)#\(keyString)"))
    }

    func testRejectsOtherLinks() {
        let rejected = [
            "https://other.example/s/\(id)#\(keyString)",
            "http://share.example/s/\(id)#\(keyString)",
            "https://share.example:8443/s/\(id)#\(keyString)",
            "https://share.example/x/\(id)#\(keyString)",
            "https://share.example/s/\(id)/extra#\(keyString)",
            "https://share.example/s/\(id)",
            "https://share.example/s/\(id)#",
            "https://share.example/s/\(id)#\(keyString.dropLast())",
            "https://share.example/s/\(id)#\(keyString)=",
            "https://share.example/s/AAAA#\(keyString)",
            "md-preview://file/\(id)#\(keyString)",
            "md-preview://share/#\(keyString)",
            "file:///s/\(id)#\(keyString)",
        ]
        for string in rejected {
            XCTAssertNil(parse(string), string)
        }
    }

    func testWebFormNeedsAConfiguredBase() {
        XCTAssertNil(ShareLink.parse(URL(string: "https://share.example/s/\(id)#\(keyString)")!,
                                     webBase: nil))
    }

    // MARK: - Base64URL

    func testBase64URLRoundTripsWithoutPadding() {
        let data = Data([0xFB, 0xFF, 0xBF, 0x00])
        XCTAssertEqual(Base64URL.encode(data), "-_-_AA")
        XCTAssertEqual(Base64URL.decode("-_-_AA"), data)
    }

    func testBase64URLRejectsNonCanonicalInput() {
        XCTAssertNil(Base64URL.decode("+/+/AA"))
        XCTAssertNil(Base64URL.decode("AA=="))
        XCTAssertNil(Base64URL.decode("AB"), "non-zero trailing bits")
        XCTAssertNil(Base64URL.decode("A"))
        XCTAssertNil(Base64URL.decode("AA AA"))
    }
}
