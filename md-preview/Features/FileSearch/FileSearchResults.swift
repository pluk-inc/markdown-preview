import Foundation

/// Combines app-wide history with project search without changing either ranking.
nonisolated enum FileSearchResults {
    struct Entry: Sendable, Equatable {
        let url: URL
        let candidate: FileSearchMatcher.Candidate
        let projectRoot: URL?
    }

    enum Row: Sendable, Equatable {
        case recentHeading
        case filesHeading
        case file(Entry)

        var entry: Entry? {
            if case .file(let entry) = self { return entry }
            return nil
        }
    }

    /// Shared by result deduplication and the current-tab no-op check.
    static func resolvedIdentity(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func rows(query: String, recentURLs: [URL], snapshot: ProjectFileIndex.Snapshot?) throws -> [Row] {
        let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let recent = recentURLs.map {
            Entry(url: $0, candidate: .init(relativePath: $0.path), projectRoot: nil)
        }
        let rankedRecent = blank ? Array(recent.indices) :
            try FileSearchMatcher.rankCancellably(query: query, candidates: recent.map(\.candidate))
        // Match every path first: an earlier alias may not match the query.
        // The first surviving identity wins by recency (blank) or relevance.
        var seen = Set<URL>()
        let uniqueRecent = rankedRecent.filter { seen.insert(resolvedIdentity(recent[$0].url)).inserted }
        let recentIndices = blank ? Array(uniqueRecent.prefix(10)) : uniqueRecent
        let displayedRecentURLs = Set(recentIndices.map { resolvedIdentity(recent[$0].url) })
        var rows: [Row] = recentIndices.isEmpty ? [] : [.recentHeading]
        rows += recentIndices.map { .file(recent[$0]) }
        guard !blank, let snapshot else { return rows }
        let ranked = try FileSearchMatcher.rankCancellably(query: query, candidates: snapshot.candidates)
        let files = ranked.compactMap { index -> Row? in
            guard let url = snapshot.url(at: index) else { return nil }
            if !displayedRecentURLs.isEmpty, displayedRecentURLs.contains(resolvedIdentity(url)) { return nil }
            return .file(Entry(url: url, candidate: snapshot.candidates[index], projectRoot: snapshot.root))
        }
        if !files.isEmpty { rows += [.filesHeading] + files }
        return rows
    }
}
