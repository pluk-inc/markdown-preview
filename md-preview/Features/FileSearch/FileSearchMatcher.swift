//
//  FileSearchMatcher.swift
//  md-preview
//
//  Ranks project files against a partial name typed into Search for Document.
//  Kept free of AppKit so the SPM helper tests can exercise it without a GUI
//  host — the matching rules are the part worth pinning down in CI.
//

import Foundation

nonisolated enum FileSearchMatcher {

    /// One file the palette can offer.
    struct Candidate: Equatable, Sendable {
        /// The last path component, which is what a reader is usually typing.
        let fileName: String
        /// Path relative to the project root, no leading slash.
        let relativePath: String

        init(fileName: String, relativePath: String) {
            self.fileName = fileName
            self.relativePath = relativePath
        }

        /// Derives the file name from the path, which is all the callers that
        /// enumerate a directory tree actually have.
        init(relativePath: String) {
            self.relativePath = relativePath
            self.fileName = relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        }
    }

    /// Where a query matched and how well. Exactly one of the two range lists
    /// is populated: a query matches either a file name or a relative path,
    /// never both, because a file name cannot contain the `/` that sends a
    /// query down the path route.
    ///
    /// Ranges are offsets into the field's `Character` view so the UI can bold
    /// the matched characters. Scores are ordering-only — the absolute value
    /// carries no meaning beyond comparing two candidates for one query.
    struct Match: Equatable, Sendable {
        let score: Int
        let nameRanges: [Range<Int>]
        let pathRanges: [Range<Int>]

        init(score: Int, nameRanges: [Range<Int>] = [], pathRanges: [Range<Int>] = []) {
            self.score = score
            self.nameRanges = nameRanges
            self.pathRanges = pathRanges
        }
    }

    // MARK: - Public API

    /// Matches a single candidate. Returns nil when the query is not a
    /// subsequence of the field it is tested against — a non-match is absent,
    /// not a zero score, so callers cannot accidentally display it.
    static func match(query: String, against candidate: Candidate) -> Match? {
        match(query: PreparedQuery(query), against: candidate)
    }

    /// Indices into `candidates`, best first. Non-matches are dropped.
    ///
    /// A blank query matches everything, which is what makes the palette show
    /// the project before anything is typed.
    static func rank(query: String, candidates: [Candidate]) -> [Int] {
        // Outside a cancelled task the cancellable variant never throws.
        (try? rankCancellably(query: query, candidates: candidates)) ?? []
    }

    /// `rank(query:candidates:)` for callers running it inside a task that a
    /// newer query can cancel. At the 20,000-file cap one pass takes tens of
    /// milliseconds in a release build, so the palette ranks off the main
    /// actor and abandons a pass as soon as the reader types again, rather
    /// than finishing work nobody will see.
    static func rankCancellably(query: String, candidates: [Candidate]) throws -> [Int] {
        let prepared = PreparedQuery(query)

        guard !prepared.isBlank else {
            try Task.checkCancellation()
            return candidates.indices.sorted { isOrderedBefore(candidates[$0], candidates[$1]) }
        }

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(candidates.count)
        for index in candidates.indices {
            // Checked in batches: the check is cheap, but not free per file.
            if index % cancellationCheckInterval == 0 {
                try Task.checkCancellation()
            }
            guard let match = match(query: prepared, against: candidates[index]) else { continue }
            scored.append((index, match.score))
        }
        try Task.checkCancellation()

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return isOrderedBefore(candidates[lhs.index], candidates[rhs.index])
        }.map(\.index)
    }

    /// How many candidates `rankCancellably` scores between cancellation
    /// checks.
    static let cancellationCheckInterval = 256

    // MARK: - Query preparation

    /// A query folded once so ranking a whole project does not refold it per
    /// candidate.
    struct PreparedQuery: Sendable {
        /// Trimmed at the ends: a search field collects stray spaces, and
        /// nobody means them. Interior spaces still have to match, because
        /// file names contain them.
        let text: String
        let folded: [Character]
        /// A `/` means the reader is narrowing by directory, which only the
        /// relative path can satisfy.
        let matchesRelativePath: Bool

        init(_ query: String) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = trimmed
            self.folded = trimmed.map(FileSearchMatcher.folded)
            self.matchesRelativePath = trimmed.contains("/")
        }

        var isBlank: Bool { text.isEmpty }
    }

    static func match(query: PreparedQuery, against candidate: Candidate) -> Match? {
        guard !query.isBlank else { return Match(score: 0) }

        if query.matchesRelativePath {
            guard let alignment = align(query: query.folded, to: candidate.relativePath) else {
                return nil
            }
            return Match(score: alignment.score, pathRanges: alignment.ranges)
        }

        guard let alignment = align(query: query.folded, to: candidate.fileName) else {
            return nil
        }
        return Match(score: alignment.score + nameTierBonus(query: query, fileName: candidate.fileName),
                     nameRanges: alignment.ranges)
    }

    // MARK: - Tiers

    /// Whole-name outcomes are put in tiers of their own rather than being
    /// folded into the per-character score, so an exact hit can never lose to
    /// a long scattered one.
    private static func nameTierBonus(query: PreparedQuery, fileName: String) -> Int {
        let folded = fileName.map(folded)
        if folded == query.folded { return scoreExactName }
        if folded.count > query.folded.count, Array(folded.prefix(query.folded.count)) == query.folded {
            return scorePrefixName
        }
        return 0
    }

    // MARK: - Alignment

    private struct Alignment {
        let score: Int
        let ranges: [Range<Int>]
    }

    /// Best-scoring subsequence alignment of `query` in `text`, by dynamic
    /// programming rather than a greedy left-to-right walk: greedy takes the
    /// first letter that fits and so misses the word-boundary hit a little
    /// further along, which is usually the one the reader meant.
    private static func align(query: [Character], to text: String) -> Alignment? {
        // Cheap reject first. Most of a project never matches, and this keeps
        // the allocation below off the hot path.
        guard isSubsequence(query, of: text) else { return nil }

        let characters = Array(text)
        let foldedText = characters.map(folded)
        let rows = query.count
        let columns = characters.count
        guard rows > 0, columns > 0 else { return nil }

        var scores = [Int](repeating: unreachable, count: rows * columns)
        var parents = [Int](repeating: -1, count: rows * columns)

        for row in 0..<rows {
            // Best cell on the previous row at least two columns back, which
            // is where a gap (as opposed to a contiguous run) can come from.
            var gapBest = unreachable
            var gapBestColumn = -1

            for column in 0..<columns {
                if row > 0, column >= 2 {
                    let candidateScore = scores[(row - 1) * columns + (column - 2)]
                    if candidateScore > gapBest {
                        gapBest = candidateScore
                        gapBestColumn = column - 2
                    }
                }

                guard foldedText[column] == query[row] else { continue }

                let cell = row * columns + column
                let bonus = scoreMatch + boundaryBonus(characters, at: column)

                if row == 0 {
                    // Nudge earlier starts ahead of later ones, gently enough
                    // that it only settles otherwise-equal alignments.
                    scores[cell] = bonus - min(column, leadingPenaltyLimit) * penaltyLeading
                    continue
                }

                var best = unreachable
                var bestParent = -1

                if column >= 1 {
                    let contiguous = scores[(row - 1) * columns + (column - 1)]
                    if contiguous != unreachable {
                        best = contiguous + bonusContiguous
                        bestParent = column - 1
                    }
                }
                if gapBest != unreachable, gapBest + penaltyGap > best {
                    best = gapBest + penaltyGap
                    bestParent = gapBestColumn
                }

                guard bestParent >= 0 else { continue }
                scores[cell] = best + bonus
                parents[cell] = bestParent
            }
        }

        let lastRow = (rows - 1) * columns
        var bestColumn = -1
        var bestScore = unreachable
        for column in 0..<columns where scores[lastRow + column] > bestScore {
            bestScore = scores[lastRow + column]
            bestColumn = column
        }
        guard bestColumn >= 0, bestScore != unreachable else { return nil }

        var positions = [Int](repeating: 0, count: rows)
        var column = bestColumn
        for row in stride(from: rows - 1, through: 0, by: -1) {
            positions[row] = column
            column = parents[row * columns + column]
        }

        return Alignment(score: bestScore, ranges: coalesce(positions))
    }

    /// Turns matched offsets into the fewest ranges that cover them, so the UI
    /// gets one attribute run per contiguous stretch.
    private static func coalesce(_ positions: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for position in positions {
            if let last = ranges.last, last.upperBound == position {
                ranges[ranges.count - 1] = last.lowerBound..<(position + 1)
            } else {
                ranges.append(position..<(position + 1))
            }
        }
        return ranges
    }

    private static func isSubsequence(_ query: [Character], of text: String) -> Bool {
        var next = query.startIndex
        for character in text {
            guard next < query.endIndex else { return true }
            if folded(character) == query[next] { next += 1 }
        }
        return next == query.endIndex
    }

    // MARK: - Scoring

    private static func boundaryBonus(_ characters: [Character], at index: Int) -> Int {
        guard index > 0 else { return bonusBoundary }
        let previous = characters[index - 1]
        if delimiters.contains(previous) { return bonusBoundary }
        let current = characters[index]
        if previous.isLowercase, current.isUppercase { return bonusCamel }
        if previous.isNumber, current.isLetter { return bonusCamel }
        return 0
    }

    /// Lowercases one character without changing how many there are, so the
    /// offsets reported back to the UI still line up with the original string.
    private static func folded(_ character: Character) -> Character {
        if let ascii = character.asciiValue {
            guard ascii >= UInt8(ascii: "A"), ascii <= UInt8(ascii: "Z") else { return character }
            return Character(UnicodeScalar(ascii + 32))
        }
        return character.lowercased().first ?? character
    }

    /// Stable order for candidates nothing else separates: shallow before
    /// deep, then the same localised, case-insensitive ordering the project
    /// navigator sorts its rows with, so results never depend on the order the
    /// file system happened to enumerate.
    private static func isOrderedBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let lhsLength = lhs.relativePath.count
        let rhsLength = rhs.relativePath.count
        if lhsLength != rhsLength { return lhsLength < rhsLength }
        switch lhs.relativePath.localizedStandardCompare(rhs.relativePath) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.relativePath < rhs.relativePath
        }
    }

    private static let delimiters: Set<Character> = ["-", "_", ".", " ", "/"]

    private static let scoreMatch = 16
    private static let bonusBoundary = 24
    private static let bonusCamel = 18
    private static let bonusContiguous = 20
    private static let penaltyGap = -8
    private static let penaltyLeading = 1
    private static let leadingPenaltyLimit = 20

    /// Far above anything the per-character score can reach for a realistic
    /// query, which is the point: these are tiers, not nudges.
    private static let scoreExactName = 1_000_000
    private static let scorePrefixName = 100_000

    /// Sentinel for "no alignment reaches this cell". Well away from
    /// `Int.min` so adding a penalty to it cannot overflow.
    private static let unreachable = Int.min / 4
}
