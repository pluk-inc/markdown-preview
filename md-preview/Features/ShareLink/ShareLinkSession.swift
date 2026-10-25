//
//  ShareLinkSession.swift
//  md-preview
//
//  The Share popover's "Copy Link": seals the open document, uploads it,
//  and returns its link. A file that already has a live link keeps it; the
//  content behind it is replaced. No options: links last 7 days, have no
//  password, and carry the document's local images when they fit.
//

import AppKit

/// The hidden switch and the server address. Ships off until the Worker
/// runs in production (docs/share-link-plan.md §4.6).
enum ShareLinkFeature {
    static let enabledDefaultsKey = "MarkdownPreview.shareLinksEnabled"
    /// Overrides the server, e.g. a staging Worker.
    static let baseURLDefaultsKey = "MarkdownPreview.shareLinkBaseURL"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey) && baseURL != nil
    }

    static var baseURL: URL? {
        let configured = UserDefaults.standard.string(forKey: baseURLDefaultsKey)
            ?? Bundle.main.object(forInfoDictionaryKey: "ShareLinkBaseURL") as? String
        if let configured, !configured.isEmpty { return URL(string: configured) }
#if DEBUG
        // `npm run dev` in server/share-worker.
        return URL(string: "http://localhost:8787")
#else
        // The Worker's routes on md-preview.app (server/share-worker/wrangler.jsonc).
        return URL(string: "https://md-preview.app")
#endif
    }
}

@MainActor
enum ShareLinkSession {

    enum Failure: Error {
        /// No server address: the feature is off in this build.
        case notConfigured
        /// The file has a live link, but its owner token is gone, so the
        /// link can neither be updated nor stopped until it expires.
        case lostCredentials(expiresAt: Date)
    }

    static let expiry = ShareLinkClient.Expiry.week

    /// One job per file: two windows of the same file must not both create
    /// a share, or the later one would drop the earlier one's owner token.
    private static var jobs: [String: Task<URL, Error>] = [:]

    /// Creates or refreshes the link for `fileURL` and puts it on the
    /// clipboard, unless the task was cancelled while it uploaded.
    static func copyLink(forFile fileURL: URL, markdown: String) async throws {
        let link = try await link(forFile: fileURL, markdown: markdown)
        try Task.checkCancellation()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }

    /// The link for `fileURL`, created or refreshed with `markdown`.
    static func link(forFile fileURL: URL,
                     markdown: String,
                     store: ShareLinkStore = .shared) async throws -> URL {
        let path = fileURL.standardizedFileURL.path
        // Each job waits for the one before it, so a second window's request
        // runs after the first finishes instead of polling it.
        let previous = jobs[path]
        let job = Task {
            _ = try? await previous?.value
            return try await makeLink(forFile: fileURL, markdown: markdown, store: store)
        }
        jobs[path] = job
        defer { if jobs[path] == job { jobs[path] = nil } }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private static func makeLink(forFile fileURL: URL,
                                 markdown: String,
                                 store: ShareLinkStore) async throws -> URL {
        guard let baseURL = ShareLinkFeature.baseURL else { throw Failure.notConfigured }
        let client = ShareLinkClient(baseURL: baseURL)
        let fileURL = fileURL.standardizedFileURL
        let payload = await makePayload(fileURL: fileURL, markdown: markdown)

        if var record = store.record(forFile: fileURL) {
            // Without the owner token the old link can be neither updated
            // nor revoked; replacing it would leave it live and unmanaged.
            guard let secrets = store.secrets(for: record) else {
                throw Failure.lostCredentials(expiresAt: record.expiresAt)
            }
            // A key of the wrong length cannot seal either: treat it as damaged.
            if let key = Base64URL.decode(secrets.key), key.count == ShareLinkCrypto.keyByteCount {
                do {
                    let envelope = try await seal(payload, key: key)
                    record.expiresAt = try await client.update(id: record.id, envelope: envelope,
                                                               ownerToken: secrets.ownerToken,
                                                               expiry: expiry)
                    store.update(record)
                    return try webLink(id: record.id, key: key, base: baseURL)
                } catch ShareLinkClient.Failure.notFound {
                    // Gone from the server; make a new link below.
                }
            } else {
                // A damaged key cannot seal; revoke the old link before
                // replacing it, while its owner token still exists.
                try await revoke(record.id, ownerToken: secrets.ownerToken, client: client)
            }
            store.remove(id: record.id)
        }

        let key = ShareLinkCrypto.randomKey()
        let envelope = try await seal(payload, key: key)
        try Task.checkCancellation()
        let created = try await client.create(envelope, expiry: expiry)
        let record = ShareLinkStore.Record(id: created.id, filePath: fileURL.path,
                                           expiresAt: created.expiresAt)
        do {
            try store.add(record, secrets: .init(key: Base64URL.encode(key),
                                                 ownerToken: created.ownerToken))
        } catch {
            // A link this Mac cannot remember could never be stopped.
            try? await revoke(created.id, ownerToken: created.ownerToken, client: client)
            throw error
        }
        return try webLink(id: created.id, key: key, base: baseURL)
    }

    /// Deletes the file's link on the server and forgets it here. A link the
    /// server no longer has is already stopped.
    static func stopSharing(fileURL: URL, store: ShareLinkStore = .shared) async throws {
        guard let record = store.record(forFile: fileURL) else { return }
        guard let baseURL = ShareLinkFeature.baseURL else { throw Failure.notConfigured }
        guard let secrets = store.secrets(for: record) else {
            throw Failure.lostCredentials(expiresAt: record.expiresAt)
        }
        try await revoke(record.id, ownerToken: secrets.ownerToken,
                         client: ShareLinkClient(baseURL: baseURL))
        store.remove(id: record.id)
    }

    static func message(for error: Error) -> String {
        switch error {
        case ShareLinkCrypto.Failure.tooLarge, ShareLinkClient.Failure.tooLarge:
            L("This document is too large to share as a link.")
        case ShareLinkClient.Failure.rateLimited:
            L("Too many links in a short time. Wait a minute, then try again.")
        case let error as URLError where error.code == .notConnectedToInternet:
            L("You are offline. Connect to the internet, then try again.")
        case Failure.lostCredentials(let expiresAt):
            String(format: L("Markdown Preview lost the key that manages this link, so it cannot change or stop it. The link stops working on %@."),
                   expiresAt.formatted(date: .abbreviated, time: .shortened))
        default:
            L("Markdown Preview could not reach the sharing server. Try again later.")
        }
    }

    // MARK: - Private

    private static func revoke(_ id: String, ownerToken: String, client: ShareLinkClient) async throws {
        do {
            try await client.delete(id: id, ownerToken: ownerToken)
        } catch ShareLinkClient.Failure.notFound {
            // Already gone from the server.
        }
    }

    /// Renders with the app's own renderer, so the web viewer shows what the
    /// app shows, and reads the local images it uses. Off the main thread:
    /// a long document or images on a slow volume would freeze the window.
    private static func makePayload(fileURL: URL, markdown: String) async -> SharePayload {
        await Task.detached(priority: .userInitiated) {
            let html = MarkdownHTML.render(markdown: markdown).articleHTML
            let assets = ShareLinkAssets.collect(articleHTML: html,
                                                 directory: fileURL.deletingLastPathComponent())
            return SharePayload(title: fileURL.lastPathComponent, markdown: markdown,
                                html: html, assets: assets)
        }.value
    }

    /// Built from the key in hand, so the Keychain is not read back.
    private static func webLink(id: String, key: Data, base: URL) throws -> URL {
        guard let link = ShareLink(id: id, key: key, hasPassword: false) else {
            throw ShareLinkClient.Failure.invalidResponse
        }
        return link.webURL(base: base)
    }

    /// Encodes and seals off the main thread (PBKDF2, DEFLATE, and base64
    /// images are all slow). When the images push the envelope over the
    /// upload limit, the link carries the text alone.
    private static func seal(_ payload: SharePayload, key: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            do {
                return try ShareLinkCrypto.seal(payload.encoded(), key: key, password: nil)
            } catch ShareLinkCrypto.Failure.tooLarge where !payload.assets.isEmpty {
                let textOnly = SharePayload(title: payload.title, markdown: payload.markdown,
                                            html: payload.html, assets: [])
                return try ShareLinkCrypto.seal(textOnly.encoded(), key: key, password: nil)
            }
        }.value
    }
}
