import Foundation
import XCTest
@testable import MarkdownHelpers

final class FileSearchMatcherTests: XCTestCase {

    private typealias Candidate = FileSearchMatcher.Candidate

    private func candidate(_ relativePath: String) -> Candidate {
        Candidate(relativePath: relativePath)
    }

    /// Ranks `paths` against `query` and returns them in the order the palette
    /// would show them, which is what every ordering test here is really about.
    private func ranked(_ query: String, _ paths: [String]) -> [String] {
        let candidates = paths.map(candidate)
        return FileSearchMatcher.rank(query: query, candidates: candidates).map { candidates[$0].relativePath }
    }

    private func score(_ query: String, _ path: String) -> Int? {
        FileSearchMatcher.match(query: query, against: candidate(path))?.score
    }

    // MARK: - Candidate

    func testCandidateDerivesItsFileNameFromThePath() {
        XCTAssertEqual(candidate("docs/guides/setup.md").fileName, "setup.md")
        XCTAssertEqual(candidate("README.md").fileName, "README.md")
    }

    // MARK: - Partial names

    func testAPrefixOfTheNameMatches() {
        XCTAssertNotNil(score("red", "README.md"))
    }

    func testCharactersMayBeSkipped() {
        // The whole point of a fuzzy palette: a typo-shaped query still finds
        // the file, because the letters appear in order.
        XCTAssertNotNil(score("redme", "README.md"))
        XCTAssertNotNil(score("rdm", "README.md"))
    }

    func testMatchingIgnoresCaseInBothDirections() {
        XCTAssertNotNil(score("README", "readme.md"))
        XCTAssertNotNil(score("readme", "README.md"))
    }

    func testANonMatchIsAbsentRatherThanAZeroScore() {
        XCTAssertNil(FileSearchMatcher.match(query: "zzz", against: candidate("README.md")))
        // Right letters, wrong order.
        XCTAssertNil(FileSearchMatcher.match(query: "emdaer", against: candidate("README.md")))
    }

    func testAQueryLongerThanTheCandidateCannotMatch() {
        XCTAssertNil(FileSearchMatcher.match(query: "readme-file", against: candidate("a.md")))
    }

    func testRankDropsNonMatches() {
        XCTAssertEqual(ranked("guide", ["README.md", "guide.md", "notes.md"]), ["guide.md"])
    }

    // MARK: - Ranking

    func testAnExactNameBeatsALongerNameThatAlsoStartsWithTheQuery() {
        XCTAssertEqual(ranked("readme.md", ["readme.md.bak", "readme.md"]).first, "readme.md")
    }

    func testAPrefixBeatsAMatchInTheMiddleOfTheName() {
        XCTAssertEqual(ranked("read", ["unread.md", "README.md"]).first, "README.md")
    }

    func testAWordBoundaryBeatsAMatchInsideAWord() {
        XCTAssertEqual(ranked("mh", ["xmhy.md", "Markdown-Helpers.md"]).first, "Markdown-Helpers.md")
    }

    func testACamelCaseHumpCountsAsAWordBoundary() {
        XCTAssertEqual(ranked("mh", ["xmhy.md", "MarkdownHelpers.md"]).first, "MarkdownHelpers.md")
    }

    func testAContiguousRunBeatsAScatteredOne() {
        XCTAssertEqual(ranked("mdhtml", ["mudhotmail.md", "MarkdownHTML.swift"]).first,
                       "MarkdownHTML.swift")
    }

    func testAnEarlierMatchWinsWhenNothingElseSeparatesTwoNames() {
        // Equal-length paths, and the alphabetical tiebreak would pick the
        // other one, so only the match position can decide this.
        XCTAssertEqual(ranked("note", ["x-aaaa-note.md", "x-note-aaaa.md"]).first, "x-note-aaaa.md")
    }

    // MARK: - Names beat paths

    func testAQueryWithoutASlashIsTestedAgainstTheNameOnly() {
        // `docs` names a directory here, not a file. Matching it would fill the
        // palette with every file under that directory, which is not what the
        // reader asked for.
        XCTAssertNil(FileSearchMatcher.match(query: "docs", against: candidate("docs/guide.md")))
        XCTAssertEqual(ranked("docs", ["docs/guide.md", "docs.md"]), ["docs.md"])
    }

    func testASlashLetsTheQueryReachTheDirectory() {
        XCTAssertNotNil(score("docs/gui", "docs/guide.md"))
        XCTAssertNil(FileSearchMatcher.match(query: "api/gui", against: candidate("docs/guide.md")))
    }

    func testASlashQueryReportsPathRangesRatherThanNameRanges() throws {
        let match = try XCTUnwrap(FileSearchMatcher.match(query: "docs/g", against: candidate("docs/guide.md")))
        XCTAssertTrue(match.nameRanges.isEmpty)
        XCTAssertEqual(match.pathRanges, [0..<6])
    }

    // MARK: - Matched ranges

    func testTheMatchedCharactersAreReportedAsRanges() throws {
        let match = try XCTUnwrap(FileSearchMatcher.match(query: "rdm", against: candidate("README.md")))
        XCTAssertEqual(match.nameRanges, [0..<1, 3..<5])
        XCTAssertTrue(match.pathRanges.isEmpty)
    }

    func testAContiguousMatchIsOneRange() throws {
        let match = try XCTUnwrap(FileSearchMatcher.match(query: "read", against: candidate("README.md")))
        XCTAssertEqual(match.nameRanges, [0..<4])
    }

    // MARK: - Determinism

    func testIdenticallyScoredFilesAreOrderedIndependentlyOfInputOrder() {
        let forwards = ranked("guide", ["a/guide.md", "b/guide.md"])
        let backwards = ranked("guide", ["b/guide.md", "a/guide.md"])
        XCTAssertEqual(forwards, ["a/guide.md", "b/guide.md"])
        XCTAssertEqual(forwards, backwards)
    }

    func testShallowerPathsComeFirstWhenScoresTie() {
        XCTAssertEqual(ranked("guide", ["deep/nested/guide.md", "guide.md"]),
                       ["guide.md", "deep/nested/guide.md"])
    }

    // MARK: - Blank queries

    func testABlankQueryMatchesEverythingInAStableOrder() {
        for query in ["", "   ", "\t\n"] {
            XCTAssertEqual(ranked(query, ["b.md", "docs/a.md", "a.md"]),
                           ["a.md", "b.md", "docs/a.md"],
                           "query \(query.debugDescription)")
        }
    }

    func testABlankQueryMatchesASingleCandidateWithoutRanges() throws {
        let match = try XCTUnwrap(FileSearchMatcher.match(query: "  ", against: candidate("README.md")))
        XCTAssertEqual(match.score, 0)
        XCTAssertTrue(match.nameRanges.isEmpty)
        XCTAssertTrue(match.pathRanges.isEmpty)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertNotNil(score("  read  ", "README.md"))
    }

    func testInteriorWhitespaceStillHasToMatch() {
        // File names contain spaces, so a space is a character, not a separator.
        XCTAssertNotNil(score("rel notes", "release notes.md"))
        XCTAssertNil(FileSearchMatcher.match(query: "rel notes", against: candidate("release-notes.md")))
    }

    // MARK: - Unicode

    func testNonASCIINamesMatchCaseInsensitively() {
        XCTAssertNotNil(score("übersicht", "Übersicht.md"))
        XCTAssertNotNil(score("ÜBERSICHT", "übersicht.md"))
        XCTAssertNotNil(score("схема", "СХЕМА.md"))
    }

    func testRangesLineUpWithTheCharactersOfANonASCIIName() throws {
        let name = "Übersicht.md"
        let match = try XCTUnwrap(FileSearchMatcher.match(query: "übe", against: candidate(name)))
        XCTAssertEqual(match.nameRanges, [0..<3])
        // The offsets are Character offsets, so slicing by them is safe even
        // when the name is not ASCII.
        let characters = Array(name)
        XCTAssertEqual(String(characters[0..<3]), "Übe")
    }

    func testRangesLineUpWithCharactersOutsideTheBasicPlane() throws {
        let name = "🚀launch.md"
        let match = try XCTUnwrap(FileSearchMatcher.match(query: "🚀la", against: candidate(name)))
        XCTAssertEqual(match.nameRanges, [0..<3])
        let characters = Array(name)
        XCTAssertEqual(String(characters[0..<3]), "🚀la")
    }

    // MARK: - Cancellation and cost

    /// A project at the index's file cap, with names that make short queries
    /// match a large share of it, the expensive case for the palette.
    private func projectAtTheFileCap() -> [Candidate] {
        let names = ["readme", "guide", "notes", "Markdown-Helpers", "changelog",
                     "api", "setup", "design_doc", "meeting", "todo"]
        return (0..<ProjectFileIndex.maximumFileCount).map { index in
            candidate("docs/section\(index % 40)/part\(index % 7)/\(names[index % names.count])-\(index).md")
        }
    }

    /// Ranks inside a task that has already been cancelled, so the outcome
    /// does not depend on how quickly the task gets scheduled.
    private func rankInCancelledTask(_ query: String, _ candidates: [Candidate]) async -> Result<[Int], Error> {
        let task = Task { () throws -> [Int] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileSearchMatcher.rankCancellably(query: query, candidates: candidates)
        }
        return await task.result
    }

    func testTheCancellableRankingAgreesWithThePlainOne() throws {
        let candidates = ["README.md", "docs/readme-old.md", "guide.md", "Markdown-Helpers.md", "xmhy.md"]
            .map(candidate)
        for query in ["", "r", "mh", "docs/", "zzz"] {
            XCTAssertEqual(try FileSearchMatcher.rankCancellably(query: query, candidates: candidates),
                           FileSearchMatcher.rank(query: query, candidates: candidates),
                           "query \(query.debugDescription)")
        }
    }

    func testACancelledRankingStopsInsteadOfReturningAPartialList() async {
        let candidates = projectAtTheFileCap()
        for query in ["md", "docs/sec", ""] {
            let outcome = await rankInCancelledTask(query, candidates)
            guard case .failure(let error) = outcome else {
                return XCTFail("query \(query.debugDescription) finished despite cancellation")
            }
            XCTAssertTrue(error is CancellationError, "query \(query.debugDescription) threw \(error)")
        }
    }

    /// Records the cost of one pass at the file cap. There is no baseline, so
    /// this reports rather than gates; the palette keeps this work off the
    /// main actor because a release build still takes tens of milliseconds.
    func testRankingAProjectAtTheFileCap() {
        let candidates = projectAtTheFileCap()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(options: options) {
            XCTAssertEqual(FileSearchMatcher.rank(query: "md", candidates: candidates).count, candidates.count)
        }
    }
}

// MARK: - Range conversion for the UI

extension FileSearchMatcherTests {

    private func nsRanges(_ query: String, _ name: String) -> [NSRange] {
        guard let match = FileSearchMatcher.match(query: query, against: Candidate(relativePath: name)) else {
            return []
        }
        return FileSearchMatcher.nsRanges(match.nameRanges, in: name)
    }

    func testMatchedRangesConvertToUTF16Offsets() {
        XCTAssertEqual(nsRanges("rdm", "README.md"), [NSRange(location: 0, length: 1),
                                                      NSRange(location: 3, length: 2)])
    }

    func testConversionAccountsForCharactersWiderThanOneUTF16Unit() {
        // "🚀" is two UTF-16 units, so a naive offset would bold one unit short
        // and land mid-character.
        let name = "🚀launch.md"
        XCTAssertEqual(nsRanges("la", name), [NSRange(location: 2, length: 2)])
        let text = name as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: 2, length: 2)), "la")
    }

    func testConvertedRangesAlwaysLieInsideTheString() {
        for name in ["README.md", "Übersicht.md", "🚀launch.md", "a.md"] {
            for query in ["r", "e", "a", "m", "d", "ü", "🚀"] {
                for range in nsRanges(query, name) {
                    XCTAssertLessThanOrEqual(range.location + range.length,
                                             (name as NSString).length,
                                             "\(query) in \(name)")
                }
            }
        }
    }

    func testOutOfBoundsOffsetsAreDroppedRatherThanCrashing() {
        XCTAssertEqual(FileSearchMatcher.nsRanges([0..<99], in: "ab"), [])
        XCTAssertEqual(FileSearchMatcher.nsRanges([], in: "ab"), [])
    }
}
