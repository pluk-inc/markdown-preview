//
//  ReleaseNotes.swift
//  md-preview
//
//  The release notes as Markdown documents laid out by
//  `ReleaseNotesFormatter` from the GitHub releases (whose bodies are the
//  CHANGELOG.md entries), written to the app's caches, where they open
//  read-only. Nothing ships in the app.
//
//  After an update (see `ReleaseNotesPolicy`) the update capsule says so
//  once, with a What's New button. The notes download while it shows —
//  every release since the version the reader ran before, so none they
//  skipped is missed — and open when the button is clicked; closing the
//  capsule throws them away. Every release, newest first, opens from
//  Help › Release Notes or the "Previous releases" link at the end.
//

import AppKit

@MainActor
enum ReleaseNotes {

    /// Where the downloaded notes are kept. Standardized once: menu
    /// validation and every display ask about it.
    static let directory = URL.cachesDirectory
        .appending(path: "ReleaseNotes", directoryHint: .isDirectory)
        .standardizedFileURL

    /// The releases since the reader's previous version.
    static let whatsNewFile = directory.appending(path: "whats-new.md")

    /// Every release; the link at the end of What's New points at it.
    static let historyFile = directory.appending(path: "history.md")

    /// The releases page, for when the notes cannot be downloaded.
    static let webURL = URL(string: "https://github.com/pluk-inc/markdown-preview/releases")!

    /// The running app's version, `MARKETING_VERSION`.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// True for a downloaded notes file. It is replaced whenever the notes
    /// are opened again, so it must not be edited.
    static func isCachedCopy(_ fileURL: URL?) -> Bool {
        fileURL?.isDescendantOrSame(of: directory) ?? false
    }

    /// True for `fileURL` being the cached notes file `file`.
    static func isCachedCopy(_ fileURL: URL?, of file: URL) -> Bool {
        fileURL?.standardizedFileURL.path == file.standardizedFileURL.path
    }

    /// True for the history file, so its link can download it first.
    static func isHistoryFile(_ fileURL: URL?) -> Bool {
        isCachedCopy(fileURL, of: historyFile)
    }

    /// The open document showing the notes file `file`, if any.
    static func openDocument(at file: URL) -> NSDocument? {
        NSDocumentController.shared.documents.first { isCachedCopy($0.fileURL, of: file) }
    }

    /// The name a window, tab, and outline show for a document: the notes'
    /// own title, or the file name.
    static func displayName(for fileURL: URL?) -> String {
        title(for: fileURL) ?? fileURL?.lastPathComponent
            ?? NSLocalizedString("Untitled", comment: "Window title when no document is open")
    }

    /// The window and tab title of a notes file, in place of its file name.
    static func title(for fileURL: URL?) -> String? {
        guard isCachedCopy(fileURL) else { return nil }
        switch fileURL?.lastPathComponent {
        case whatsNewFile.lastPathComponent:
            return String(format: L("What’s New in Markdown Preview %@"), currentVersion)
        case historyFile.lastPathComponent:
            return L("Release Notes")
        default:
            return nil
        }
    }

    // MARK: - What's New

    private static var whatsNewDownload: Task<URL, Error>?

    /// Starts downloading the releases after `previousVersion` up to the
    /// running one; empty for a reader whose previous version is unknown,
    /// who gets the running version's notes.
    static func prepareWhatsNew(after previousVersion: String) {
        whatsNewDownload?.cancel()
        whatsNewDownload = Task {
            let releases = ReleaseNotesFormatter.releases(try await allReleases(),
                                                          after: previousVersion, through: currentVersion)
            guard !releases.isEmpty else { throw URLError(.resourceUnavailable) }
            let footer = "[\(L("Previous releases"))](\(historyFile.lastPathComponent))"
            // The capsule may have been closed during the download.
            try Task.checkCancellation()
            let labels = labels, locale = locale
            try writeDocument(to: whatsNewFile) {
                ReleaseNotesFormatter.document(releases, authors: $0, footer: footer,
                                               labels: labels, locale: locale)
            }
            return whatsNewFile
        }
    }

    /// The prepared notes, waiting for them when the download is still
    /// running (a click right after the capsule appeared).
    static func whatsNew() async throws -> URL {
        if whatsNewDownload == nil { prepareWhatsNew(after: "") }
        return try await whatsNewDownload!.value
    }

    /// The capsule was closed: stop the download and drop the notes.
    static func discardWhatsNew() {
        whatsNewDownload?.cancel()
        whatsNewDownload = nil
        try? FileManager.default.removeItem(at: whatsNewFile)
    }

    // MARK: - Every release

    /// Whether this launch has written the history; a history tab restored
    /// from before an update is refreshed first.
    private(set) static var hasDownloadedHistory = false

    /// Downloads every release and returns the history file. Offline, the
    /// copy from an earlier download is good enough.
    static func downloadHistory() async throws -> URL {
        do {
            let releases = try await allReleases()
            let labels = labels, locale = locale
            try writeDocument(to: historyFile) {
                ReleaseNotesFormatter.document(releases, authors: $0, labels: labels, locale: locale)
            }
            hasDownloadedHistory = true
        } catch where FileManager.default.fileExists(atPath: historyFile.path) {
            NSLog("ReleaseNotes: using the saved notes: \(error)")
        }
        return historyFile
    }

    /// Writes the document `render` makes. "Shipped by" never holds it up:
    /// it shows the authors saved last time, and asks GitHub afterwards.
    /// When that changes anything the document is written again, and an
    /// open window reloads it.
    private static func writeDocument(to file: URL,
                                      render: @escaping ([Int: ReleaseNotesFormatter.Author]) -> String) throws {
        let cache = loadAuthorCache()
        let saved = authors(in: cache)
        try write(render(saved), to: file)
        Task {
            let fresh = await fetchAuthors(updating: cache)
            // A What's New dropped meanwhile stays dropped.
            if fresh != saved, FileManager.default.fileExists(atPath: file.path) {
                try? write(render(fresh), to: file)
            }
        }
    }

    /// The releases, downloaded once a session: What's New and then every
    /// release ask for the same list.
    private static var releasesDownload: Task<[ReleaseNotesFormatter.Release], Error>?

    private static func allReleases() async throws -> [ReleaseNotesFormatter.Release] {
        let download = releasesDownload ?? Task { try await fetchReleases() }
        releasesDownload = download
        do {
            return try await download.value
        } catch {
            // Offline now need not mean offline next time.
            releasesDownload = nil
            throw error
        }
    }

    /// The words around the release text, in the app's language.
    private static var labels: ReleaseNotesFormatter.Labels {
        .init(shippedBy: L("Shipped by"), thanks: L("Thanks to %@."))
    }

    /// The app's language, which can differ from the system's: dates and
    /// lists follow it.
    private static var locale: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }

    private static func write(_ markdown: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: file, options: .atomic)
    }

    // MARK: - After an update

    /// Waits for the document to settle before the capsule appears, so it
    /// never competes with the first paint of a launch.
    private static let announcementDelay: TimeInterval = 0.8
    /// How long to wait before asking again while the capsule shows an
    /// update step.
    private static let busyRetryDelay: TimeInterval = 10
    private static var hadUsedAppBeforeLaunch = false
    private static var isAnnouncementScheduled = false
    private static var didHandleAnnouncement = false

    /// Keys every earlier release wrote once a reader used the app: the
    /// sidebar seed runs for the first window of any kind (file, folder or
    /// untitled), the default-handler offer for the first file.
    private static let priorUseKeys = [
        MainSplitViewController.didSeedKey,
        DocumentWindowController.didOfferDefaultHandlerKey,
    ]

    /// Call from `applicationWillFinishLaunching(_:)`, before any window —
    /// restored ones included — can write the prior-use keys for this launch.
    static func noteLaunch() {
        hadUsedAppBeforeLaunch = priorUseKeys.contains { UserDefaults.standard.bool(forKey: $0) }
    }

    /// Called each time a document window shows content. Once per update,
    /// the capsule says the app was updated, over a document window that is
    /// still on screen when the delay passes, and the notes start
    /// downloading. Left alone, it is gone at the next launch.
    static func announceUpdateIfNeeded() {
        guard !didHandleAnnouncement, !isAnnouncementScheduled else { return }
        isAnnouncementScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + announcementDelay) {
            isAnnouncementScheduled = false
            // With every document window closed during the delay, the next
            // one to open asks again, rather than the capsule showing alone.
            guard NSApp.windows.contains(where: {
                $0.isVisible && $0.windowController is DocumentWindowController
            }) else { return }
            // An update step waiting for an answer (Download, Relaunch Now)
            // keeps the capsule; ask again once it may have gone.
            if let delegate = NSApp.delegate as? AppDelegate, delegate.updaterController.model.phase != .idle {
                DispatchQueue.main.asyncAfter(deadline: .now() + busyRetryDelay) { announceUpdateIfNeeded() }
                return
            }
            didHandleAnnouncement = true
            guard let previousVersion = ReleaseNotesPolicy.claimUpdate(
                thisBuild: thisBuild, thisVersion: currentVersion,
                hasUsedAppBefore: hadUsedAppBeforeLaunch
            ), let delegate = NSApp.delegate as? AppDelegate else {
                // A capsule left alone last time leaves its notes behind.
                if openDocument(at: whatsNewFile) == nil {
                    try? FileManager.default.removeItem(at: whatsNewFile)
                }
                return
            }
            prepareWhatsNew(after: previousVersion)
            let model = delegate.updaterController.model
            model.show(.updated(currentVersion),
                       primary: {
                           model.hide()
                           delegate.openWhatsNew()
                       },
                       close: { discardWhatsNew() })
        }
    }

    private static var thisBuild: Int {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
    }

    // MARK: - Private

    /// GitHub's API without a token allows 60 requests an hour, so the
    /// authors are kept between opens and only new pull requests and a few
    /// new people are asked for each time.
    private struct AuthorCache: Codable, Sendable {
        /// Pull request number → author login.
        var pullRequests: [Int: String] = [:]
        /// Login → avatar address.
        var avatars: [String: String] = [:]
        var people: [String: ReleaseNotesFormatter.Author] = [:]
    }

    nonisolated private struct PullRequest: Decodable, Sendable {
        nonisolated struct User: Decodable, Sendable {
            let login: String
            let avatarUrl: String
        }
        let number: Int
        let user: User?
    }

    nonisolated private struct Profile: Decodable, Sendable {
        let name: String?
    }

    private static let authorCacheFile = directory.appending(path: "authors.json")

    /// Who opened each pull request, for "Shipped by". Best effort: what
    /// cannot be downloaded (offline, or over the hourly limit) is left out.
    private static func fetchAuthors(updating cache: AuthorCache) async -> [Int: ReleaseNotesFormatter.Author] {
        var cache = cache
        // Most recently updated first, so a pull request merged since the
        // last fetch comes before the known ones, however old it is: stop at
        // the first page that reaches a known one.
        for page in 1...20 {
            guard let pullRequests: [PullRequest] = try? await get(
                "pulls?state=closed&sort=updated&direction=desc&per_page=100&page=\(page)"
            ) else { break }
            var reachedKnown = false
            for pullRequest in pullRequests {
                guard let user = pullRequest.user else { continue }
                reachedKnown = reachedKnown || cache.pullRequests[pullRequest.number] != nil
                cache.pullRequests[pullRequest.number] = user.login
                cache.avatars[user.login] = user.avatarUrl
            }
            if reachedKnown || pullRequests.count < 100 { break }
        }
        // A profile costs a request each, so a few per open, newest authors
        // first; until then a name shows as the login.
        var newLogins: [String] = []
        for number in cache.pullRequests.keys.sorted(by: >) {
            let login = cache.pullRequests[number]!
            guard cache.people[login] == nil, !newLogins.contains(login) else { continue }
            newLogins.append(login)
            if newLogins.count == profilesPerOpen { break }
        }
        await withTaskGroup(of: (String, Profile?).self) { group in
            for login in newLogins {
                group.addTask {
                    (login, try? await get("https://api.github.com/users/\(login)"))
                }
            }
            for await (login, profile) in group {
                // A failed profile is asked for again next time; a profile
                // without a name shows the login.
                guard let profile else { continue }
                let firstName = profile.name?.split(separator: " ").first.map(String.init) ?? login
                cache.people[login] = .init(name: firstName.isEmpty ? login : firstName,
                                            avatarURL: avatarURL(login: login, in: cache))
            }
        }
        if let data = try? JSONEncoder().encode(cache) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: authorCacheFile, options: .atomic)
        }
        return authors(in: cache)
    }

    private static func loadAuthorCache() -> AuthorCache {
        (try? Data(contentsOf: authorCacheFile))
            .flatMap { try? JSONDecoder().decode(AuthorCache.self, from: $0) } ?? AuthorCache()
    }

    /// Pull request number → author; a person whose profile is not known yet
    /// shows as their login.
    private static func authors(in cache: AuthorCache) -> [Int: ReleaseNotesFormatter.Author] {
        cache.pullRequests.compactMapValues { login in
            cache.people[login] ?? cache.avatars[login].map { _ in
                .init(name: login, avatarURL: avatarURL(login: login, in: cache))
            }
        }
    }

    /// GitHub's avatar address for `login`, at twice the 24-point size shown.
    private static func avatarURL(login: String, in cache: AuthorCache) -> String {
        var components = URLComponents(string: cache.avatars[login] ?? "https://github.com/\(login).png")!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "s" }
            + [URLQueryItem(name: "s", value: "96")]
        return components.string!
    }

    private static let profilesPerOpen = 10

    /// A GET on the repository's API (or a full API address), decoded off
    /// the main actor: a page of pull requests is a megabyte or two.
    nonisolated private static func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        let url = URL(string: path, relativeTo: repositoryAPI)!.absoluteURL
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// Ends in "/" so relative paths resolve inside it.
    nonisolated private static let repositoryAPI = URL(string: "https://api.github.com/repos/pluk-inc/markdown-preview/")!

    nonisolated private struct Release: Decodable, Sendable {
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
    }

    /// Every release, newest first, 100 to a page (GitHub's most).
    nonisolated private static func fetchReleases() async throws -> [ReleaseNotesFormatter.Release] {
        var releases: [Release] = []
        for page in 1...10 {
            let batch: [Release] = try await get("releases?per_page=100&page=\(page)")
            releases += batch
            if batch.count < 100 { break }
        }
        return releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release in
                guard let date = release.publishedAt, release.tagName.hasPrefix("v") else { return nil }
                return ReleaseNotesFormatter.Release(version: String(release.tagName.dropFirst()),
                                                     name: release.name, date: date,
                                                     body: release.body ?? "")
            }
    }
}
