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
    private var jpeg: String {
        let pixels = NSBitmapImageRep(data: Data(base64Encoded: png)!)!
        return pixels.representation(using: .jpeg, properties: [:])!.base64EncodedString()
    }
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

        Inline math $E = mc^2$ here, with spacing $a \\, b$ and $a \\! b$.

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
        _ = try await harness.layout(texts: [], imageCount: 2, selectors: [".katex": 3])
        // An image the preview could not load either (the harness waits on real ones).
        _ = try await harness.webView.evaluateJavaScript("""
            document.querySelector('article p').insertAdjacentHTML('beforeend',
                '<img alt="Missing" src="md-asset:///nowhere/missing.png">'); 0
            """)
        let before = try await harness.webView.evaluateJavaScript("document.querySelector('article').outerHTML") as? String
        let contents = try await export(from: harness, markdown: book, name: "field-guide")
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        XCTAssertEqual(try TestArchive.files(in: contents), [
            "META-INF/container.xml", "OEBPS/content.opf", "OEBPS/images/image-1.png",
            "OEBPS/images/image-2.png", "OEBPS/images/image-3.png", "OEBPS/nav.xhtml",
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

        // Pictures are stored as the preview drew them, at twice the size
        // shown; an image the preview could not load leaves its description.
        XCTAssertTrue(sections[0].contains(#"<img src="images/image-1.png" alt="Vector" width="160""#))
        XCTAssertTrue(sections[0].contains(#"<img src="images/image-2.png" alt="Pixel""#))
        XCTAssertTrue(sections[0].contains("Missing"))
        XCTAssertFalse(sections[0].contains("md-asset"))
        let vector = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: folder.appendingPathComponent("images/image-1.png"))))
        XCTAssertEqual([vector.pixelsWide, vector.pixelsHigh], [320, 100])
        let blue = try XCTUnwrap(vector.colorAt(x: 160, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(blue.blueComponent, 0.7)
        XCTAssertLessThan(blue.redComponent, 0.45)

        XCTAssertTrue(sections[1].contains("\u{2610} "))
        XCTAssertTrue(sections[1].contains("\u{2611} "))
        XCTAssertTrue(sections[1].contains(#"<span class="hljs-keyword">let</span>"#))
        XCTAssertTrue(sections[1].contains(#"<math xmlns="http://www.w3.org/1998/Math/MathML">"#))
        XCTAssertFalse(sections[1].contains("annotation"))
        // MathML holds text only in token elements; KaTeX's loose spacing
        // characters are kept in <mtext>.
        XCTAssertTrue(sections[1].contains("<mi>a</mi><mtext>\u{2009}</mtext><mi>b</mi>"))
        let loose = try XMLDocument(xmlString: sections[1]).nodes(forXPath: """
            //*[local-name()='math']/descendant-or-self::*
               [not(local-name()='mi' or local-name()='mn' or local-name()='mo'
                    or local-name()='ms' or local-name()='mtext')]/text()
            """)
        XCTAssertEqual(loose.count, 0)

        // The diagram becomes a picture drawn for a light page, shown at the
        // size Mermaid laid it out and stored at twice that.
        let width = try XCTUnwrap(sections[2].firstMatch(
            of: /<img src="images\/image-3\.png" alt="Mermaid diagram" width="(\d+)"/)?.1).flatMap { Int($0) }
        XCTAssertFalse(sections[2].contains("<svg"))
        let diagram = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: folder.appendingPathComponent("images/image-3.png"))))
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

        שלום עולם, a right-to-left paragraph.

        ![Photo](data:image/jpeg;base64,\(jpeg))

        <img src="data:image/png;base64,\(png)" width="0" height="0" alt="Unseen">

        <svg width="40" height="20" aria-label="Badge"><image href="https://example.com/beacon.png" width="40" height="20"/><rect width="40" height="20" fill="royalblue"/></svg>

        <table background="https://example.com/beacon.png"><tr><td>Cell</td></tr></table>

        | A | B | C | D | E | F |
        | --- | --- | --- | --- | --- | --- |
        | 1 | 2 | 3 | 4 | 5 | 6 |

        | Narrow | Table |
        | --- | --- |
        | 1 | 2 |
        """
        let harness = makeHarness(markdown: markdown)
        defer { harness.close() }
        _ = try await harness.layout(texts: ["Opening words."], imageCount: 2)
        let contents = try await export(from: harness, markdown: markdown, name: "single")
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        let folder = contents.appendingPathComponent("OEBPS")
        XCTAssertEqual(try TestArchive.files(in: contents).filter { $0.contains("section-") }, ["OEBPS/section-001.xhtml"])
        XCTAssertNoThrow(try XMLDocument(contentsOf: folder.appendingPathComponent("section-001.xhtml")))
        // Only tables with many columns are set in smaller type to fit a page.
        let section = try String(contentsOf: folder.appendingPathComponent("section-001.xhtml"), encoding: .utf8)
        XCTAssertEqual(section.components(separatedBy: "<table").count - 1, 3)
        XCTAssertEqual(section.components(separatedBy: #"<table class="md-many-columns">"#).count - 1, 1)
        // Text direction travels with the block it was inferred for.
        XCTAssertTrue(section.contains(#"<p dir="rtl">שלום עולם"#))

        // A book made from someone else's document carries only what the
        // preview showed, and never reaches for the network when opened.
        let files = try TestArchive.files(in: contents).filter { $0.contains("/images/") }
        XCTAssertEqual(files, ["OEBPS/images/image-1.jpg", "OEBPS/images/image-2.png"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("images/image-1.jpg")).prefix(3),
                       Data([0xFF, 0xD8, 0xFF]))
        XCTAssertTrue(section.contains(#"<img src="images/image-1.jpg" alt="Photo""#))
        XCTAssertTrue(section.contains(#"<img src="images/image-2.png" alt="Badge" width="40""#))
        for absent in ["Unseen", "<svg", "<image", "example.com", "background=", "xlink"] {
            XCTAssertFalse(section.contains(absent), absent)
        }
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

    func testLinksResolveAsInThePreview() async throws {
        let markdown = """
        # Guide

        [third](#setup-1-1), [second](#setup-1), [start](#), [up](#top), [nowhere](#missing)

        ## Setup

        ## Setup

        ## Setup-1
        """
        let harness = makeHarness(markdown: markdown)
        defer { harness.close() }
        _ = try await harness.layout(texts: ["Guide"], imageCount: 0)
        let contents = try await export(from: harness, markdown: markdown, name: "links")
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        let section = try String(contentsOf: contents.appendingPathComponent("OEBPS/section-001.xhtml"), encoding: .utf8)
        // Repeated headings take GitHub's suffixes: `Setup`, `Setup` and
        // `Setup-1` are `setup`, `setup-1` and `setup-1-1`.
        XCTAssertTrue(section.contains(#"<a href="section-003.xhtml#md-heading-2">second</a>"#), section)
        XCTAssertTrue(section.contains(#"<a href="section-004.xhtml#md-heading-3">third</a>"#), section)
        XCTAssertTrue(section.contains(#"<a href="section-001.xhtml">start</a>"#), section)
        XCTAssertTrue(section.contains(#"<a href="section-001.xhtml">up</a>"#), section)
        XCTAssertTrue(section.contains("<a>nowhere</a>"), section)
    }

    func testPicturesBesideTheDocumentAreEmbedded() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdp epub " + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("pictures"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(svg.utf8).write(to: folder.appendingPathComponent("pictures/local.svg"))

        // The page finds the file as it does in the app: relative to a base
        // that names the document's folder, through the `md-asset` scheme.
        let markdown = "Words.\n\n![Local](pictures/local.svg)\n"
        let files = LocalFiles()
        let harness = makeHarness(markdown: markdown, folder: folder, assetHandler: files)
        defer { harness.close() }
        _ = try await harness.layout(texts: ["Words."], imageCount: 1)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(files, forURLScheme: MarkdownAssetResolution.scheme)
        let contents = try await export(from: harness, markdown: markdown, name: "local", configuration: configuration)
        defer { try? FileManager.default.removeItem(at: contents.deletingLastPathComponent()) }

        let book = contents.appendingPathComponent("OEBPS")
        let section = try String(contentsOf: book.appendingPathComponent("section-001.xhtml"), encoding: .utf8)
        XCTAssertTrue(section.contains(#"<img src="images/image-1.png" alt="Local" width="160""#), section)
        XCTAssertFalse(section.contains("md-asset"))
        let picture = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: book.appendingPathComponent("images/image-1.png"))))
        XCTAssertEqual([picture.pixelsWide, picture.pixelsHigh], [320, 100])
        let blue = try XCTUnwrap(picture.colorAt(x: 160, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(blue.blueComponent, 0.7)
        XCTAssertLessThan(blue.redComponent, 0.45)
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

        func language(declared: String) -> String {
            EPUBExport.metadata(from: "---\nlang: \(declared)\n---\nCeci est un document entièrement rédigé en français.").language
        }
        // A locale identifier is read as the tag it stands for.
        XCTAssertEqual(language(declared: "en_GB"), "en-GB")
        for tag in ["zh-Hans-CN", "de-CH-1901", "de-DE-u-co-phonebk", "en-x-a"] {
            XCTAssertEqual(language(declared: tag), tag)
        }
        // A lone letter with nothing after it is not a tag.
        for malformed in ["en-x", "en-a", "en-GB-u"] {
            XCTAssertEqual(language(declared: malformed), "fr", malformed)
        }
    }

    private func makeHarness(markdown: String, folder: URL? = nil,
                             assetHandler: WKURLSchemeHandler? = nil) -> WebViewLayoutHarness {
        _ = NSApplication.shared
        // A dark preview: the book must not inherit its page or diagram colours.
        let html = MarkdownHTML.render(markdown: markdown, allowsScroll: true,
                                       assetBaseHref: folder.map(MarkdownAssetResolution.baseHref(forFolder:)),
                                       vendorLoading: .inline, colorScheme: .dark).html
        return WebViewLayoutHarness(html: appLikeMermaidStart(html), width: 900, isEditor: false, height: 600,
                                    schemeHandlers: assetHandler.map { [MarkdownAssetResolution.scheme: $0] } ?? [:])
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

    private func export(from harness: WebViewLayoutHarness, markdown: String, name: String,
                        configuration: WKWebViewConfiguration = WKWebViewConfiguration()) async throws -> URL {
        let session = try await DocumentExportSession.capture(from: harness.webView, configuration: configuration)
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

/// Stands in for the app's `md-asset` handler, which is not part of this
/// test target: serves the file a request's path names.
private final class LocalFiles: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let file = MarkdownAssetResolution.fileURL(for: url),
              let data = try? Data(contentsOf: file) else {
            return urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
        let type = file.pathExtension == "svg" ? "image/svg+xml" : "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: data.count,
                                             textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
