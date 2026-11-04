import Foundation
import XCTest
@testable import MarkdownHelpers

final class ReleaseNotesFormatterTests: XCTestCase {
    private let body = """
    This release adds **Publish to Web**.

    ### Added

    - **Publish to Web.** Uploads the document ([#567](https://github.com/o/r/pull/567), [#570](https://github.com/o/r/pull/570)).
    - **Support links.** About links to Discord.

    ### Fixed

    - **Search keeps its place.** Clicking no longer moves
      the highlight ([#604](https://github.com/o/r/pull/604)).
    - A bullet without a title.

    ### Contributors

    Thank you to the reporters:

    - [@kkkpc](https://github.com/kkkpc) — asked for shortcuts ([#590](https://github.com/o/r/issues/590)).
    - [@lucsky](https://github.com/lucsky) — reported the button ([#560](https://github.com/o/r/issues/560)).
    """

    private func date(_ text: String) -> Date {
        try! Date(text, strategy: .iso8601)
    }

    func testParsesIntroItemsLinksAndContributors() {
        let entry = ReleaseNotesFormatter.parse(body)
        XCTAssertEqual(entry.intro, "This release adds **Publish to Web**.")
        XCTAssertEqual(entry.items, [
            .init(title: "Publish to Web", text: "Uploads the document.",
                  links: ["[#567](https://github.com/o/r/pull/567)", "[#570](https://github.com/o/r/pull/570)"]),
            .init(title: "Support links", text: "About links to Discord.", links: []),
            .init(title: "Search keeps its place", text: "Clicking no longer moves the highlight.",
                  links: ["[#604](https://github.com/o/r/pull/604)"]),
            .init(title: nil, text: "A bullet without a title.", links: []),
        ])
        XCTAssertEqual(entry.contributors, ["[@kkkpc](https://github.com/kkkpc)", "[@lucsky](https://github.com/lucsky)"])
    }

    func testTitleUsesTheReleaseNameOrTheFirstItems() {
        let entry = ReleaseNotesFormatter.parse(body)
        let named = ReleaseNotesFormatter.Release(version: "0.0.71", name: "Sharper tables, steadier search",
                                                  date: date("2026-11-10T10:00:00Z"), body: body)
        XCTAssertEqual(ReleaseNotesFormatter.title(for: named, entry: entry), "Sharper tables, steadier search")
        let unnamed = ReleaseNotesFormatter.Release(version: "0.0.70", name: "Markdown Preview 0.0.70",
                                                    date: date("2026-10-28T10:00:00Z"), body: body)
        XCTAssertEqual(ReleaseNotesFormatter.title(for: unnamed, entry: entry), "Publish to Web, Support links")
        let empty = ReleaseNotesFormatter.Release(version: "0.0.5", name: nil,
                                                  date: date("2026-05-02T10:00:00Z"), body: "Fixes.")
        XCTAssertEqual(ReleaseNotesFormatter.title(for: empty, entry: ReleaseNotesFormatter.parse("Fixes.")),
                       "Markdown Preview 0.0.5")
    }

    func testDocumentGroupsReleasesNewestFirstByYearAndMonth() {
        let releases = [
            ReleaseNotesFormatter.Release(version: "0.0.1", name: nil,
                                          date: date("2025-12-30T10:00:00Z"), body: "First."),
            ReleaseNotesFormatter.Release(version: "0.0.3", name: "Third",
                                          date: date("2026-01-20T10:00:00Z"), body: body),
            ReleaseNotesFormatter.Release(version: "0.0.2", name: "Second",
                                          date: date("2026-01-05T10:00:00Z"), body: "Second."),
        ]
        let markdown = ReleaseNotesFormatter.document(releases)
        let headings = markdown.split(separator: "\n").filter { $0.hasPrefix("#") }
        XCTAssertEqual(headings, ["# 2026", "## January", "### Third", "### Second",
                                  "# 2025", "## December", "### Markdown Preview 0.0.1"])
        XCTAssertTrue(markdown.hasPrefix(ReleaseNotesFormatter.marker + "\n\n"))
        XCTAssertTrue(markdown.contains("January 20, 2026\n### Third\n`v0.0.3`\n"))
        XCTAssertTrue(markdown.contains("- **Publish to Web**\n\n  Uploads the document.\n\n  <span class=\"mdp-rn-links\">[#567](https://github.com/o/r/pull/567) [#570](https://github.com/o/r/pull/570)</span>\n"))
        XCTAssertTrue(markdown.contains("Thanks to [@kkkpc](https://github.com/kkkpc) and [@lucsky](https://github.com/lucsky)."))
    }

    func testItemsNameWhoShippedThemOnceEach() {
        let release = ReleaseNotesFormatter.Release(version: "0.0.3", name: "Third",
                                                    date: date("2026-01-20T10:00:00Z"), body: body)
        let authors: [Int: ReleaseNotesFormatter.Author] = [
            567: .init(name: "Ana", avatarURL: "https://a/1?v=4&s=96"),
            570: .init(name: "Ana", avatarURL: "https://a/1?v=4&s=96"),
            604: .init(name: "<b>Bo</b>", avatarURL: "https://a/2?v=4&s=96"),
        ]
        let markdown = ReleaseNotesFormatter.document([release], authors: authors)
        XCTAssertTrue(markdown.contains(#"<span class="mdp-rn-shipped"><img src="https://a/1?v=4&amp;s=96" alt="">Shipped by <span class="mdp-rn-name">Ana</span></span>"#))
        XCTAssertTrue(markdown.contains(#"Shipped by <span class="mdp-rn-name">&lt;b&gt;Bo&lt;/b&gt;</span>"#))
        // Issue links and items without pull requests name no one.
        XCTAssertEqual(markdown.components(separatedBy: "Shipped by").count - 1, 2)
    }

    func testLongLinkListsEndInACountThatOpensTheRelease() {
        let links = (1...6).map { "[#\($0)](https://github.com/o/r/pull/\($0))" }.joined(separator: ", ")
        let release = ReleaseNotesFormatter.Release(version: "0.0.9", name: nil, date: date("2026-01-20T10:00:00Z"),
                                                    body: "- **Big.** Many changes (\(links)).")
        let markdown = ReleaseNotesFormatter.document([release])
        XCTAssertTrue(markdown.contains("[#4](https://github.com/o/r/pull/4) [+2](https://github.com/pluk-inc/markdown-preview/releases/tag/v0.0.9)</span>"))
        XCTAssertFalse(markdown.contains("[#5]"))
    }

    func testWhatsNewCoversEverySkippedReleaseUpToThisOne() {
        let all = ["0.0.9", "0.0.10", "0.0.11", "0.0.12"].map {
            ReleaseNotesFormatter.Release(version: $0, name: nil, date: date("2026-01-20T10:00:00Z"), body: "")
        }
        let versions = { (previous: String, current: String) in
            ReleaseNotesFormatter.releases(all, after: previous, through: current).map(\.version)
        }
        // Numeric: 0.0.10 is newer than 0.0.9.
        XCTAssertEqual(versions("0.0.9", "0.0.11"), ["0.0.10", "0.0.11"])
        XCTAssertEqual(versions("0.0.10", "0.0.11"), ["0.0.11"])
        XCTAssertEqual(versions("", "0.0.11"), ["0.0.11"])
        // A rebuild of the same version shows that version.
        XCTAssertEqual(versions("0.0.11", "0.0.11"), ["0.0.11"])
    }

    func testFooterEndsTheDocument() {
        let release = ReleaseNotesFormatter.Release(version: "0.0.9", name: nil,
                                                    date: date("2026-01-20T10:00:00Z"), body: "Fixes.")
        let markdown = ReleaseNotesFormatter.document([release], footer: "[Previous releases](Release%20Notes.md)")
        XCTAssertTrue(markdown.hasSuffix("[Previous releases](Release%20Notes.md)\n"))
    }
}
