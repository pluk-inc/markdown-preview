import XCTest

@testable import MarkdownHelpers

/// Runs the real watcher against a temporary file: a save that deletes the
/// file and writes it again later must re-arm the watcher (#615).
@MainActor
final class FileWatcherTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("note.md")
        try "# v1\n".write(to: fileURL, atomically: false, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReloadsAfterFileIsDeletedAndRecreatedLater() async throws {
        var changes = 0
        let watcher = FileWatcher(url: fileURL) { changes += 1 }
        defer { watcher.cancel() }

        try FileManager.default.removeItem(at: fileURL)
        // Longer than the old single retry, so several retries fail first.
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(changes, 0)

        try "# v2\n".write(to: fileURL, atomically: false, encoding: .utf8)
        try await waitUntil { changes > 0 }
        let afterRecreate = changes

        // The watcher is armed on the new file: a later in-place write reloads.
        try "# v3\n".write(to: fileURL, atomically: false, encoding: .utf8)
        try await waitUntil { changes > afterRecreate }
    }

    func testCancelStopsPendingRetries() async throws {
        var changes = 0
        let watcher = FileWatcher(url: fileURL) { changes += 1 }

        try FileManager.default.removeItem(at: fileURL)
        try await Task.sleep(for: .milliseconds(400))
        watcher.cancel()

        try "# v2\n".write(to: fileURL, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(changes, 0)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                return XCTFail("condition not met within \(timeout)")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
