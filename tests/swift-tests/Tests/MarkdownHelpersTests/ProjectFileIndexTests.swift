import Foundation
import XCTest
@testable import MarkdownHelpers

final class ProjectFileIndexTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appending(path: "ProjectFileIndexTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    /// Creates a file at a path relative to the fixture root, making the
    /// intermediate directories on the way.
    private func write(_ relativePath: String) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func paths(maximumFileCount: Int = ProjectFileIndex.maximumFileCount,
                       maximumDepth: Int = ProjectFileIndex.maximumDepth) -> [String] {
        ProjectFileIndex.build(root: root,
                               maximumFileCount: maximumFileCount,
                               maximumDepth: maximumDepth)
            .candidates.map(\.relativePath).sorted()
    }

    // MARK: - What gets indexed

    func testNestedFilesAreFound() throws {
        try write("README.md")
        try write("docs/guide.md")
        try write("docs/deep/nested.md")

        XCTAssertEqual(paths(), ["README.md", "docs/deep/nested.md", "docs/guide.md"])
    }

    func testTheRelativePathIsRelativeToTheRootWithNoLeadingSlash() throws {
        try write("docs/guide.md")

        let candidate = try XCTUnwrap(ProjectFileIndex.build(root: root).candidates.first)
        XCTAssertEqual(candidate.relativePath, "docs/guide.md")
        XCTAssertEqual(candidate.fileName, "guide.md")
    }

    func testEveryMarkdownExtensionTheNavigatorShowsIsIndexed() throws {
        for ext in ProjectFileIndex.markdownExtensions {
            try write("file-\(ext).\(ext)")
        }

        XCTAssertEqual(paths().count, ProjectFileIndex.markdownExtensions.count)
    }

    func testTheExtensionMatchIsCaseInsensitive() throws {
        try write("SHOUTING.MD")

        XCTAssertEqual(paths(), ["SHOUTING.MD"])
    }

    // MARK: - What gets skipped

    func testNonMarkdownFilesAreExcluded() throws {
        try write("README.md")
        try write("notes.txt")
        try write("diagram.png")
        try write("Makefile")

        XCTAssertEqual(paths(), ["README.md"])
    }

    func testHiddenFilesAndDirectoriesAreSkipped() throws {
        try write("README.md")
        try write(".config.md")
        try write(".hidden/secret.md")

        XCTAssertEqual(paths(), ["README.md"])
    }

    func testDependencyAndBuildDirectoriesArePruned() throws {
        try write("README.md")
        try write("node_modules/dep/readme.md")
        try write("Pods/lib/notes.md")
        try write("DerivedData/log.md")
        try write("vendor/thing/doc.md")

        XCTAssertEqual(paths(), ["README.md"])
    }

    func testAPrunedNameOnlyPrunesTheDirectoryNotAFileThatSharesIt() throws {
        // `build` is on the prune list as a directory. A note *called* build.md
        // is a file the reader wrote and must still be findable.
        try write("build.md")
        try write("build/output.md")

        XCTAssertEqual(paths(), ["build.md"])
    }

    // MARK: - Caps

    func testTheWalkStopsAtTheDepthCap() throws {
        try write("a.md")
        try write("one/b.md")
        try write("one/two/c.md")

        XCTAssertEqual(paths(maximumDepth: 2), ["a.md", "one/b.md"])
        XCTAssertEqual(paths(maximumDepth: 3), ["a.md", "one/b.md", "one/two/c.md"])
    }

    func testHittingTheFileCapReportsItself() throws {
        for index in 0..<5 {
            try write("note-\(index).md")
        }

        let capped = ProjectFileIndex.build(root: root, maximumFileCount: 3)
        XCTAssertEqual(capped.candidates.count, 3)
        XCTAssertTrue(capped.isTruncated)
    }

    func testAWalkThatReachesTheEndIsNotTruncated() throws {
        try write("README.md")

        XCTAssertFalse(ProjectFileIndex.build(root: root).isTruncated)
    }

    func testAnEmptyProjectIndexesToNothingRatherThanFailing() {
        let snapshot = ProjectFileIndex.build(root: root)
        XCTAssertTrue(snapshot.candidates.isEmpty)
        XCTAssertFalse(snapshot.isTruncated)
    }

    func testAMissingRootIndexesToNothingRatherThanFailing() {
        let missing = root.appending(path: "does-not-exist")
        XCTAssertTrue(ProjectFileIndex.build(root: missing).candidates.isEmpty)
    }

    // MARK: - Snapshot

    func testASnapshotPutsACandidateBackTogetherIntoAURL() throws {
        try write("docs/guide.md")
        let snapshot = ProjectFileIndex.build(root: root)

        XCTAssertEqual(snapshot.url(at: 0)?.standardizedFileURL,
                       root.appending(path: "docs/guide.md").standardizedFileURL)
        XCTAssertNil(snapshot.url(at: 1))
    }

    // MARK: - Caching

    func testAFreshCacheIsReusedRatherThanRewalked() async throws {
        try write("README.md")
        let clock = TestClock()
        let index = ProjectFileIndex(cacheLifetime: 5, now: clock.now)

        _ = await index.snapshot(for: root)
        try write("added.md")
        clock.advance(by: 4)

        let second = await index.snapshot(for: root)
        XCTAssertEqual(second.candidates.map(\.relativePath), ["README.md"])
    }

    func testAStaleCacheIsRebuilt() async throws {
        try write("README.md")
        let clock = TestClock()
        let index = ProjectFileIndex(cacheLifetime: 5, now: clock.now)

        _ = await index.snapshot(for: root)
        try write("added.md")
        clock.advance(by: 6)

        let second = await index.snapshot(for: root)
        XCTAssertEqual(second.candidates.map(\.relativePath).sorted(), ["README.md", "added.md"])
    }

    func testInvalidatingARootForcesARebuildBeforeTheCacheExpires() async throws {
        try write("README.md")
        let clock = TestClock()
        let index = ProjectFileIndex(cacheLifetime: 5, now: clock.now)

        _ = await index.snapshot(for: root)
        try write("added.md")
        await index.invalidate(root: root)

        let second = await index.snapshot(for: root)
        XCTAssertEqual(second.candidates.map(\.relativePath).sorted(), ["README.md", "added.md"])
    }

    func testDifferentRootsAreCachedSeparately() async throws {
        try write("README.md")
        let other = root.appending(path: "other", directoryHint: .isDirectory)
        try write("other/only-here.md")

        let index = ProjectFileIndex()
        let rootSnapshot = await index.snapshot(for: root)
        let otherSnapshot = await index.snapshot(for: other)

        XCTAssertEqual(rootSnapshot.candidates.map(\.relativePath).sorted(),
                       ["README.md", "other/only-here.md"])
        XCTAssertEqual(otherSnapshot.candidates.map(\.relativePath), ["only-here.md"])
    }

    func testConcurrentRequestsForOneRootShareASingleWalk() async throws {
        try write("README.md")
        let index = ProjectFileIndex()
        // Local copy: `self.root` would drag the test case into the tasks.
        let root = root!

        async let first = index.snapshot(for: root)
        async let second = index.snapshot(for: root)
        let snapshots = await [first, second]

        XCTAssertEqual(snapshots[0], snapshots[1])
    }
}

/// A clock the cache tests can move by hand, so nothing here sleeps.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += seconds
    }
}
