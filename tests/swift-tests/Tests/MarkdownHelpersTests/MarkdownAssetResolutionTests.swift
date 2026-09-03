import XCTest
@testable import MarkdownHelpers

final class MarkdownAssetResolutionTests: XCTestCase {

    // MARK: baseHref(forFolder:)

    func testBaseHrefMirrorsFolderPathWithTrailingSlash() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        XCTAssertEqual(
            MarkdownAssetResolution.baseHref(forFolder: folder),
            "md-asset:///Users/me/notes/sub/"
        )
    }

    func testBaseHrefPercentEncodesSpecialCharacters() {
        let folder = URL(fileURLWithPath: "/Users/me/My Notes", isDirectory: true)
        XCTAssertEqual(
            MarkdownAssetResolution.baseHref(forFolder: folder),
            "md-asset:///Users/me/My%20Notes/"
        )
    }

    // MARK: fileURL(for:containedIn:)

    private let documentFolder = URL(fileURLWithPath: "/Users/me/notes", isDirectory: true)

    func testFileURLMapsAssetPathToAbsoluteFilePath() {
        let asset = URL(string: "md-asset:///Users/me/notes/img.png")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset, containedIn: documentFolder)?.path,
            "/Users/me/notes/img.png"
        )
    }

    func testFileURLDecodesPercentEncoding() {
        let folder = URL(fileURLWithPath: "/Users/me/My Notes", isDirectory: true)
        let asset = URL(string: "md-asset:///Users/me/My%20Notes/a%20b.md")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset, containedIn: folder)?.path,
            "/Users/me/My Notes/a b.md"
        )
    }

    /// `..` segments that stay inside the folder are still normalised away.
    func testFileURLStandardizesTraversalSegmentsThatStayInside() {
        let asset = URL(string: "md-asset:///Users/me/notes/sub/../img.png")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset, containedIn: documentFolder)?.path,
            "/Users/me/notes/img.png"
        )
    }

    func testFileURLResolvesNestedSubfolders() {
        let asset = URL(string: "md-asset:///Users/me/notes/images/deep/pic.png")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset, containedIn: documentFolder)?.path,
            "/Users/me/notes/images/deep/pic.png"
        )
    }

    func testFileURLRejectsRootAndEmptyPaths() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(
            for: URL(string: "md-asset:///")!, containedIn: documentFolder))
        XCTAssertNil(MarkdownAssetResolution.fileURL(
            for: URL(string: "md-asset://")!, containedIn: documentFolder))
    }

    func testFileURLRejectsNonEmptyHost() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(
            for: URL(string: "md-asset://example.com/etc/hosts")!, containedIn: documentFolder))
        XCTAssertNil(MarkdownAssetResolution.fileURL(
            for: URL(string: "md-asset://__vendor/katex.min.js")!, containedIn: documentFolder))
    }

    func testFileURLRejectsOtherSchemes() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(
            for: URL(string: "file:///etc/hosts")!, containedIn: documentFolder))
        XCTAssertNil(MarkdownAssetResolution.fileURL(
            for: URL(string: "https://example.com/a.md")!, containedIn: documentFolder))
    }

    // MARK: - Containment (security)
    //
    // Every path below is one a Markdown document can name on its own. The
    // app holds a read-only sandbox exception for the whole filesystem, so an
    // unbounded resolve is an arbitrary local file read with no interaction.

    /// Was `testParentRelativeLinkResolvesAgainstBaseHref`, which asserted the
    /// opposite: that `../` climbing out of the document folder resolved. It
    /// is now the primary regression test for the containment boundary.
    ///
    /// Widening the boundary by one level to make this pass again is the
    /// tempting fix and the wrong one — see the note on
    /// `MarkdownAssetResolution` for why a boundary derived from where the
    /// document happens to sit is not a boundary.
    func testParentRelativeLinkIsRejected() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        let base = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder))!
        let clicked = URL(string: "../sibling.md", relativeTo: base)!.absoluteURL
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: clicked, containedIn: folder))
    }

    func testDeepTraversalToSystemFileIsRejected() {
        let asset = URL(string: "md-asset:///Users/me/notes/../../../etc/passwd")!
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: asset, containedIn: documentFolder))
    }

    func testUnrelatedAbsolutePathIsRejected() {
        for path in ["/etc/hosts", "/Users/me/.ssh/id_rsa", "/Users/other/notes/img.png"] {
            let asset = URL(string: "md-asset://\(path)")!
            XCTAssertNil(
                MarkdownAssetResolution.fileURL(for: asset, containedIn: documentFolder),
                "\(path) resolved but lies outside the document folder"
            )
        }
    }

    /// A sibling directory sharing a name prefix is not a descendant. Without
    /// a trailing separator in the containment check, `/Users/me/notes` would
    /// also match `/Users/me/notes-private`.
    func testSiblingDirectoryWithSharedPrefixIsRejected() {
        let asset = URL(string: "md-asset:///Users/me/notes-private/secrets.png")!
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: asset, containedIn: documentFolder))
    }

    /// Real filesystem: a symlink inside the document folder pointing outside
    /// it must not become an escape hatch. A purely textual containment check
    /// passes this and hands back the target.
    func testSymlinkOutOfTheDocumentFolderIsRejected() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("md-asset-containment-\(UUID().uuidString)", isDirectory: true)
        let folder = temporary.appendingPathComponent("notes", isDirectory: true)
        let outside = temporary.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let escape = folder.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        let asset = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder)
            + "escape/secret.txt")!
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: asset, containedIn: folder))
    }

    /// The inverse of the symlink test: a symlinked *document folder* — which
    /// `/tmp` already is on macOS — must still resolve its own contents.
    func testSymlinkedDocumentFolderStillResolvesItsOwnFiles() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("md-asset-symlinked-\(UUID().uuidString)", isDirectory: true)
        let real = temporary.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let image = real.appendingPathComponent("pic.png")
        try Data("png".utf8).write(to: image)
        let linked = temporary.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        let asset = URL(string: MarkdownAssetResolution.baseHref(forFolder: linked) + "pic.png")!
        XCTAssertNotNil(MarkdownAssetResolution.fileURL(for: asset, containedIn: linked))
    }

    // MARK: End-to-end relative resolution

    func testSameFolderRelativeLinkResolvesAgainstBaseHref() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        let base = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder))!
        let clicked = URL(string: "images/pic.png", relativeTo: base)!.absoluteURL
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: clicked, containedIn: folder)?.path,
            "/Users/me/notes/sub/images/pic.png"
        )
    }

    // MARK: - Image storage helpers

    func testPicturesDirectoryUsesMarkdownStem() {
        let markdown = URL(fileURLWithPath: "/Users/me/notes/Trip Notes.md")
        XCTAssertEqual(
            MarkdownAssetResolution.picturesDirectory(forMarkdownFile: markdown).path,
            "/Users/me/notes/Trip Notes-pictures"
        )
    }

    func testNextIntegerFileNameReturnsOneForNonExistentDirectory() {
        let tempDir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        XCTAssertEqual(
            MarkdownAssetResolution.nextIntegerFileName(in: tempDir, extension: "png"),
            "1.png"
        )
    }

    func testNextIntegerFileNameReturnsOneForEmptyDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        XCTAssertEqual(
            MarkdownAssetResolution.nextIntegerFileName(in: tempDir, extension: "png"),
            "1.png"
        )
    }

    func testNextIntegerFileNameFindsNextAvailableNumber() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create existing files: 1.png, 2.png, 5.png
        for num in [1, 2, 5] {
            let file = tempDir.appendingPathComponent("\(num).png")
            try Data().write(to: file)
        }

        XCTAssertEqual(
            MarkdownAssetResolution.nextIntegerFileName(in: tempDir, extension: "png"),
            "6.png"
        )
    }

    func testNextIntegerFileNameIgnoresNonMatchingFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create files with different extensions and non-numeric names
        let files = ["1.png", "2.jpg", "abc.png", "10.png"]
        for file in files {
            try Data().write(to: tempDir.appendingPathComponent(file))
        }

        XCTAssertEqual(
            MarkdownAssetResolution.nextIntegerFileName(in: tempDir, extension: "png"),
            "11.png"
        )
    }

    func testRelativePathFromSameDirectory() {
        let source = URL(fileURLWithPath: "/Users/me/notes/doc.md")
        let dest = URL(fileURLWithPath: "/Users/me/notes/image.png")
        XCTAssertEqual(
            MarkdownAssetResolution.relativePath(from: source, to: dest),
            "image.png"
        )
    }

    func testRelativePathToSubdirectory() {
        let source = URL(fileURLWithPath: "/Users/me/notes/doc.md")
        let dest = URL(fileURLWithPath: "/Users/me/notes/assets/image.png")
        XCTAssertEqual(
            MarkdownAssetResolution.relativePath(from: source, to: dest),
            "assets/image.png"
        )
    }

    func testRelativePathToParentDirectory() {
        let source = URL(fileURLWithPath: "/Users/me/notes/sub/doc.md")
        let dest = URL(fileURLWithPath: "/Users/me/notes/image.png")
        XCTAssertEqual(
            MarkdownAssetResolution.relativePath(from: source, to: dest),
            "../image.png"
        )
    }

    func testRelativePathBetweenSiblingDirectories() {
        let source = URL(fileURLWithPath: "/Users/me/notes/drafts/doc.md")
        let dest = URL(fileURLWithPath: "/Users/me/notes/assets/image.png")
        XCTAssertEqual(
            MarkdownAssetResolution.relativePath(from: source, to: dest),
            "../assets/image.png"
        )
    }

    func testRelativePathAcrossMultipleLevels() {
        let source = URL(fileURLWithPath: "/Users/me/notes/sub/deep/doc.md")
        let dest = URL(fileURLWithPath: "/Users/me/images/pic.png")
        XCTAssertEqual(
            MarkdownAssetResolution.relativePath(from: source, to: dest),
            "../../../images/pic.png"
        )
    }

    func testRelativePathReturnsNilForNonFileURLs() {
        let source = URL(fileURLWithPath: "/Users/me/doc.md")
        let dest = URL(string: "https://example.com/image.png")!
        XCTAssertNil(MarkdownAssetResolution.relativePath(from: source, to: dest))
    }

    func testAtomicWriteCreatesFileWithData() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testData = Data("test content".utf8)
        let fileURL = tempDir.appendingPathComponent("test.txt")

        let written = try MarkdownAssetResolution.atomicWrite(testData, to: fileURL)
        XCTAssertEqual(written, fileURL)

        let readData = try Data(contentsOf: fileURL)
        XCTAssertEqual(readData, testData)
    }

    func testAtomicWriteCreatesIntermediateDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testData = Data("test content".utf8)
        let fileURL = tempDir
            .appendingPathComponent("sub1", isDirectory: true)
            .appendingPathComponent("sub2", isDirectory: true)
            .appendingPathComponent("test.txt")

        try MarkdownAssetResolution.atomicWrite(testData, to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let readData = try Data(contentsOf: fileURL)
        XCTAssertEqual(readData, testData)
    }

    func testAtomicWriteOverwritesExistingFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")

        // Write initial data
        let initialData = Data("initial".utf8)
        try initialData.write(to: fileURL)

        // Overwrite with new data
        let newData = Data("overwritten".utf8)
        try MarkdownAssetResolution.atomicWrite(newData, to: fileURL)

        let readData = try Data(contentsOf: fileURL)
        XCTAssertEqual(readData, newData)
    }

    func testSavePastedImageCreatesPicturesDirectoryAndRelativePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdown = root.appendingPathComponent("notes.md")
        let image = try MarkdownAssetResolution.savePastedImage(
            Data([0, 1, 2]),
            forMarkdownFile: markdown
        )

        XCTAssertEqual(image.lastPathComponent, "1.png")
        XCTAssertEqual(
            MarkdownAssetResolution.markdownPath(for: image, from: markdown),
            "notes-pictures/1.png"
        )
        XCTAssertEqual(try Data(contentsOf: image), Data([0, 1, 2]))
    }

    func testMarkdownPathEncodesUnbalancedParenthesesInFilenames() {
        let markdown = URL(fileURLWithPath: "/Users/me/notes.md")
        let image = URL(fileURLWithPath: "/Users/me/notes)-pictures/1.png")
        XCTAssertEqual(
            MarkdownAssetResolution.markdownPath(for: image, from: markdown),
            "notes%29-pictures/1.png"
        )
    }

    func testReplacingImagePathOnlyChangesInlineImageDestinations() {
        let markdown = "![one](notes-pictures/1.png)\n\n`notes-pictures/1.png`"
        XCTAssertEqual(
            MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: "notes-pictures/1.png",
                to: "notes-pictures/renamed.png"
            ),
            "![one](notes-pictures/renamed.png)\n\n`notes-pictures/1.png`"
        )
    }

    func testReplacingImagePathUpdatesEveryMatchingImageAndLiteralCharacters() {
        let markdown = "![one](notes/$draft-pictures/1.png)\n![two](<notes/$draft-pictures/1.png>)"
        XCTAssertEqual(
            MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: "notes/$draft-pictures/1.png",
                to: "notes/$draft-pictures/final.png"
            ),
            "![one](notes/$draft-pictures/final.png)\n![two](<notes/$draft-pictures/final.png>)"
        )
    }

    func testReplacingImagePathSupportsAngleDestinationWithSpaces() {
        let markdown = "![one](<notes-pictures/a b.png> \"caption\")"
        XCTAssertEqual(
            MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: "notes-pictures/a%20b.png",
                to: "notes-pictures/hero%20shot.png"
            ),
            "![one](<notes-pictures/hero%20shot.png> \"caption\")"
        )
    }

    func testReplacingImagePathSupportsEscapedClosingParenthesis() {
        let markdown = "![one](notes-pictures/a\\)b.png \"caption\")"
        XCTAssertEqual(
            MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: "notes-pictures/a%29b.png",
                to: "notes-pictures/hero%20shot.png"
            ),
            "![one](notes-pictures/hero%20shot.png \"caption\")"
        )
    }

    func testReplacingImagePathSupportsBalancedParentheses() {
        let markdown = "![one](notes-pictures/a(b).png \"caption\")"
        XCTAssertEqual(
            MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: "notes-pictures/a%28b%29.png",
                to: "notes-pictures/hero%20shot.png"
            ),
            "![one](notes-pictures/hero%20shot.png \"caption\")"
        )
    }

    func testReplacingImagePathDoesNotChangeCodeExamples() {
        let markdown = """
        ![real](notes-pictures/1.png)

        `![inline](notes-pictures/1.png)`

        ```markdown
        ![fenced](notes-pictures/1.png)
        ```

            ![indented](notes-pictures/1.png)
        """

        XCTAssertEqual(
            MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: "notes-pictures/1.png",
                to: "notes-pictures/renamed.png"
            ),
            """
            ![real](notes-pictures/renamed.png)

            `![inline](notes-pictures/1.png)`

            ```markdown
            ![fenced](notes-pictures/1.png)
            ```

                ![indented](notes-pictures/1.png)
            """
        )
    }
}
