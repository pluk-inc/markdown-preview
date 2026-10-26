import Foundation
import XCTest
@testable import MarkdownHelpers

/// The share link web viewer (server/share-worker/viewer) draws documents
/// with the app's own stylesheet and renderer scripts, exported from
/// `MarkdownHTML` into `viewer/generated/`. This test fails when the copies
/// drift from the app. Set MDP_WRITE_VIEWER_KIT=1 to rewrite them.
final class ShareViewerKitTests: XCTestCase {

    private static let generated = TestVendor.repositoryRoot
        .appendingPathComponent("server/share-worker/viewer/generated")

    private static let header = """
    /* Generated from the app's MarkdownHTML by ShareViewerKitTests.
       Do not edit; run MDP_WRITE_VIEWER_KIT=1 swift test --filter ShareViewerKitTests. */

    """

    static var files: [String: String] {
        [
            // The app page also sets these per user setting; the viewer
            // shows a share the way a fresh install would.
            "markdown.css": header + MarkdownHTML.stylesheet + """

            /* The app's scroll override; printing uses viewer.css's print layout. */
            @media screen {
            \(MarkdownHTML.scrollOverrideCSS)
            }
            :root {
                --mdp-doc-font: \(DocumentFontSetting.defaultSetting.fontFamily);
                --mdp-code-font-size: \(DocumentFontSetting.defaultSetting.codeFontSize);
                --mdp-page-top-clearance: 0px;
                --mdp-chrome-zoom: 1;
            }

            """,
            "renderers.js": header + """
            (function () {
            // The app's renderers log timings through this; the page has no use for them.
            window.MdPreviewPerf = window.MdPreviewPerf || { log() {}, now: () => performance.now() };
            \(MarkdownHTML.highlightAllBody)
            \(MarkdownHTML.mathElementRenderer)
            \(MarkdownHTML.markdownSelectionScript)
            \(MarkdownHTML.tableColumnResizeScript)
            window.MdpRenderers = {
                highlightAll: highlightAll,
                renderMathElement: renderMathElement,
                markdownForSelection: markdownForSelection,
                wrapTables: wrapTables,
                enableTableColumnResize: enableTableColumnResize,
            };
            })();

            """,
            // Loaded after pele.global.js, only for documents with diagrams.
            "diagrams.js": header + """
            window.MdpDiagrams = {
                // (messages) => { bootstrap, renderAll }
                wiring: \(MarkdownHTML.mermaidWiringFunction),
                // The app's diagramMessagesJS in each of its languages.
                messages: {
            \(languages.map { "        \(javaScriptKey($0)): \(diagramMessages(in: $0))," }.joined(separator: "\n"))
                },
            };

            """,
        ]
    }

    /// The viewer's languages, named as the app's .lproj folders.
    private static let languages = ["en", "ja", "zh-Hans", "pl", "fa"]

    private static func javaScriptKey(_ language: String) -> String {
        language.contains("-") ? MarkdownHTML.javaScriptStringLiteral(language) : language
    }

    private static func localizedStrings(_ language: String) -> [String: String] {
        let url = TestVendor.repositoryRoot.appendingPathComponent("md-preview/\(language).lproj/Localizable.strings")
        return (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil))
            as? [String: String] ?? [:]
    }

    /// Each string literal of `diagramMessagesJS`, the app's English.
    private static var diagramTexts: [String] {
        let literal = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        let js = MarkdownHTML.diagramMessagesJS
        return literal.matches(in: js, range: NSRange(js.startIndex..., in: js)).map { match in
            let quoted = String(js[Range(match.range, in: js)!])
            return (try! JSONSerialization.jsonObject(with: Data("[\(quoted)]".utf8)) as! [String])[0]
        }
    }

    /// `diagramMessagesJS` with each English text replaced by `language`'s
    /// translation from the app's Localizable.strings.
    static func diagramMessages(in language: String) -> String {
        let strings = localizedStrings(language)
        var js = MarkdownHTML.diagramMessagesJS
        for text in diagramTexts {
            js = js.replacingOccurrences(of: MarkdownHTML.javaScriptStringLiteral(text),
                                         with: MarkdownHTML.javaScriptStringLiteral(strings[text] ?? text))
        }
        return js
    }

    func testEveryDiagramTextHasATranslationInEveryLanguage() {
        XCTAssertFalse(Self.diagramTexts.isEmpty)
        for language in Self.languages where language != "en" {
            let strings = Self.localizedStrings(language)
            for text in Self.diagramTexts {
                XCTAssertNotNil(strings[text], "\(language) has no translation for \(text.debugDescription)")
            }
        }
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
