import XCTest
@testable import MarkdownHelpers

/// Which folder bounds a document's automatic asset loads, and how that
/// boundary changes as the reader opens folders and documents.
final class MarkdownAccessPolicyTests: XCTestCase {

    private let project = URL(fileURLWithPath: "/Users/me/project", isDirectory: true)
    private let docs = URL(fileURLWithPath: "/Users/me/project/docs", isDirectory: true)
    private let elsewhere = URL(fileURLWithPath: "/Users/me/other", isDirectory: true)

    // MARK: - Which folder bounds a document

    /// The case the review asked for: a project opened by the reader, and a
    /// document one level down reaching a sibling folder.
    func testOpenedFolderBoundsADocumentInsideIt() {
        XCTAssertEqual(
            MarkdownAccessPolicy.containmentRoot(documentFolder: docs, openedFolder: project),
            project
        )
    }

    func testDocumentOutsideTheOpenedFolderKeepsItsOwnFolder() {
        XCTAssertEqual(
            MarkdownAccessPolicy.containmentRoot(documentFolder: elsewhere, openedFolder: project),
            elsewhere
        )
    }

    func testWithoutAnOpenedFolderTheDocumentFolderBounds() {
        XCTAssertEqual(
            MarkdownAccessPolicy.containmentRoot(documentFolder: docs, openedFolder: nil),
            docs
        )
    }

    /// An unsaved document has no folder, so nothing may resolve.
    func testUnsavedDocumentHasNoBoundary() {
        XCTAssertNil(
            MarkdownAccessPolicy.containmentRoot(documentFolder: nil, openedFolder: project)
        )
    }

    /// `/Users/me/project-private` is a sibling, not a descendant. Sharing a
    /// name prefix must not put a document inside the opened folder.
    func testSiblingFolderWithSharedPrefixIsNotInsideTheOpenedFolder() {
        let sibling = URL(fileURLWithPath: "/Users/me/project-private", isDirectory: true)
        XCTAssertEqual(
            MarkdownAccessPolicy.containmentRoot(documentFolder: sibling, openedFolder: project),
            sibling
        )
    }

    // MARK: - The opened folder is dropped when the reader leaves it

    func testOpenedFolderSurvivesADocumentInsideIt() {
        XCTAssertEqual(
            MarkdownAccessPolicy.openedFolder(project, afterLoading: docs),
            project
        )
    }

    /// The file navigator re-roots at the same moment, so a boundary that
    /// stayed behind would be one nobody could see.
    func testOpenedFolderIsDroppedForADocumentOutsideIt() {
        XCTAssertNil(MarkdownAccessPolicy.openedFolder(project, afterLoading: elsewhere))
    }

    func testOpenedFolderIsDroppedForAnUnsavedDocument() {
        XCTAssertNil(MarkdownAccessPolicy.openedFolder(project, afterLoading: nil))
    }
}
