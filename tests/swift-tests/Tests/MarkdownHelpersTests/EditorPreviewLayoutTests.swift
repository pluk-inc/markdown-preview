import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class EditorPreviewLayoutTests: XCTestCase {
    struct Fixture {
        let name: String
        let markdown: String
        let texts: [String]
        var imageCount = 0
        var editorImageCount: Int? = nil
        var readSelectors: [String: Int] = [:]
        var editorSelectors: [String: Int] = [:]
        var readBoxes: [String: String] = [:]
        var editorBoxes: [String: String] = [:]
        var styles: [String: [String: String]] = [:]
        var editorSourceSnippets: [String] = []
        /// A documented source-editing contract, not a claim of visual parity.
        var sourceRepresentationReason: String? = nil
        /// Shared text still has to match horizontally and within each block.
        var localParityTexts: [String] = []
        var height: CGFloat = 1800
    }

    var image: String {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="80">
        <rect width="240" height="80" fill="royalblue"/></svg>
        """
        return "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
    }

    func testParagraphAndHeadingAlignment() async throws {
        try await check(Fixture(name: "paragraphs-headings", markdown: """
            # First heading

            First paragraph.

            ## Second heading

            Second paragraph.

            Setext heading
            --------------

            Final paragraph.
            """, texts: ["First heading", "First paragraph.", "Second heading", "Second paragraph.",
                           "Setext heading", "Final paragraph."]))
    }

    func testImageAlignmentAndSpacingBeforeAndAfterImages() async throws {
        try await check(Fixture(name: "images", markdown: """
            Before first image.

            ![First](\(image))

            After first image.

            ![Second](\(image))

            After second image.

            Final paragraph.
            """, texts: ["Before first image.", "After first image.", "After second image.", "Final paragraph."],
            imageCount: 2))
    }

    func testLinkedImageAlignment() async throws {
        try await check(Fixture(name: "linked-image", markdown: """
            Before linked image.

            [![Linked](\(image))](https://example.com)

            After linked image.
            """, texts: ["Before linked image.", "After linked image."], imageCount: 1))
    }

    func testWrappedParagraphAlignment() async throws {
        let paragraph = "This paragraph is deliberately long enough to wrap across several lines in a narrow window, so the test checks line breaks and the alignment of every rendered line."
        try await check(Fixture(name: "wrapping", markdown: "\(paragraph)\n\nFollowing paragraph.",
                               texts: [paragraph, "Following paragraph."]))
    }

    func testWrappedInlineCodeKeepsPaddingOnEveryLine() async throws {
        let code = String(repeating: "asdadd-asd-", count: 24)
        try await check(Fixture(
            name: "wrapped-inline-code-padding",
            markdown: "Before code.\n\n`\(code)`\n\nAfter code.",
            texts: ["Before code.", code, "After code."]))
    }

    func testQuotePaddingAcrossWrappedAndHardBreakLines() async throws {
        try await check(Fixture(name: "quote-edges", markdown: """
            Before quotation.

            > This quoted paragraph is long enough to wrap in the narrow viewport and must receive padding only at the start and end of the block.\("  ")
            > Second quoted line.
            ## Following heading

            After quotation.
            """, texts: ["Before quotation.", "This quoted paragraph is long enough to wrap in the narrow viewport and must receive padding only at the start and end of the block.",
                           "Second quoted line.", "Following heading", "After quotation."]))
    }

    func testOversizedImageResizesWithTheContentColumn() async throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"300\"><rect width=\"1200\" height=\"300\" fill=\"royalblue\"/></svg>"
        let source = "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
        try await check(Fixture(name: "oversized-image", markdown: "Before large image.\n\n![Large](\(source))\n\nAfter large image.",
                               texts: ["Before large image.", "After large image."], imageCount: 1))
    }

    func testListAndQuoteAlignment() async throws {
        try await check(Fixture(name: "lists-quotes", markdown: """
            Intro paragraph.

            - First bullet
            - Second bullet

            1. First ordered item
            2. Second ordered item

            > Quoted paragraph.

            Closing paragraph.
            """, texts: ["Intro paragraph.", "First bullet", "Second bullet", "First ordered item",
                           "Second ordered item", "Quoted paragraph.", "Closing paragraph."]))
    }

    func testQuoteAtDocumentStart() async throws {
        try await check(Fixture(name: "leading-quote", markdown: "> Opening quotation.\n> Continuing the same paragraph.\n\nAfter quotation.",
                               texts: ["Opening quotation.", "Continuing the same paragraph.", "After quotation."]))
    }

    func testAlignmentAfterReplacingMarkdownAndResizing() async throws {
        let initial = Fixture(name: "initial", markdown: "Original paragraph.", texts: ["Original paragraph."])
        let updated = Fixture(name: "updated-and-resized", markdown: """
            # Updated heading

            Before inserted image.

            ![Inserted](\(image))

            After inserted image.
            """, texts: ["Updated heading", "Before inserted image.", "After inserted image."], imageCount: 1)
        try await check(updated, updatingFrom: initial)
    }

    func check(_ fixture: Fixture, updatingFrom initial: Fixture? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let editorScript = try TestVendor.script("md-preview/Vendor/CodeMirror/mdedit.min.js")
        TestVendor.installHighlighterGrammar()
        let mermaid = fixture.markdown.contains("```mermaid")
            ? try TestVendor.script("md-preview/Vendor/Mermaid/mermaid.min.js") : nil
        let zoom = try XCTUnwrap(Double(ProcessInfo.processInfo.environment["MDP_LAYOUT_ZOOM"] ?? "1"))
        guard zoom > 0 else { throw WebViewLayoutHarness.Failure("Page zoom must be positive") }
        for (width, fullWidth, pageScrolling) in [
            (CGFloat(500), false, false), (900, false, true),
            (1280, false, true), (1280, true, true)
        ] {
            let name = "\(fixture.name)-\(Int(width))-\(fullWidth ? "full" : "normal")-zoom\(zoom)"
            let readerHTML = MarkdownHTML.render(
                markdown: fixture.markdown, allowsScroll: true,
                contentWidth: fullWidth ? .full : .centered,
                documentFont: .system, readerLayout: ReaderLayoutSetting(),
                pageTopClearance: pageScrolling ? MarkdownHTML.appPageTopClearance : 0
            ).html
            let editorHTML = EditorHTML.render(
                markdown: (initial ?? fixture).markdown, editorJavaScript: editorScript,
                mermaidJavaScript: mermaid,
                configuration: .init(fullWidth: fullWidth, usesPageScrolling: pageScrolling)
            )
            let reader = WebViewLayoutHarness(html: readerHTML, width: width, isEditor: false, zoom: zoom, height: fixture.height)
            let editor = WebViewLayoutHarness(html: editorHTML, width: initial == nil ? width : 1100,
                                              isEditor: true, zoom: zoom, height: fixture.height)
            defer { reader.close(); editor.close() }
            var readLayout: WebViewLayoutHarness.Layout?
            var editLayout: WebViewLayoutHarness.Layout?
            do {
                if let initial {
                    _ = try await editor.layout(texts: initial.texts, imageCount: initial.imageCount)
                    editor.webView.setFrameSize(CGSize(width: width, height: 1800))
                    _ = try await editor.webView.callAsyncJavaScript(
                        "window.__mdEditor.replaceMarkdown(markdown)",
                        arguments: ["markdown": fixture.markdown], in: nil, contentWorld: .page
                    )
                }
                readLayout = try await reader.layout(texts: fixture.texts, imageCount: fixture.imageCount,
                                                     selectors: fixture.readSelectors, boxes: fixture.readBoxes, styles: fixture.styles)
                editLayout = try await editor.layout(texts: fixture.texts,
                                                     imageCount: fixture.editorImageCount ?? fixture.imageCount,
                                                     selectors: fixture.editorSelectors, boxes: fixture.editorBoxes, styles: fixture.styles,
                                                     sourceSnippets: fixture.editorSourceSnippets)
                let source = try await editor.webView.evaluateJavaScript("window.__mdEditor.getMarkdown()")
                guard source as? String == fixture.markdown else {
                    throw WebViewLayoutHarness.Failure("Rendering changed the Markdown source")
                }
                let read = try XCTUnwrap(readLayout)
                let edit = try XCTUnwrap(editLayout)
                var differences: [String] = []
                func compare(_ label: String, _ lhs: Double, _ rhs: Double) {
                    if abs(lhs - rhs) > 1 { differences.append("\(label): read=\(lhs), editor=\(rhs)") }
                }
                func compareRect(_ label: String, _ lhs: WebViewLayoutHarness.Rect, _ rhs: WebViewLayoutHarness.Rect,
                                 editorHeaders: Int = 0) {
                    compare("\(label).x", lhs.x, rhs.x)
                    // Both modes reserve the same language-header height.
                    compare("\(label).y", lhs.y, rhs.y)
                    compare("\(label).width", lhs.width, rhs.width)
                    compare("\(label).height", lhs.height, rhs.height)
                }
                compare("column x", read.columnX, edit.columnX)
                compare("column y", read.columnY, edit.columnY)
                compare("column width", read.columnWidth, edit.columnWidth)
                if fixture.sourceRepresentationReason != nil {
                    // Source-only features have intentionally different block
                    // heights. Shared paragraphs must still wrap and align;
                    // compare their lines relative to each paragraph's top.
                    for name in fixture.localParityTexts {
                        let lhs = try XCTUnwrap(read.elements.first { $0.name == name })
                        let rhs = try XCTUnwrap(edit.elements.first { $0.name == name })
                        compare("\(name).x", lhs.rect.x, rhs.rect.x)
                        compare("\(name).width", lhs.rect.width, rhs.rect.width)
                        compare("\(name).height", lhs.rect.height, rhs.rect.height)
                        if lhs.lines.count != rhs.lines.count {
                            differences.append("\(name): different wrapped line count")
                        }
                        for (index, pair) in zip(lhs.lines, rhs.lines).enumerated() {
                            let label = "\(name) line \(index)"
                            compare("\(label).x", pair.0.x, pair.1.x)
                            compare("\(label).y within block", pair.0.y - lhs.rect.y, pair.1.y - rhs.rect.y)
                            compare("\(label).width", pair.0.width, pair.1.width)
                            compare("\(label).height", pair.0.height, pair.1.height)
                        }
                    }
                    if !differences.isEmpty { throw WebViewLayoutHarness.Failure(differences.joined(separator: "\n")) }
                    continue
                }
                if read.elements.map(\.name) != edit.elements.map(\.name) {
                    differences.append("Different rendered elements or order")
                }
                for (lhs, rhs) in zip(read.elements, edit.elements) {
                    compareRect(lhs.name, lhs.rect, rhs.rect, editorHeaders: rhs.editorHeadersAbove)
                    if lhs.lines.count != rhs.lines.count {
                        differences.append("\(lhs.name): different wrapped line count")
                    }
                    for (index, pair) in zip(lhs.lines, rhs.lines).enumerated() {
                        compareRect("\(lhs.name) line \(index)", pair.0, pair.1, editorHeaders: rhs.editorHeadersAbove)
                    }
                }
                if !differences.isEmpty { throw WebViewLayoutHarness.Failure(differences.joined(separator: "\n")) }
            } catch {
                let directory = await reader.saveDiagnostics(name: name, layout: readLayout)
                _ = await editor.saveDiagnostics(name: name, layout: editLayout)
                XCTFail("\(name): \(error)\nDiagnostics: \(directory.path)", file: file, line: line)
            }
        }
    }
}
