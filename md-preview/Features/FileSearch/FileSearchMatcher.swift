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
        fileprivate let name: PreparedText
        fileprivate let path: PreparedText

        init(fileName: String, relativePath: String) {
            self.fileName = fileName
            self.relativePath = relativePath
            self.name = PreparedText(fileName)
            self.path = fileName == relativePath ? name : PreparedText(relativePath)
        }

        /// Derives the file name from the path, which is all the callers that
        /// enumerate a directory tree actually have.
        init(relativePath: String) {
            self.init(fileName: relativePath.split(separator: "/").last.map(String.init) ?? relativePath,
                      relativePath: relativePath)
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

    /// Converts the `Character` offsets in a `Match` into `NSRange`s over the
    /// same string, for attributing the matched characters in the UI.
    ///
    /// Lives here rather than in the view so the conversion is covered by the
    /// SPM suite: a file name with an emoji or a combining mark has more UTF-16
    /// units than characters, and getting that wrong bolds the wrong letters.
    static func nsRanges(_ ranges: [Range<Int>], in string: String) -> [NSRange] {
        ranges.compactMap { range in
            guard let lower = string.index(string.startIndex, offsetBy: range.lowerBound, limitedBy: string.endIndex),
                  let upper = string.index(string.startIndex, offsetBy: range.upperBound, limitedBy: string.endIndex),
                  lower <= upper else { return nil }
            return NSRange(lower..<upper, in: string)
        }
    }

    /// Indices into `candidates`, best first. Non-matches are dropped.
    ///
    /// A blank query matches everything for callers that need an unfiltered
    /// ordering. The palette skips ranking until a nonblank query is entered.
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
            guard let score = score(query: prepared, against: candidates[index]) else { continue }
            scored.append((index, score))
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
        let ascii: [UInt8]?
        /// A `/` means the reader is narrowing by directory, which only the
        /// relative path can satisfy.
        let matchesRelativePath: Bool

        init(_ query: String) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            self.text = trimmed
            self.folded = trimmed.map(FileSearchMatcher.folded)
            let ascii = folded.compactMap(\.asciiValue)
            // Character.asciiValue reports LF for CRLF, but matching treats
            // those as distinct graphemes, so CRLF must stay on the Unicode path.
            self.ascii = ascii.count == folded.count && !trimmed.utf8.contains(13) ? ascii : nil
            self.matchesRelativePath = trimmed.contains("/")
        }

        var isBlank: Bool { text.isEmpty }
    }

    static func match(query: PreparedQuery, against candidate: Candidate) -> Match? {
        guard !query.isBlank else { return Match(score: 0) }

        if query.matchesRelativePath {
            guard let alignment = align(query: query, to: candidate.path) else {
                return nil
            }
            return Match(score: alignment.score, pathRanges: alignment.ranges)
        }

        guard let alignment = align(query: query, to: candidate.name) else {
            return nil
        }
        return Match(score: alignment.score + nameTierBonus(query: query, name: candidate.name),
                     nameRanges: alignment.ranges)
    }

    /// Ranking needs only scores. Highlight backtracking is reserved for the
    /// visible rows that call `match`, not every matching file in the index.
    static func score(query: PreparedQuery, against candidate: Candidate) -> Int? {
        guard !query.isBlank else { return 0 }
        let text = query.matchesRelativePath ? candidate.path : candidate.name
        guard let alignment = align(query: query, to: text, includeRanges: false) else { return nil }
        return alignment.score + (query.matchesRelativePath ? 0 : nameTierBonus(query: query, name: candidate.name))
    }

    /// Immutable work shared by queries for the lifetime of the index snapshot.
    /// Character folding preserves the existing Unicode and highlight semantics.
    fileprivate struct PreparedText: Equatable, Sendable {
        enum Storage: Equatable, Sendable {
            case ascii([UInt8])
            case unicode(String)
        }

        let storage: Storage
        let boundaryBonuses: [UInt8]

        let count: Int

        init(_ text: String) {
            let bytes = Array(text.utf8)
            // CRLF is one Swift Character despite containing two ASCII bytes.
            if bytes.allSatisfy({ $0 < 128 }), !bytes.contains(13) {
                // Most project paths are ASCII. One byte per character avoids
                // retaining a 16-byte Character for every byte in those paths.
                count = bytes.count
                storage = .ascii(bytes.map { (65...90).contains($0) ? $0 + 32 : $0 })
                boundaryBonuses = bytes.indices.map { index in
                    guard index > 0 else { return UInt8(bonusBoundary) }
                    let previous = bytes[index - 1]
                    if [45, 95, 46, 32, 47].contains(previous) { return UInt8(bonusBoundary) }
                    let current = bytes[index]
                    if (97...122).contains(previous), (65...90).contains(current) { return UInt8(bonusCamel) }
                    if (48...57).contains(previous), (65...90).contains(current) || (97...122).contains(current) {
                        return UInt8(bonusCamel)
                    }
                    return 0
                }
            } else {
                // Retaining Character arrays for every Unicode path is costly.
                // Keep the original string and prepare only the queried field,
                // avoiding extra cold-open latency and index memory for these files.
                count = text.count
                storage = .unicode(text)
                boundaryBonuses = []
            }
        }
    }

    // MARK: - Tiers

    /// Whole-name outcomes are put in tiers of their own rather than being
    /// folded into the per-character score, so an exact hit can never lose to
    /// a long scattered one.
    private static func nameTierBonus(query: PreparedQuery, name: PreparedText) -> Int {
        switch name.storage {
        case .ascii(let text):
            guard let query = query.ascii else { return 0 }
            if text == query { return scoreExactName }
            if text.starts(with: query) { return scorePrefixName }
        case .unicode(let text):
            let folded = text.map(FileSearchMatcher.folded)
            if folded == query.folded { return scoreExactName }
            if folded.starts(with: query.folded) { return scorePrefixName }
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
    private static func align(query: PreparedQuery, to text: PreparedText,
                              includeRanges: Bool = true) -> Alignment? {
        switch text.storage {
        case .ascii(let characters):
            guard let query = query.ascii else { return nil }
            return align(query: query, text: characters, includeRanges: includeRanges) {
                Int(text.boundaryBonuses[$0])
            }
        case .unicode(let string):
            guard query.folded.count <= text.count else { return nil }
            // Reject without allocating arrays, as in the original Unicode path.
            var next = 0
            for character in string {
                if next == query.folded.count { break }
                if FileSearchMatcher.folded(character) == query.folded[next] { next += 1 }
            }
            guard next == query.folded.count else { return nil }
            let characters = Array(string)
            return align(query: query.folded, text: characters.map(FileSearchMatcher.folded),
                         includeRanges: includeRanges) { boundaryBonus(characters, at: $0) }
        }
    }

    private static func align<Element: Equatable>(query: [Element], text: [Element],
                                                  includeRanges: Bool,
                                                  boundaryAt: (Int) -> Int) -> Alignment? {
        // Cheap reject first. Most of a project never matches, and this keeps
        // the allocation below off the hot path.
        let rows = query.count
        let columns = text.count
        guard rows <= columns, isSubsequence(query, of: text) else { return nil }
        let foldedText = text
        guard rows > 0, columns > 0 else { return nil }

        // Only the previous row is needed to score the next. Parent links are
        // allocated only when a visible result needs its highlight ranges.
        var previous = [Int](repeating: unreachable, count: columns)
        var current = previous
        var parents = includeRanges ? [Int](repeating: -1, count: rows * columns) : []

        for row in 0..<rows {
            // Best cell on the previous row at least two columns back, which
            // is where a gap (as opposed to a contiguous run) can come from.
            var gapBest = unreachable
            var gapBestColumn = -1

            for column in 0..<columns {
                if row > 0, column >= 2 {
                    let candidateScore = previous[column - 2]
                    if candidateScore > gapBest {
                        gapBest = candidateScore
                        gapBestColumn = column - 2
                    }
                }

                current[column] = unreachable
                guard foldedText[column] == query[row] else { continue }

                let bonus = scoreMatch + boundaryAt(column)

                if row == 0 {
                    // Nudge earlier starts ahead of later ones, gently enough
                    // that it only settles otherwise-equal alignments.
                    current[column] = bonus - min(column, leadingPenaltyLimit) * penaltyLeading
                    continue
                }

                var best = unreachable
                var bestParent = -1

                if column >= 1 {
                    let contiguous = previous[column - 1]
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
                current[column] = best + bonus
                if includeRanges { parents[row * columns + column] = bestParent }
            }
            swap(&previous, &current)
        }

        var bestColumn = -1
        var bestScore = unreachable
        for column in 0..<columns where previous[column] > bestScore {
            bestScore = previous[column]
            bestColumn = column
        }
        guard bestColumn >= 0, bestScore != unreachable else { return nil }

        guard includeRanges else { return Alignment(score: bestScore, ranges: []) }
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

    private static func isSubsequence<Element: Equatable>(_ query: [Element], of text: [Element]) -> Bool {
        var next = query.startIndex
        for character in text {
            guard next < query.endIndex else { return true }
            if character == query[next] { next += 1 }
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
        let lhsLength = lhs.path.count
        let rhsLength = rhs.path.count
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
