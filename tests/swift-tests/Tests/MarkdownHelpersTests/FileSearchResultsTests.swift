import XCTest
@testable import MarkdownHelpers

final class FileSearchResultsTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/project")

    func testBlankQueryPreservesRecencyDeduplicatesAndCapsHistory() throws {
        let urls = (0..<12).map { root.appendingPathComponent("file-\($0).md") }
        let rows = try FileSearchResults.rows(query: "  ", recentURLs: [urls[0]] + urls, snapshot: nil)
        XCTAssertEqual(rows.first, .recentHeading)
        XCTAssertEqual(rows.compactMap { $0.entry?.url }, Array(urls.prefix(10)))
    }

    func testMatchingHistoryPrecedesProjectResultsWithoutDuplicates() throws {
        let recent = [root.appendingPathComponent("guide.md"), URL(fileURLWithPath: "/elsewhere/guide-old.md")]
        let snapshot = ProjectFileIndex.Snapshot(root: root, candidates: [
            .init(relativePath: "guide.md"), .init(relativePath: "guide-new.md"), .init(relativePath: "other.md")
        ], isTruncated: false)
        let rows = try FileSearchResults.rows(query: "guide", recentURLs: recent, snapshot: snapshot)
        XCTAssertEqual(rows.first, .recentHeading)
        XCTAssertEqual(rows[3], .filesHeading)
        XCTAssertEqual(rows.compactMap { $0.entry?.url }, recent + [root.appendingPathComponent("guide-new.md")])
        XCTAssertEqual(rows.last?.entry?.projectRoot, root)
        XCTAssertNil(rows[1].entry?.projectRoot)
    }

    func testHistorySearchWithoutProjectAndClearedHistory() throws {
        let recent = URL(fileURLWithPath: "/outside/notes.md")
        XCTAssertEqual(try FileSearchResults.rows(query: "outside/notes", recentURLs: [recent], snapshot: nil).last?.entry?.url, recent)
        XCTAssertEqual(try FileSearchResults.rows(query: "", recentURLs: [], snapshot: nil), [])
        XCTAssertEqual(try FileSearchResults.rows(query: "missing", recentURLs: [recent], snapshot: nil), [])
    }
}
