import Foundation
import XCTest
@testable import MarkdownHelpers

final class QuickLookLinkHandoffTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/Users/me/docs/README.md")
    private let target = URL(string: "md-preview://file/Users/me/docs/setup.md#install-steps")!
    private let now = Date(timeIntervalSince1970: 1_000)

    func testMatchingSourceReturnsTargetAndFragment() {
        let pending = QuickLookLinkHandoff.Pending(source: source, target: target, created: now)
        XCTAssertEqual(pending.target(for: source, now: now.addingTimeInterval(1)), target)
        XCTAssertNil(pending.target(for: URL(fileURLWithPath: "/Users/me/other.md"), now: now))
    }

    func testSourcePathsAreStandardized() {
        let pending = QuickLookLinkHandoff.Pending(source: source, target: target, created: now)
        XCTAssertEqual(pending.target(for: URL(fileURLWithPath: "/Users/me/docs/sub/../README.md"), now: now), target)
    }

    func testStaleAndFutureRequestsDoNotRedirect() {
        let pending = QuickLookLinkHandoff.Pending(source: source, target: target, created: now)
        for age: TimeInterval in [60, 100, -1] {
            XCTAssertNil(pending.target(for: source, now: now.addingTimeInterval(age)))
        }
    }

    func testUnsupportedTargetsAreRejected() {
        for string in ["mailto:a@example.com", "file:///Users/me/docs/setup.md", "md-preview://file/Users/me/a.txt", "md-preview://open/Users/me/a.md", "https:relative"] {
            let url = URL(string: string)!
            XCTAssertFalse(QuickLookLinkHandoff.isSupported(url), string)
            XCTAssertNil(QuickLookLinkHandoff.Pending(source: source, target: url, created: now).target(for: source, now: now))
        }
        XCTAssertTrue(QuickLookLinkHandoff.isSupported(URL(string: "https://example.com/path#section")!))
    }

    func testRoundTripCorrelatesReplyToQuery() {
        let query = QuickLookLinkHandoff.Query(id: UUID(), source: source)
        let decoded = QuickLookLinkHandoff.decode(QuickLookLinkHandoff.Query.self, object: QuickLookLinkHandoff.encode(query))
        XCTAssertEqual(decoded?.id, query.id)
        XCTAssertEqual(decoded?.source, source)
        let reply = QuickLookLinkHandoff.Reply(id: query.id, target: target)
        let decodedReply = QuickLookLinkHandoff.decode(QuickLookLinkHandoff.Reply.self, object: QuickLookLinkHandoff.encode(reply))
        XCTAssertEqual(decodedReply?.id, query.id)
        XCTAssertEqual(decodedReply?.target, target)
    }

    func testMalformedAndOversizeMessagesAreIgnored() {
        for object: Any in [42, "not json", String(repeating: "x", count: 65_537)] {
            XCTAssertNil(QuickLookLinkHandoff.decode(QuickLookLinkHandoff.Query.self, object: object))
        }
        XCTAssertNotEqual(QuickLookLinkHandoff.notification("query", appID: "doc.md-preview"), QuickLookLinkHandoff.notification("query", appID: "doc.md-preview.dev"))
    }
}
