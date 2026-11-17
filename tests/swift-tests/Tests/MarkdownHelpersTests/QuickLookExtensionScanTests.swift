import Foundation
import XCTest
@testable import MarkdownHelpers

final class QuickLookExtensionScanTests: XCTestCase {
    // The shape `pluginkit -m -v -p com.apple.quicklook.preview` prints: a
    // mark column, then tab-separated identifier(version), UUID, date, path.
    private let output = [
        "-    net.example.notes.Quicklook(3.0.4)\tUUID-1\t2026-11-09 10:59:58 +0000\t/Applications/Notes Two.app/Contents/PlugIns/Notes Quicklook.appex",
        "+    doc.md-preview.quick-look(0.0.74)\tUUID-2\t2026-11-17 09:56:55 +0000\t/Applications/Markdown Preview.app/Contents/PlugIns/quick-look.appex",
        "     com.example.editor.QuickLook(1.0.8)\tUUID-3\t2026-11-13 09:40:22 +0000\t/Applications/Editor.app/Contents/PlugIns/EditorQuickLook.appex",
        "     com.example.framework.Preview(1.0)\tUUID-4\t2026-10-15 11:53:44 +0000\t/System/Library/Frameworks/Example.framework/PlugIns/Example_Preview.appex",
        " (4 plug-ins)",
    ].joined(separator: "\n")

    private var extensions: [QuickLookExtension] {
        QuickLookExtensionScan.parse(pluginkitOutput: output)
    }

    func testParseReadsIdentifierElectionAndPath() {
        XCTAssertEqual(extensions.map(\.identifier), [
            "net.example.notes.Quicklook",
            "doc.md-preview.quick-look",
            "com.example.editor.QuickLook",
            "com.example.framework.Preview",
        ])
        XCTAssertEqual(extensions.map(\.election), [.ignore, .use, .automatic, .automatic])
        XCTAssertEqual(extensions[2].path, "/Applications/Editor.app/Contents/PlugIns/EditorQuickLook.appex")
    }

    func testParseSkipsLinesThatAreNotExtensions() {
        XCTAssertEqual(QuickLookExtensionScan.parse(pluginkitOutput: " (0 plug-ins)\n\nmatch: error"), [])
    }

    func testDisplayNameIsTheContainingApp() {
        XCTAssertEqual(extensions[0].displayName, "Notes Two")
    }

    func testDisplayNameOutsideAnAppIsTheExtensionFileName() {
        XCTAssertEqual(extensions[3].displayName, "Example_Preview")
    }

    func testCompetitorsAreTheOtherEnabledClaimantsOfOurTypes() {
        let types = [
            "net.example.notes.Quicklook": ["net.daringfireball.markdown"],
            "com.example.editor.QuickLook": ["public.plain-text", "net.daringfireball.markdown"],
            "com.example.framework.Preview": ["public.plain-text"],
            "doc.md-preview.quick-look": ["net.daringfireball.markdown"],
        ]
        let competitors = QuickLookExtensionScan.competitors(
            in: extensions,
            ownIdentifier: "doc.md-preview.quick-look",
            ownContentTypes: ["net.daringfireball.markdown", "public.markdown"],
            contentTypes: { types[$0.identifier] ?? [] }
        )
        // Not ours, not the one already turned off, and not the one that
        // claims only the parent type.
        XCTAssertEqual(competitors.map(\.identifier), ["com.example.editor.QuickLook"])
    }

    func testCompetitorsListEachIdentifierOnce() {
        let twice = extensions + extensions
        let competitors = QuickLookExtensionScan.competitors(
            in: twice,
            ownIdentifier: "doc.md-preview.quick-look",
            ownContentTypes: ["public.markdown"],
            contentTypes: { _ in ["public.markdown"] }
        )
        XCTAssertEqual(competitors.map(\.identifier),
                       ["com.example.editor.QuickLook", "com.example.framework.Preview"])
    }
}
