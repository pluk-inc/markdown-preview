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

    // MARK: fileURL(for:)

    func testFileURLMapsAssetPathToAbsoluteFilePath() {
        let asset = URL(string: "md-asset:///Users/me/notes/img.png")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset)?.path,
            "/Users/me/notes/img.png"
        )
    }

    func testFileURLDecodesPercentEncoding() {
        let asset = URL(string: "md-asset:///Users/me/My%20Notes/a%20b.md")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset)?.path,
            "/Users/me/My Notes/a b.md"
        )
    }

    func testFileURLStandardizesTraversalSegments() {
        let asset = URL(string: "md-asset:///Users/me/notes/sub/../sibling.md")!
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: asset)?.path,
            "/Users/me/notes/sibling.md"
        )
    }

    func testFileURLRejectsRootAndEmptyPaths() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset:///")!))
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset://")!))
    }

    func testFileURLRejectsNonEmptyHost() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset://example.com/etc/hosts")!))
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "md-asset://__vendor/katex.min.js")!))
    }

    func testFileURLRejectsOtherSchemes() {
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "file:///etc/hosts")!))
        XCTAssertNil(MarkdownAssetResolution.fileURL(for: URL(string: "https://example.com/a.md")!))
    }

    // MARK: End-to-end relative resolution

    /// Mirrors what WebKit does with a relative href against the page
    /// `<base>`: a `../` link climbs into the parent folder and maps back to
    /// the right file — the behaviour the base-href design exists to enable.
    func testParentRelativeLinkResolvesAgainstBaseHref() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        let base = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder))!
        let clicked = URL(string: "../sibling.md", relativeTo: base)!.absoluteURL
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: clicked)?.path,
            "/Users/me/notes/sibling.md"
        )
    }

    func testSameFolderRelativeLinkResolvesAgainstBaseHref() {
        let folder = URL(fileURLWithPath: "/Users/me/notes/sub", isDirectory: true)
        let base = URL(string: MarkdownAssetResolution.baseHref(forFolder: folder))!
        let clicked = URL(string: "images/pic.png", relativeTo: base)!.absoluteURL
        XCTAssertEqual(
            MarkdownAssetResolution.fileURL(for: clicked)?.path,
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
