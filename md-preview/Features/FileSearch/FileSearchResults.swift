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

    static func rows(query: String, recentURLs: [URL], snapshot: ProjectFileIndex.Snapshot?) throws -> [Row] {
        let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var seen = Set<URL>()
        let recent = recentURLs.filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL).inserted }.map {
            Entry(url: $0, candidate: .init(relativePath: $0.path), projectRoot: nil)
        }
        let recentIndices = blank ? Array(recent.indices.prefix(10)) :
            try FileSearchMatcher.rankCancellably(query: query, candidates: recent.map(\.candidate))
        let displayedRecentURLs = Set(recentIndices.map { recent[$0].url.resolvingSymlinksInPath().standardizedFileURL })
        var rows: [Row] = recentIndices.isEmpty ? [] : [.recentHeading]
        rows += recentIndices.map { .file(recent[$0]) }
        guard !blank, let snapshot else { return rows }
        let ranked = try FileSearchMatcher.rankCancellably(query: query, candidates: snapshot.candidates)
        let files = ranked.compactMap { index -> Row? in
            guard let url = snapshot.url(at: index), !displayedRecentURLs.contains(url.resolvingSymlinksInPath().standardizedFileURL) else { return nil }
            return .file(Entry(url: url, candidate: snapshot.candidates[index], projectRoot: snapshot.root))
        }
        if !files.isEmpty { rows += [.filesHeading] + files }
        return rows
    }
}
