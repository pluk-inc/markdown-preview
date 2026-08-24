import Foundation
import XCTest
@testable import MarkdownHelpers

final class DocumentFontSettingTests: XCTestCase {
    func testMissingAndInvalidValuesFallBackToTheSystemFace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DocumentFontSetting.read(from: defaults), .system)
        XCTAssertEqual(DocumentFontSetting.read(from: nil), .system)

        defaults.set("comic-sans", forKey: DocumentFontSetting.defaultsKey)
        XCTAssertEqual(DocumentFontSetting.read(from: defaults), .system)
    }

    func testEveryFaceRoundTripsAndTheDefaultClearsItsKey() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for setting in DocumentFontSetting.allCases {
            DocumentFontSetting.write(setting, to: defaults)
            XCTAssertEqual(DocumentFontSetting.read(from: defaults), setting)
        }

        DocumentFontSetting.write(.system, to: defaults)
        XCTAssertNil(defaults.object(forKey: DocumentFontSetting.defaultsKey))
    }

    // Every stack has to end in a generic family, or macOS's per-script cascade
    // has nothing to fall back to for text the named faces don't cover — the
    // zh-Hans localisation being the case that would break first.
    func testEveryStackEndsInAGenericFamily() {
        let generics = ["serif", "sans-serif", "monospace"]
        for setting in DocumentFontSetting.allCases {
            let last = setting.fontFamily
                .split(separator: ",")
                .last
                .map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertNotNil(last, "\(setting) has no font stack")
            XCTAssertTrue(generics.contains(last ?? ""),
                          "\(setting) ends in \(last ?? "nothing"), not a generic family")
        }
    }

    func testTheSystemAndMonospaceFacesReuseTheSharedStacks() {
        XCTAssertEqual(DocumentFontSetting.system.fontFamily, MarkdownHTML.bodyFontFamily)
        XCTAssertEqual(DocumentFontSetting.monospace.fontFamily, MarkdownHTML.codeFontFamily)
    }

    // 0.88em is tuned against the system face's x-height, so a face with a
    // different one needs its own correction or code stops reading as smaller
    // than the prose around it.
    func testCodeSizeIsCorrectedPerFace() {
        XCTAssertEqual(DocumentFontSetting.system.codeFontSize, "0.88em")
        XCTAssertEqual(DocumentFontSetting.rounded.codeFontSize, "0.88em")
        XCTAssertNotEqual(DocumentFontSetting.serif.codeFontSize,
                          DocumentFontSetting.system.codeFontSize)
        XCTAssertEqual(DocumentFontSetting.monospace.codeFontSize, "1em")
    }

    func testRenderedHTMLCarriesTheChosenFace() {
        let html = MarkdownHTML.makeHTML(from: "# Title\n\nBody `code`.",
                                         documentFont: .serif)
        XCTAssertTrue(html.contains("--mdp-doc-font: \(DocumentFontSetting.serif.fontFamily);"),
                      "the document font custom property is missing")
        XCTAssertTrue(html.contains("--mdp-code-font-size: \(DocumentFontSetting.serif.codeFontSize);"),
                      "the code size correction is missing")
    }

    // The stylesheet keeps a literal fallback, so a page rendered before the
    // override is applied still has a face rather than the browser default.
    func testTheStylesheetFallsBackToTheSystemFace() {
        let html = MarkdownHTML.makeHTML(from: "Body", documentFont: .system)
        XCTAssertTrue(html.contains("var(--mdp-doc-font, \(MarkdownHTML.bodyFontFamily))"))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
