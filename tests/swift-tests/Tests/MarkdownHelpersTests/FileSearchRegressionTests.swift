import Foundation
import XCTest
@testable import MarkdownHelpers

final class FileSearchRegressionTests: XCTestCase {
    private struct Baseline: Decodable {
        let paths: [String]
        let cases: [Query]

        struct Query: Decodable {
            let query: String
            let matches: [Match]
        }

        struct Match: Decodable {
            let index: Int
            let score: Int
            let nameRanges: [[Int]]
            let pathRanges: [[Int]]
            let nameUTF16: [[Int]]
            let pathUTF16: [[Int]]
        }
    }

    /// Recorded from the unoptimized matcher at 5d111f6, before changing the
    /// algorithm. Keep these expectations independent of the optimized code.
    /// Covers blank/nonmatching queries, score ties, case, word/camel boundaries,
    /// filename/path switching, spaces, composed accents and multi-scalar emoji.
    func testScoresOrderingAndHighlightsMatchThePreviousImplementation() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "fixtures/file-search/matcher-baseline.json")
        let baseline = try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: fixture))
        let candidates = baseline.paths.map { FileSearchMatcher.Candidate(relativePath: $0) }
        for item in baseline.cases {
            let query = FileSearchMatcher.PreparedQuery(item.query)
            XCTAssertEqual(FileSearchMatcher.rank(query: item.query, candidates: candidates),
                           item.matches.map(\.index), item.query)
            // Changing filesystem enumeration order must not change result order.
            let reversed = Array(candidates.reversed())
            XCTAssertEqual(FileSearchMatcher.rank(query: item.query, candidates: reversed)
                .map { reversed[$0].relativePath },
                           item.matches.map { baseline.paths[$0.index] }, item.query)
            let expected = Dictionary(uniqueKeysWithValues: item.matches.map { ($0.index, $0) })
            for (index, candidate) in candidates.enumerated() {
                let context = "\(item.query.debugDescription) in \(candidate.relativePath)"
                let match = FileSearchMatcher.match(query: query, against: candidate)
                let score = FileSearchMatcher.score(query: query, against: candidate)
                guard let expected = expected[index] else {
                    XCTAssertNil(match, context)
                    XCTAssertNil(score, context)
                    continue
                }
                let actual = try XCTUnwrap(match, context)
                XCTAssertEqual(score, expected.score, context)
                XCTAssertEqual(actual.score, expected.score, context)
                XCTAssertEqual(actual.nameRanges.map { [$0.lowerBound, $0.upperBound] }, expected.nameRanges, context)
                XCTAssertEqual(actual.pathRanges.map { [$0.lowerBound, $0.upperBound] }, expected.pathRanges, context)
                XCTAssertEqual(FileSearchMatcher.nsRanges(actual.nameRanges, in: candidate.fileName)
                    .map { [$0.location, $0.length] }, expected.nameUTF16, context)
                XCTAssertEqual(FileSearchMatcher.nsRanges(actual.pathRanges, in: candidate.relativePath)
                    .map { [$0.location, $0.length] }, expected.pathUTF16, context)
            }
        }
    }

    func testTypingBackspacingAndSwitchingToPathsDoNotMutatePreparedCandidates() {
        let paths = ["README.md", "docs/README.md", "docs/guide.md", "🚀launch.md"]
        let candidates = paths.map { FileSearchMatcher.Candidate(relativePath: $0) }
        for query in ["r", "re", "read", "re", "r", "", "docs/", "docs/g", "docs/", "docs", "🚀"] {
            let fresh = paths.map { FileSearchMatcher.Candidate(relativePath: $0) }
            XCTAssertEqual(FileSearchMatcher.rank(query: query, candidates: candidates),
                           FileSearchMatcher.rank(query: query, candidates: fresh), query)
        }
    }

    func testCRLFQueryDoesNotMatchASingleNewline() {
        let query = FileSearchMatcher.PreparedQuery("a\r\nb")
        let candidate = FileSearchMatcher.Candidate(relativePath: "a\nb.md")
        XCTAssertNil(FileSearchMatcher.match(query: query, against: candidate))
        XCTAssertNil(FileSearchMatcher.score(query: query, against: candidate))
    }

    func testExplicitFileNameIsPreparedIndependentlyOfPath() {
        let candidate = FileSearchMatcher.Candidate(fileName: "Visible.md", relativePath: "docs/stored.md")
        XCTAssertNotNil(FileSearchMatcher.match(query: "vis", against: candidate))
        XCTAssertNil(FileSearchMatcher.match(query: "stored", against: candidate))
        XCTAssertNotNil(FileSearchMatcher.match(query: "docs/stored", against: candidate))
    }
}
