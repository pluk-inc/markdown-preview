import XCTest
@testable import MarkdownHelpers

final class MarkdownSourceScriptTests: XCTestCase {
    /// Quick Look rewrites `<img src>` in the page HTML. Raw HTML in the
    /// embedded Markdown source must not look like markup to it, or
    /// copy-as-Markdown returns rewritten text.
    func testEmbeddedSourceSurvivesQuickLookImageRewrite() throws {
        let markdown = "<img src='same.png'>\n\n</script>"
        let html = MarkdownHTML.makeHTML(from: markdown, allowsScroll: true, colorScheme: .light)
        let rewritten = InlineLocalAssets.rewriteRelativeImages(
            html: html,
            baseDirectory: URL(fileURLWithPath: "/tmp/qltest-source/", isDirectory: true),
            reader: { _ in Data([0xDE, 0xAD]) }
        ).html
        let marker = "window.MdPreview = window.MdPreview || {}; window.MdPreview.source = "
        let start = try XCTUnwrap(rewritten.range(of: marker)).upperBound
        let end = try XCTUnwrap(rewritten[start...].range(of: ";</script>")).lowerBound
        let literal = String(rewritten[start..<end])
        XCTAssertFalse(literal.contains("<"), literal)
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8), options: .fragmentsAllowed) as? String
        XCTAssertEqual(decoded, markdown)
    }
}
