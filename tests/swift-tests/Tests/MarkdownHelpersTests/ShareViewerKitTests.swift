import Foundation
import XCTest
@testable import MarkdownHelpers

/// The share link web viewer (server/share-worker/viewer) draws documents
/// with the app's own stylesheet and renderer scripts, exported from
/// `MarkdownHTML` into `viewer/generated/`. This test fails when the copies
/// drift from the app. Set MDP_WRITE_VIEWER_KIT=1 to rewrite them.
final class ShareViewerKitTests: XCTestCase {

    private static let generated: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("server/share-worker/viewer/generated")

    private static let header = """
    /* Generated from the app's MarkdownHTML by ShareViewerKitTests.
       Do not edit; run MDP_WRITE_VIEWER_KIT=1 swift test --filter ShareViewerKitTests. */

    """

    /// The app hides every inner scroller's bar because its page scrolls in
    /// the root. The viewer's page scrolls in `.page`, which keeps its bar.
    static let scrollbarRule = ":where(:not(html):not(body):not(pre))::-webkit-scrollbar"

    static var viewerStylesheet: String {
        MarkdownHTML.stylesheet.replacingOccurrences(
            of: scrollbarRule,
            with: ":where(:not(html):not(body):not(pre):not(.page))::-webkit-scrollbar")
    }

    func testViewerPageKeepsItsScrollbar() {
        XCTAssertTrue(MarkdownHTML.stylesheet.contains(Self.scrollbarRule),
                      "The app's scrollbar rule changed; update ShareViewerKitTests.viewerStylesheet")
    }

    static var files: [String: String] {
        [
            // The app page also sets these per user setting; the viewer
            // shows a share the way a fresh install would.
            "markdown.css": header + viewerStylesheet + """

            :root {
                --mdp-doc-font: \(DocumentFontSetting.defaultSetting.fontFamily);
                --mdp-code-font-size: \(DocumentFontSetting.defaultSetting.codeFontSize);
                --mdp-page-top-clearance: 0px;
                --mdp-chrome-zoom: 1;
            }

            """,
            "renderers.js": header + """
            (function () {
            \(MarkdownHTML.highlightAllBody)
            \(MarkdownHTML.mathElementRenderer)
            \(MarkdownHTML.markdownSelectionScript)
            window.MdpRenderers = {
                highlightAll: highlightAll,
                renderMathElement: renderMathElement,
                markdownForSelection: markdownForSelection,
            };
            })();

            """,
        ]
    }

    func testViewerKitMatchesTheApp() throws {
        let rewrite = ProcessInfo.processInfo.environment["MDP_WRITE_VIEWER_KIT"] == "1"
        for (name, contents) in Self.files {
            let url = Self.generated.appendingPathComponent(name)
            if rewrite {
                try FileManager.default.createDirectory(at: Self.generated, withIntermediateDirectories: true)
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
            let committed = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(committed, contents,
                           "\(name) is out of date; run MDP_WRITE_VIEWER_KIT=1 swift test --filter ShareViewerKitTests")
        }
    }
}
