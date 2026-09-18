//
//  ProjectFileIndex.swift
//  md-preview
//
//  Walks the project folder once and caches the files Search for Document can
//  offer. Kept free of AppKit so the SPM helper tests can exercise the walk
//  against a temporary directory without a GUI host.
//

import Foundation

actor ProjectFileIndex {

    /// The extensions a project surfaces. This is the one list — the project
    /// navigator filters its rows with it too, so the two agree on which
    /// *kinds* of file belong to a project.
    ///
    /// They do not agree on which *folders* to look in. The walk below prunes
    /// dependency and build directories, package contents, and anything past
    /// `maximumDepth`, none of which the navigator hides. README.md lists
    /// these exclusions; keep it in step when changing them.
    ///
    /// Note this is deliberately *not* the list the open panel accepts, which
    /// also takes `.txt` and does not take `.mkd` or `.mdwn`. Reconciling the
    /// two is a user-visible change and belongs in its own PR.
    nonisolated static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdwn", "mdx"
    ]

    /// The files under one root at one moment.
    struct Snapshot: Sendable, Equatable {
        let root: URL
        let candidates: [FileSearchMatcher.Candidate]
        /// True when the walk stopped at a cap rather than at the end of the
        /// tree. The palette says so rather than quietly showing a partial
        /// answer as if it were the whole project.
        let isTruncated: Bool

        /// Candidates carry a relative path rather than a URL so the matcher
        /// stays a string algorithm; the root puts them back together.
        func url(at position: Int) -> URL? {
            guard candidates.indices.contains(position) else { return nil }
            return root.appending(path: candidates[position].relativePath)
        }
    }

    static let shared = ProjectFileIndex()

    private struct Cached {
        let snapshot: Snapshot
        let builtAt: Date
    }

    private var cache: [URL: Cached] = [:]
    /// Builds in progress, so two palettes opening at once walk the tree once.
    private var builds: [URL: Task<Snapshot, Never>] = [:]

    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date

    init(cacheLifetime: TimeInterval = 5, now: @escaping @Sendable () -> Date = Date.init) {
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    /// The project's files, walking the tree only when what is cached has gone
    /// stale. Five seconds is chosen to cover the realistic case — the reader
    /// creates a file and immediately goes looking for it — without a
    /// recursive watcher over the whole tree, which costs real resources.
    func snapshot(for root: URL) async -> Snapshot {
        let key = root.standardizedFileURL

        if let cached = cache[key], now().timeIntervalSince(cached.builtAt) < cacheLifetime {
            return cached.snapshot
        }
        if let inFlight = builds[key] {
            return await inFlight.value
        }

        let build = Task { @concurrent in Self.build(root: key) }
        builds[key] = build
        let snapshot = await build.value
        builds[key] = nil
        cache[key] = Cached(snapshot: snapshot, builtAt: now())
        return snapshot
    }

    /// Drops the cached walk for a root, so the next open rebuilds. Here for
    /// the navigator's directory watchers to call once someone wires them up.
    func invalidate(root: URL) {
        cache[root.standardizedFileURL] = nil
    }

    // MARK: - Walking

    /// The caps are parameters so the tests can exceed them without building
    /// a twenty-thousand-file fixture.
    nonisolated static func build(root: URL,
                                  maximumFileCount: Int = ProjectFileIndex.maximumFileCount,
                                  maximumDepth: Int = ProjectFileIndex.maximumDepth) -> Snapshot {
        let rootComponents = root.standardizedFileURL.pathComponents
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            // `skipsPackageDescendants` keeps the walk out of `.app`, `.rtfd`
            // and friends, which are directories but are not folders a reader
            // is browsing.
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return Snapshot(root: root, candidates: [], isTruncated: false)
        }

        var candidates: [FileSearchMatcher.Candidate] = []
        var isTruncated = false

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDirectory {
                if enumerator.level >= maximumDepth || prunedDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }

            guard candidates.count < maximumFileCount else {
                isTruncated = true
                break
            }

            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else { continue }
            let relativePath = components.dropFirst(rootComponents.count).joined(separator: "/")

            candidates.append(FileSearchMatcher.Candidate(fileName: url.lastPathComponent,
                                                          relativePath: relativePath))
        }

        return Snapshot(root: root, candidates: candidates, isTruncated: isTruncated)
    }

    /// Dependency and build directories. Without this a walk rooted at a real
    /// project is dominated by thousands of vendored `.md` files nobody is
    /// looking for, which pushes the reader's own notes off the list.
    nonisolated static let prunedDirectoryNames: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "build", "Pods",
        "Carthage", "vendor", "target", "venv", ".venv", "__pycache__"
    ]

    nonisolated static let maximumFileCount = 20_000
    nonisolated static let maximumDepth = 12
}
