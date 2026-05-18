import XCTest

@testable import MarkdownHelpers

final class CodeFenceInfoTests: XCTestCase {

    // MARK: - Language extraction

    func testBareLanguageBecomesLowercaseLanguageWithEmptyMetadata() {
        let info = CodeFenceInfo(rawInfoString: "Swift")
        XCTAssertEqual(info.language, "swift")
        XCTAssertEqual(info.metadata, "")
    }

    func testFirstWhitespaceSeparatedTokenIsTheLanguage() {
        // ```mermaid some-name → language is mermaid; rest is metadata.
        let info = CodeFenceInfo(rawInfoString: "mermaid some-name")
        XCTAssertEqual(info.language, "mermaid")
        XCTAssertEqual(info.metadata, "some-name")
    }

    func testTabsAlsoSeparateLanguageFromMetadata() {
        let info = CodeFenceInfo(rawInfoString: "ts\ttitle=\"foo.ts\"")
        XCTAssertEqual(info.language, "ts")
        XCTAssertEqual(info.metadata, "title=\"foo.ts\"")
    }

    func testMetadataPreservesInternalWhitespaceAndCasing() {
        // CommonMark says only language is "first word"; metadata is left as-is
        // (modulo surrounding-whitespace trimming) so callers can parse it.
        let info = CodeFenceInfo(rawInfoString: "ts  Title=\"Foo Bar\"  {1,3}")
        XCTAssertEqual(info.language, "ts")
        XCTAssertEqual(info.metadata, "Title=\"Foo Bar\"  {1,3}")
    }

    // MARK: - Trimming and empty cases

    func testLeadingAndTrailingWhitespaceIsTrimmedBeforeSplitting() {
        let info = CodeFenceInfo(rawInfoString: "   mermaid   some-name   ")
        XCTAssertEqual(info.language, "mermaid")
        XCTAssertEqual(info.metadata, "some-name")
    }

    func testNilInfoStringYieldsEmptyValues() {
        let info = CodeFenceInfo(rawInfoString: nil)
        XCTAssertEqual(info.language, "")
        XCTAssertEqual(info.metadata, "")
    }

    func testEmptyInfoStringYieldsEmptyValues() {
        let info = CodeFenceInfo(rawInfoString: "")
        XCTAssertEqual(info.language, "")
        XCTAssertEqual(info.metadata, "")
    }

    func testWhitespaceOnlyInfoStringYieldsEmptyValues() {
        let info = CodeFenceInfo(rawInfoString: "   \t  ")
        XCTAssertEqual(info.language, "")
        XCTAssertEqual(info.metadata, "")
    }
}
