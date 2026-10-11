import AppKit
import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EPUBExportTests: XCTestCase {
    override class func setUp() {
        TestVendor.installHighlighterGrammar()
    }

    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    private let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"160\" height=\"50\"><rect width=\"160\" height=\"50\" fill=\"royalblue\"/></svg>"

    private var book: String {
        """
        ---
        title: Field Guide
        author: Ada Lovelace
        lang: en-GB
        ---

        # Field notes

        Intro with a [link to setup](#setup), a [neighbouring file](other.md),
        a [site](https://example.com) and a footnote[^1].

        ![Vector](data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString()))
        ![Pixel](data:image/png;base64,\(png))

        ## Setup

        - [ ] Open task
        - [x] Done task

        ```swift
        let message = "Hello"
        ```

        Inline math $E = mc^2$ here.

        ## Diagram

        ```mermaid
        flowchart LR
          A[Start] --> B[Finish]
        ```

        | Left | Right |
        | :--- | ---: |
        | a | b |

        ## Wrap-up

        Back to the [top](#field-notes) and a [dead end](#nowhere).

        [^1]: Footnote text.
        """
    }

    func testBookSplitsSectionsAndCarriesRenderedContent() async throws {
        let harness = makeHarness(markdown: book)
        defer { harness.close() }
        _ = try await harness.layout(texts: [], imageCount: 2, selectors: [".katex": 1])
        // An image the preview could not load either (the harness waits on real ones).
        _ = try await harness.webView.evaluateJavaScript("""
            document.querySelector('article p').insertAdjacentHTML('beforeend',
                '<img alt="Missing" src="md-asset:///nowhere/missing.png">'); 0
            """)
        let before = try await harness.webView.evaluateJavaScript("document.querySelector('article').outerHTML") as? String
        let contents = try await export(from: harness, markdown: book, name: "field-guide")
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        XCTAssertEqual(try TestArchive.files(in: contents), [
            "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/images/diagram-1.png",
            "OEBPS/images/image-1.svg", "OEBPS/images/image-2.png", "OEBPS/nav.xhtml",
            "OEBPS/section-001.xhtml", "OEBPS/section-002.xhtml", "OEBPS/section-003.xhtml",
            "OEBPS/section-004.xhtml", "OEBPS/style.css", "mimetype",
        ])
        let folder = contents.appendingPathComponent("OEBPS")
        func text(_ name: String) throws -> String {
            try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
        }
        let sections = try (1...4).map { try text("section-00\($0).xhtml") }
        for section in sections {
            // Readers reject anything that is not well-formed XML.
            XCTAssertNoThrow(try XMLDocument(xmlString: section))
            for preview in ["data-source", "<button", "<input", "<script", "md-code-header", "mermaid-hud",
                            "md-source-blank-line", "katex-html", " align=", "tabindex"] {
                XCTAssertFalse(section.contains(preview), preview)
            }
        }

        // Frontmatter stays visible, as in the other export formats, and names the book.
        XCTAssertTrue(sections[0].contains("md-frontmatter"))
        let package = try XMLDocument(xmlString: try text("content.opf"))
        func metadata(_ name: String) throws -> [String] {
            try package.nodes(forXPath: "//*[local-name()='\(name)']").compactMap(\.stringValue)
        }
        XCTAssertEqual(try metadata("title"), ["Field Guide"])
        XCTAssertEqual(try metadata("creator"), ["Ada Lovelace"])
        XCTAssertEqual(try metadata("language"), ["en-GB"])
        XCTAssertEqual(try package.nodes(forXPath: "//*[local-name()='itemref']").count, 4)
        XCTAssertEqual(try package.nodes(forXPath: "//*[local-name()='item'][@properties='mathml']/@href")
            .compactMap(\.stringValue), ["section-002.xhtml"])

        // Links follow their targets into other files; dead ones stop being links.
        XCTAssertTrue(sections[0].contains(#"<a href="section-002.xhtml#md-heading-1">link to setup</a>"#))
        XCTAssertTrue(sections[0].contains("<a>neighbouring file</a>"))
        XCTAssertTrue(sections[0].contains(#"<a href="https://example.com">site</a>"#))
        XCTAssertTrue(sections[0].contains(#"href="section-004.xhtml#fn-1""#))
        XCTAssertTrue(sections[3].contains(#"href="section-001.xhtml#fnref-1""#))
        XCTAssertTrue(sections[3].contains(#"<a href="section-001.xhtml#md-heading-0">top</a>"#))
        XCTAssertTrue(sections[3].contains("<a>dead end</a>"))

        // Images travel inside the book; one that cannot be read leaves its description.
        XCTAssertTrue(sections[0].contains(#"<img src="images/image-1.svg" alt="Vector""#))
        XCTAssertTrue(sections[0].contains(#"<img src="images/image-2.png" alt="Pixel""#))
        XCTAssertTrue(sections[0].contains("Missing"))
        XCTAssertFalse(sections[0].contains("md-asset"))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("images/image-2.png")),
                       Data(base64Encoded: png))

        XCTAssertTrue(sections[1].contains("\u{2610} "))
        XCTAssertTrue(sections[1].contains("\u{2611} "))
        XCTAssertTrue(sections[1].contains(#"<span class="hljs-keyword">let</span>"#))
        XCTAssertTrue(sections[1].contains(#"<math xmlns="http://www.w3.org/1998/Math/MathML">"#))
        XCTAssertFalse(sections[1].contains("annotation"))

        // The diagram becomes a picture drawn for a light page, shown at the
        // size Mermaid laid it out and stored at twice that.
        let width = try XCTUnwrap(sections[2].firstMatch(
            of: /<img src="images\/diagram-1\.png" alt="Mermaid diagram" width="(\d+)"/)?.1).flatMap { Int($0) }
        XCTAssertFalse(sections[2].contains("<svg"))
        let diagram = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: folder.appendingPathComponent("images/diagram-1.png"))))
        let displayWidth = try XCTUnwrap(width)
        XCTAssertTrue((200...330).contains(displayWidth), "\(displayWidth)")
        XCTAssertEqual(Double(diagram.pixelsWide), Double(displayWidth * 2), accuracy: 3)
        XCTAssertEqual(Double(diagram.pixelsWide) / Double(diagram.pixelsHigh), 263.0 / 70, accuracy: 0.3)
        // Whole and uncropped: a light margin all round, with ink inside it.
        var darkest: CGFloat = 1
        for x in stride(from: 0, to: diagram.pixelsWide, by: 3) {
            for y in stride(from: 0, to: diagram.pixelsHigh, by: 3) {
                let brightness = try XCTUnwrap(diagram.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).brightnessComponent
                let onEdge = x < 3 || y < 3 || x >= diagram.pixelsWide - 3 || y >= diagram.pixelsHigh - 3
                if onEdge { XCTAssertGreaterThan(brightness, 0.95, "edge \(x),\(y)") }
                darkest = min(darkest, brightness)
            }
        }
        XCTAssertLessThan(darkest, 0.5)
        XCTAssertTrue(sections[2].contains("text-align: right"))

        let navigation = try text("nav.xhtml")
        XCTAssertNoThrow(try XMLDocument(xmlString: navigation))
        for entry in [#"<a href="section-001.xhtml#md-heading-0">Field notes</a>"#,
                      #"<a href="section-002.xhtml#md-heading-1">Setup</a>"#,
                      #"<a href="section-003.xhtml#md-heading-2">Diagram</a>"#,
                      #"<a href="section-004.xhtml#md-heading-3">Wrap-up</a>"#] {
            XCTAssertTrue(navigation.contains(entry), entry)
        }

        let after = try await harness.webView.evaluateJavaScript("document.querySelector('article').outerHTML") as? String
        XCTAssertEqual(after, before)
    }

    func testDocumentWithoutRepeatedHeadingsIsOneSectionNamedAfterItsHeading() async throws {
        let markdown = """
        Opening words.

        ## Only heading

        Body with a control\u{C}character and <span xlink:title="stray prefix">raw HTML</span>.

        | A | B | C | D | E | F |
        | --- | --- | --- | --- | --- | --- |
        | 1 | 2 | 3 | 4 | 5 | 6 |

        | Narrow | Table |
        | --- | --- |
        | 1 | 2 |
        """
        let harness = makeHarness(markdown: markdown)
        defer { harness.close() }
        _ = try await harness.layout(texts: ["Opening words."], imageCount: 0)
        let contents = try await export(from: harness, markdown: markdown, name: "single")
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        let folder = contents.appendingPathComponent("OEBPS")
        XCTAssertEqual(try TestArchive.files(in: contents).filter { $0.contains("section-") }, ["OEBPS/section-001.xhtml"])
        XCTAssertNoThrow(try XMLDocument(contentsOf: folder.appendingPathComponent("section-001.xhtml")))
        // Only tables with many columns are set in smaller type to fit a page.
        let section = try String(contentsOf: folder.appendingPathComponent("section-001.xhtml"), encoding: .utf8)
        XCTAssertEqual(section.components(separatedBy: "<table").count - 1, 2)
        XCTAssertEqual(section.components(separatedBy: #"<table class="md-many-columns">"#).count - 1, 1)
        let package = try XMLDocument(contentsOf: folder.appendingPathComponent("content.opf"))
        XCTAssertEqual(try package.nodes(forXPath: "//*[local-name()='title']").first?.stringValue, "Only heading")
        XCTAssertEqual(try package.nodes(forXPath: "//*[local-name()='language']").first?.stringValue, "en")
    }

    func testUntitledDocumentUsesTheFileName() async throws {
        let harness = makeHarness(markdown: "Just a paragraph.")
        defer { harness.close() }
        _ = try await harness.layout(texts: ["Just a paragraph."], imageCount: 0)
        let contents = try await export(from: harness, markdown: "Just a paragraph.", name: "untitled")
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        let folder = contents.appendingPathComponent("OEBPS")
        let package = try XMLDocument(contentsOf: folder.appendingPathComponent("content.opf"))
        XCTAssertEqual(try package.nodes(forXPath: "//*[local-name()='title']").first?.stringValue, "File name")
        let navigation = try String(contentsOf: folder.appendingPathComponent("nav.xhtml"), encoding: .utf8)
        XCTAssertTrue(navigation.contains(#"<a href="section-001.xhtml">File name</a>"#))
    }

    func testMetadataComesFromFrontmatterThenTheText() {
        let declared = EPUBExport.metadata(from: """
            ---
            Title: "Quoted: title"
            authors: [Ada, Grace]
            language: ja
            ---
            English body text that would otherwise decide the language.
            """)
        XCTAssertEqual(declared, .init(title: "Quoted: title", authors: ["Ada", "Grace"], language: "ja"))

        let detected = EPUBExport.metadata(from: """
            ---
            lang: not a language
            ---
            Ceci est un document entièrement rédigé en français, avec assez de mots pour le reconnaître.
            """)
        XCTAssertEqual(detected, .init(title: nil, authors: [], language: "fr"))
    }

    func testImagesLoadFromDocumentFilesAndUnsupportedFormatsBecomePNG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdp-epub-images-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pixel = try XCTUnwrap(Data(base64Encoded: png))
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: pixel)?.representation(using: .tiff, properties: [:]))
        try pixel.write(to: directory.appendingPathComponent("pixel.png"))
        try tiff.write(to: directory.appendingPathComponent("scan image.tiff"))
        try Data("not an image".utf8).write(to: directory.appendingPathComponent("notes.png"))

        let base = MarkdownAssetResolution.baseHref(forFolder: directory)
        let sources = ["pixel.png", "scan%20image.tiff", "notes.png", "absent.png"].map { base + $0 }
        let images = await EPUBExport.loadImages(sources + ["ftp://example.com/a.png"])

        XCTAssertEqual(images[sources[0]]?.data, pixel)
        XCTAssertEqual(images[sources[0]]?.mediaType, "image/png")
        XCTAssertEqual(images[sources[1]]?.mediaType, "image/png")
        XCTAssertEqual(images[sources[1]]?.data.prefix(4), pixel.prefix(4))
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(EPUBExport.image(from: Data(svg.utf8))?.fileExtension, "svg")
        XCTAssertEqual(EPUBExport.image(from: Data([0xFF, 0xD8, 0xFF, 0xE0]))?.mediaType, "image/jpeg")
        // An error page with an inline icon is not an SVG image.
        XCTAssertNil(EPUBExport.image(from: Data("<!DOCTYPE html><html><body>\(svg)</body></html>".utf8)))
    }

    private func makeHarness(markdown: String) -> WebViewLayoutHarness {
        _ = NSApplication.shared
        // A dark preview: the book must not inherit its page or diagram colours.
        let html = MarkdownHTML.render(markdown: markdown, allowsScroll: true, vendorLoading: .inline,
                                       colorScheme: .dark).html
        return WebViewLayoutHarness(html: appLikeMermaidStart(html), width: 900, isEditor: false, height: 600)
    }

    /// The app loads Mermaid after the page's load event, so Mermaid's own
    /// start-on-load pass never runs there and every diagram goes through the
    /// preview's renderer. This inline test page loads it earlier; switch that
    /// pass off so diagrams take the same path as in the app.
    private func appLikeMermaidStart(_ html: String) -> String {
        guard let end = html.range(of: "</body>", options: .backwards) else { return html }
        return html.replacingCharacters(
            in: end, with: "<script>window.mermaid && (mermaid.startOnLoad = false);</script></body>")
    }

    private func export(from harness: WebViewLayoutHarness, markdown: String, name: String) async throws -> URL {
        let session = try await DocumentExportSession.capture(from: harness.webView)
        defer { session.close() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".epub")
        defer { try? FileManager.default.removeItem(at: url) }
        try await session.writeEPUB(to: url, markdown: markdown, fallbackTitle: "File name")
        let data = try Data(contentsOf: url)
        if let path = ProcessInfo.processInfo.environment["MDP_EPUB_ARTIFACTS"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".epub"))
        }
        return try TestArchive.extract(data)
    }
}
