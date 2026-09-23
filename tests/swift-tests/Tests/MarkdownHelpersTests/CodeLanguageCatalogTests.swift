import XCTest
@testable import MarkdownHelpers

final class CodeLanguageCatalogTests: XCTestCase {
    func testFilteringMatchesNamesAndAliases() {
        XCTAssertEqual(CodeLanguageCatalog.matching("  SWIFT ").map(\.id), ["swift"])
        XCTAssertEqual(CodeLanguageCatalog.matching("terraform").map(\.id), ["hcl"])
        XCTAssertEqual(CodeLanguageCatalog.matching("objc").map(\.id), ["objective-c"])
        XCTAssertEqual(CodeLanguageCatalog.matching("C++").map(\.id), ["cpp"])
        XCTAssertTrue(CodeLanguageCatalog.matching("not-a-language").isEmpty)
        XCTAssertEqual(CodeLanguageCatalog.matching(" "), CodeLanguageCatalog.all)
    }

    func testRecentLanguagesAreDeduplicatedBoundedAndPersisted() throws {
        let suite = "CodeLanguageCatalogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CodeLanguageCatalog.recent(defaults: defaults).isEmpty)
        for id in ["swift", "python", "bash", "cpp", "json", "html", "python"] {
            CodeLanguageCatalog.remember(id, defaults: defaults)
        }
        XCTAssertEqual(CodeLanguageCatalog.recent(defaults: defaults).map(\.id),
                       ["python", "html", "json", "cpp", "bash"])
        CodeLanguageCatalog.remember("unknown", defaults: defaults)
        XCTAssertEqual(CodeLanguageCatalog.recent(defaults: defaults).count, 5)
        defaults.set(["swift", "unknown", "swift", "json"], forKey: CodeLanguageCatalog.recentKey)
        XCTAssertEqual(CodeLanguageCatalog.recent(defaults: defaults).map(\.id), ["swift", "json"])
    }

    func testCommonLanguagesExistAndCatalogIdentifiersAreUnique() {
        XCTAssertEqual(CodeLanguageCatalog.options(for: CodeLanguageCatalog.commonIDs).count,
                       CodeLanguageCatalog.commonIDs.count)
        XCTAssertEqual(Set(CodeLanguageCatalog.all.map(\.id)).count, CodeLanguageCatalog.all.count)
    }
}
