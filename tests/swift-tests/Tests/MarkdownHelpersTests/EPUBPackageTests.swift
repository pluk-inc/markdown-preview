import Foundation
import XCTest
@testable import MarkdownHelpers

/// Unpacks archives with the system `ditto`, an independent ZIP reader.
enum TestArchive {
    static func extract(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdp-epub-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("book.zip")
        try data.write(to: file)
        let contents = directory.appendingPathComponent("contents", isDirectory: true)
        // `unzip` on macOS mangles UTF-8 entry names; `ditto` honours them.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", file.path, contents.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "TestArchive", code: Int(ditto.terminationStatus))
        }
        return contents
    }

    static func files(in directory: URL) throws -> [String] {
        let root = directory.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.resolvingSymlinksInPath().path.dropFirst(root.count)) }
            .sorted()
    }
}

final class EPUBPackageTests: XCTestCase {
    func testArchiveRoundTripsStoredAndDeflatedEntries() throws {
        let text = Data(String(repeating: "Compressible text. ", count: 400).utf8)
        let noise = Data((0..<512).map { _ in UInt8.random(in: 0...255) })
        var writer = ZIPArchiveWriter()
        try writer.add(Data("first".utf8), at: "first", compression: .stored)
        try writer.add(text, at: "folder/text.txt")
        try writer.add(noise, at: "folder/ünïcode noise.bin")
        try writer.add(Data(), at: "empty")
        let archive = try writer.finish()
        XCTAssertLessThan(archive.count, text.count)

        let contents = try TestArchive.extract(archive)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent("first")), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent("folder/text.txt")), text)
        XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent("folder/ünïcode noise.bin")), noise)
        XCTAssertEqual(try Data(contentsOf: contents.appendingPathComponent("empty")), Data())
    }

    func testBookStartsWithUncompressedMediaType() throws {
        let archive = try makePackage().archiveData()
        // Readers identify an EPUB by these bytes at fixed offsets: a local
        // file header, then the name and the stored contents with no extra field.
        XCTAssertEqual(Array(archive.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Array(archive[8..<10]), [0, 0])
        XCTAssertEqual(Array(archive[28..<30]), [0, 0])
        XCTAssertEqual(String(decoding: archive[30..<58], as: UTF8.self), "mimetypeapplication/epub+zip")

        let contents = try TestArchive.extract(archive)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }
        XCTAssertEqual(try TestArchive.files(in: contents), [
            "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/images/picture.png", "OEBPS/nav.xhtml",
            "OEBPS/section-001.xhtml", "OEBPS/section-002.xhtml", "OEBPS/style.css", "mimetype",
        ])
        let container = try XMLDocument(contentsOf: contents.appendingPathComponent("META-INF/container.xml"))
        XCTAssertEqual(try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue,
                       "OEBPS/content.opf")
    }

    func testPackageDocumentDescribesTheBook() throws {
        let package = makePackage()
        let document = try XMLDocument(xmlString: package.packageDocument)
        func values(_ path: String) throws -> [String] {
            try document.nodes(forXPath: path).compactMap(\.stringValue)
        }
        XCTAssertEqual(try values("//*[local-name()='title']"), ["Tom & Jerry <Notes>"])
        XCTAssertEqual(try values("//*[local-name()='creator']"), ["Ada", "Grace"])
        XCTAssertEqual(try values("//*[local-name()='language']"), ["en-GB"])
        XCTAssertEqual(try values("//*[local-name()='identifier']"), ["urn:uuid:test"])
        XCTAssertEqual(try values("//*[local-name()='meta'][@property='dcterms:modified']"), ["2001-01-01T00:00:00Z"])
        XCTAssertEqual(try values("//*[local-name()='itemref']/@idref"), ["section-1", "section-2"])
        XCTAssertEqual(try values("//*[local-name()='item'][@properties='nav']/@href"), ["nav.xhtml"])
        XCTAssertEqual(try values("//*[local-name()='item'][@id='section-1']/@properties"), [])
        XCTAssertEqual(try values("//*[local-name()='item'][@id='section-2']/@properties"), ["mathml"])
        XCTAssertEqual(try values("//*[local-name()='item'][@media-type='image/png']/@href"), ["images/picture.png"])
        // Every spine entry and manifest href names a real file.
        let identifiers = Set(try values("//*[local-name()='item']/@id"))
        XCTAssertTrue(Set(try values("//*[local-name()='itemref']/@idref")).isSubset(of: identifiers))
    }

    func testNavigationNestsHeadingsInOneList() throws {
        var package = makePackage()
        package.headings = [
            .init(level: 2, title: "Preface", href: "section-001.xhtml#a"),
            .init(level: 1, title: "One & Only", href: "section-001.xhtml#b"),
            .init(level: 2, title: "Detail", href: "section-001.xhtml#c"),
            .init(level: 4, title: "Deep", href: "section-001.xhtml#d"),
            .init(level: 2, title: "", href: "section-001.xhtml#empty"),
            .init(level: 1, title: "Two", href: "section-002.xhtml#e"),
        ]
        let document = try XMLDocument(xmlString: package.navigationDocument)
        let nav = try XCTUnwrap(document.nodes(forXPath: "//*[local-name()='nav']").first as? XMLElement)
        // A table of contents is exactly one list; entries nest inside their
        // parent, and headings without text are left out.
        let lists = nav.elements(forName: "ol")
        XCTAssertEqual(lists.count, 1)
        func outline(_ list: XMLElement) -> String {
            list.elements(forName: "li").map { item in
                let link = item.elements(forName: "a").first
                let entry = (link?.stringValue ?? "?") + " " + (link?.attribute(forName: "href")?.stringValue ?? "?")
                return entry + item.elements(forName: "ol").map { " [" + outline($0) + "]" }.joined()
            }.joined(separator: ", ")
        }
        XCTAssertEqual(
            outline(try XCTUnwrap(lists.first)),
            "Preface section-001.xhtml#a, "
                + "One & Only section-001.xhtml#b [Detail section-001.xhtml#c [Deep section-001.xhtml#d]], "
                + "Two section-002.xhtml#e")
    }

    func testNavigationKeepsOneListPerEntryWhenHeadingLevelsAreSkipped() throws {
        var package = makePackage()
        package.headings = [
            .init(level: 1, title: "A", href: "a"), .init(level: 3, title: "B", href: "b"),
            .init(level: 2, title: "C", href: "c"), .init(level: 3, title: "D", href: "d"),
            .init(level: 1, title: "E", href: "e"),
        ]
        let document = try XMLDocument(xmlString: package.navigationDocument)
        // An entry may hold a single nested list: B and C share A's.
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='li'][count(*[local-name()='ol']) > 1]").count, 0)
        let top = try XCTUnwrap(document.nodes(forXPath: "//*[local-name()='nav']/*[local-name()='ol']").first as? XMLElement)
        func outline(_ list: XMLElement) -> String {
            list.elements(forName: "li").map { item in
                (item.elements(forName: "a").first?.stringValue ?? "?")
                    + item.elements(forName: "ol").map { "[" + outline($0) + "]" }.joined()
            }.joined(separator: " ")
        }
        XCTAssertEqual(outline(top), "A[B C[D]] E")
    }

    func testArchiveRejectsSectionsAReaderCouldNotOpen() throws {
        for broken in ["<article xmlns=\"http://www.w3.org/1999/xhtml\"><p>Unclosed</article>",
                       "<article xmlns=\"http://www.w3.org/1999/xhtml\"><a xlink:href=\"#x\">Unbound prefix</a></article>"] {
            var package = makePackage()
            package.sections[1].xhtml = broken
            XCTAssertThrowsError(try package.archiveData()) { error in
                guard case EPUBPackage.PackageError.malformedSection("section-002.xhtml") = error else {
                    return XCTFail("\(error)")
                }
            }
        }
    }

    func testBookWithoutHeadingsStillHasAContentsEntry() throws {
        var package = makePackage()
        package.headings = []
        let document = try XMLDocument(xmlString: package.navigationDocument)
        let links = try document.nodes(forXPath: "//*[local-name()='nav']//*[local-name()='a']")
        XCTAssertEqual(links.map(\.stringValue), ["Tom & Jerry <Notes>"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='nav']//*[local-name()='a']/@href")
            .map(\.stringValue), ["section-001.xhtml"])
    }

    func testStylesheetLeavesBodyTextToTheReaderAndResolvesCodeColours() {
        let css = EPUBPackage.stylesheet
        XCTAssertFalse(css.contains("var("))
        XCTAssertTrue(css.contains(".hljs-keyword"))
        XCTAssertTrue(css.contains("#9b2393"))
        XCTAssertNil(css.range(of: #"(^|\})\s*(html|body)\b"#, options: .regularExpression))
        XCTAssertFalse(css.contains("-apple-system"))
        // Indents and rules follow the text direction, as in the preview.
        for physical in ["padding-left", "border-left", "margin-right", "text-align: left"] {
            XCTAssertFalse(css.contains(physical), physical)
        }
        // Readers that left-align paragraphs themselves still set
        // right-to-left blocks from the right.
        XCTAssertTrue(css.contains(#"[dir="rtl"] { text-align: right; }"#))
    }

    func testContentDocumentIsWellFormedAndEscapesTheTitle() throws {
        let package = makePackage()
        let document = try XMLDocument(xmlString: package.contentDocument(for: package.sections[0]))
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='title']").first?.stringValue, "Start <here>")
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='link']/@href").first?.stringValue, "style.css")
        XCTAssertEqual(EPUBPackage.escape("a\u{0}b\u{C}c\td"), "abc\td")
    }

    private func makePackage() -> EPUBPackage {
        EPUBPackage(
            title: "Tom & Jerry <Notes>", authors: ["Ada", "Grace"], language: "en-GB",
            identifier: "urn:uuid:test", modified: Date(timeIntervalSinceReferenceDate: 0),
            sections: [
                .init(fileName: "section-001.xhtml", title: "Start <here>",
                      xhtml: "<article xmlns=\"http://www.w3.org/1999/xhtml\"><h1 id=\"a\">Start</h1></article>"),
                .init(fileName: "section-002.xhtml", title: "",
                      xhtml: "<article xmlns=\"http://www.w3.org/1999/xhtml\"><p>More</p></article>",
                      containsMath: true),
            ],
            headings: [.init(level: 1, title: "Start", href: "section-001.xhtml#a")],
            resources: [.init(path: "images/picture.png", mediaType: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))]
        )
    }
}
