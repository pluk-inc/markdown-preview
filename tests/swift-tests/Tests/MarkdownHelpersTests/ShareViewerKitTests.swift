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
            // The app's diagram wiring (drawing, zoom, the HUD), started once
            // pele.global.js has loaded with the reader's language's texts
            // (diagramStrings); it returns { bootstrap, renderAll }.
            const mermaidWiring = (t) => \(localizedMermaidWiring);
            // The app's translations of the diagram texts, by language.
            const diagramStrings = \(diagramStrings);
            window.MdpRenderers = {
                highlightAll: highlightAll,
                renderMathElement: renderMathElement,
                markdownForSelection: markdownForSelection,
                mermaidWiring: mermaidWiring,
                diagramStrings: diagramStrings,
            };
            })();

            """,
        ]
    }

    /// The diagram texts the viewer shows, keyed for `t` in the wiring, to
    /// the app's English source text.
    private static let diagramKeys: KeyValuePairs<String, String> = [
        "zoomOut": "Zoom Out", "zoomIn": "Zoom In", "resetZoom": "Reset zoom",
        "fillWidth": "Fill width", "fitDiagram": "Fit diagram",
        "unsupported": "This diagram type is not supported.",
        "syntax": "The diagram has a syntax error.",
        "semantic": "The diagram is not valid.",
        "limit": "The diagram is too large to draw.",
        "generic": "The diagram could not be drawn.",
        "position": "Line %d, column %d",
        "empty": "This diagram is empty.",
    ]

    /// The viewer's languages, named as the app's .lproj folders.
    private static let languages = ["en", "ja", "zh-Hans", "pl", "fa"]

    /// `{ en: { zoomOut: "Zoom Out", … }, ja: { … }, … }` from the app's
    /// Localizable.strings, so the viewer says what the app says.
    static var diagramStrings: String {
        var table: [String: [String: String]] = [:]
        for language in languages {
            let url = TestVendor.repositoryRoot.appendingPathComponent("md-preview/\(language).lproj/Localizable.strings")
            let strings = (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil)) as? [String: String] ?? [:]
            table[language] = Dictionary(uniqueKeysWithValues: diagramKeys.map { ($0.key, strings[$0.value] ?? $0.value) })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(table)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The app's wiring with its English texts read from `t` instead.
    static var localizedMermaidWiring: String {
        var wiring = MarkdownHTML.mermaidInitWiring
        let replacements = [
            (#"const fillWidthLabel = "Fill width";"#, "const fillWidthLabel = t.fillWidth;"),
            (#"const fitDiagramLabel = "Fit diagram";"#, "const fitDiagramLabel = t.fitDiagram;"),
            (MarkdownHTML.diagramMessagesJS, """
            {
                errors: { 'unsupported-diagram': t.unsupported, syntax: t.syntax, semantic: t.semantic, limit: t.limit },
                generic: t.generic, position: t.position, empty: t.empty, emptyHint: '', unavailable: ''
            }
            """),
        ]
        for (english, localized) in replacements {
            precondition(wiring.components(separatedBy: english).count == 2,
                         "The app's diagram wiring changed; update ShareViewerKitTests.localizedMermaidWiring")
            wiring = wiring.replacingOccurrences(of: english, with: localized)
        }
        return wiring
    }

    func testDiagramStringsHaveEveryTextInEveryLanguage() {
        for language in Self.languages where language != "en" {
            let url = TestVendor.repositoryRoot.appendingPathComponent("md-preview/\(language).lproj/Localizable.strings")
            let strings = (try? PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil)) as? [String: String] ?? [:]
            for (key, english) in Self.diagramKeys {
                XCTAssertNotNil(strings[english], "\(language) has no translation for \(key)")
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
