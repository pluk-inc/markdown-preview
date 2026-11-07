import XCTest

@testable import MarkdownHelpers

final class FileWatcherMoveResolutionTests: XCTestCase {
    private let originalURL = URL(fileURLWithPath: "/tmp/README.md")
    private let backupURL = URL(fileURLWithPath: "/tmp/README.md~")

    func testReplacementAtOriginalPathWinsOverMovedInode() {
        let existing = Set([originalURL, backupURL])

        XCTAssertEqual(
            FileWatcherMoveResolution.renameTarget(
                originalURL: originalURL,
                movedURL: backupURL,
                fileExists: { existing.contains($0) }
            ),
            nil
        )
    }

    func testRenameIsFollowedWhenOriginalPathStaysAbsent() {
        XCTAssertEqual(
            FileWatcherMoveResolution.renameTarget(
                originalURL: originalURL,
                movedURL: backupURL,
                fileExists: { $0 == self.backupURL }
            ),
            backupURL
        )
    }

    func testDeleteWithoutMovedFileKeepsOriginalPath() {
        XCTAssertEqual(
            FileWatcherMoveResolution.renameTarget(
                originalURL: originalURL,
                movedURL: nil,
                fileExists: { _ in false }
            ),
            nil
        )
    }

    func testOriginalDescriptorPathIsNotTreatedAsRename() {
        // Missing on the first check, present after: only the same-path
        // rule keeps the original path from being returned as the target.
        var checks = 0
        XCTAssertNil(
            FileWatcherMoveResolution.renameTarget(
                originalURL: originalURL,
                movedURL: originalURL,
                fileExists: { _ in
                    checks += 1
                    return checks > 1
                }
            )
        )
    }

    func testReopenDelayStartsShortAndBacksOffToOneSecond() {
        XCTAssertEqual(FileWatcherMoveResolution.reopenDelay(attempt: 0), 0.05, accuracy: 0.0001)
        XCTAssertEqual(FileWatcherMoveResolution.reopenDelay(attempt: 1), 0.10, accuracy: 0.0001)
        XCTAssertEqual(FileWatcherMoveResolution.reopenDelay(attempt: 4), 0.80, accuracy: 0.0001)
        XCTAssertEqual(FileWatcherMoveResolution.reopenDelay(attempt: 5), 1.0)
        XCTAssertEqual(FileWatcherMoveResolution.reopenDelay(attempt: 500), 1.0)
    }
}
