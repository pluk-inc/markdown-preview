import XCTest

@testable import MarkdownHelpers

final class FileWatcherMoveResolutionTests: XCTestCase {
    private let originalURL = URL(fileURLWithPath: "/tmp/README.md")
    private let backupURL = URL(fileURLWithPath: "/tmp/README.md~")

    func testReplacementAtOriginalPathWinsOverMovedInode() {
        let existing = Set([originalURL, backupURL])

        XCTAssertEqual(
            FileWatcherMoveResolution.resolve(
                originalURL: originalURL,
                movedURL: backupURL,
                fileExists: { existing.contains($0) }
            ),
            .reloadOriginal
        )
    }

    func testRenameIsFollowedWhenOriginalPathStaysAbsent() {
        XCTAssertEqual(
            FileWatcherMoveResolution.resolve(
                originalURL: originalURL,
                movedURL: backupURL,
                fileExists: { $0 == self.backupURL }
            ),
            .followRename(backupURL)
        )
    }

    func testDeleteWithoutMovedFileRemainsUnavailable() {
        XCTAssertEqual(
            FileWatcherMoveResolution.resolve(
                originalURL: originalURL,
                movedURL: nil,
                fileExists: { _ in false }
            ),
            .unavailable
        )
    }

    func testOriginalDescriptorPathIsNotTreatedAsRename() {
        XCTAssertEqual(
            FileWatcherMoveResolution.resolve(
                originalURL: originalURL,
                movedURL: originalURL,
                fileExists: { _ in false }
            ),
            .unavailable
        )
    }
}
