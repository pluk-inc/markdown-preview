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
    func testSymlinkHistoryAndProjectMatchAppearOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("guide.md")
        let alias = directory.appendingPathComponent("guide-link.md")
        try "# Guide".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let snapshot = ProjectFileIndex.Snapshot(root: directory, candidates: [
            .init(relativePath: "guide.md")
        ], isTruncated: false)
        let rows = try FileSearchResults.rows(query: "guide", recentURLs: [alias, file], snapshot: snapshot)
        XCTAssertEqual(rows.compactMap { $0.entry?.url }, [file])
        XCTAssertFalse(rows.contains(.filesHeading))
    }

    func testDifferentAliasNameDoesNotHideMatchingRecentTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("guide.md")
        let alias = directory.appendingPathComponent("shortcut.md")
        try "# Guide".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)

        let matching = try FileSearchResults.rows(query: "guide.md", recentURLs: [alias, file], snapshot: nil)
        XCTAssertEqual(matching.compactMap { $0.entry?.url }, [file])
        let aliasMatch = try FileSearchResults.rows(query: "shortcut", recentURLs: [alias, file], snapshot: nil)
        XCTAssertEqual(aliasMatch.compactMap { $0.entry?.url }, [alias])
        let blank = try FileSearchResults.rows(query: "", recentURLs: [alias, file], snapshot: nil)
        XCTAssertEqual(blank.compactMap { $0.entry?.url }, [alias])
    }

    func testCurrentFileIdentityMatchesAnAliasBeforeReloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("edited.md")
        let alias = directory.appendingPathComponent("shortcut.md")
        try "Old disk content".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        // The selection guard must recognize this identity without loading old
        // disk content or asking the editor to commit its newer in-memory text.
        XCTAssertEqual(FileSearchResults.resolvedIdentity(file), FileSearchResults.resolvedIdentity(alias))
        XCTAssertNotEqual(FileSearchResults.resolvedIdentity(file),
                          FileSearchResults.resolvedIdentity(directory.appendingPathComponent("other.md")))
    }

}
