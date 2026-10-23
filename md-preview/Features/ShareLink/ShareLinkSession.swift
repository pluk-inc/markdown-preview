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
    }

    static let expiry = ShareLinkClient.Expiry.week

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
        guard let baseURL = ShareLinkFeature.baseURL else { throw Failure.notConfigured }
        let client = ShareLinkClient(baseURL: baseURL)
        let fileURL = fileURL.standardizedFileURL

        // The app's own renderer, so the web viewer shows what the app shows.
        let html = MarkdownHTML.render(markdown: markdown).articleHTML
        let assets = ShareLinkAssets.collect(articleHTML: html,
                                             directory: fileURL.deletingLastPathComponent())
        let payload = SharePayload(title: fileURL.lastPathComponent, markdown: markdown,
                                   html: html, assets: assets)

        if var record = store.record(forFile: fileURL),
           let secrets = store.secrets(for: record),
           let key = Base64URL.decode(secrets.key) {
            do {
                let envelope = try await seal(payload, key: key)
                record.expiresAt = try await client.update(id: record.id, envelope: envelope,
                                                           ownerToken: secrets.ownerToken,
                                                           expiry: expiry)
                record.title = payload.title
                store.update(record)
                return try webLink(id: record.id, key: key, base: baseURL)
            } catch ShareLinkClient.Failure.notFound {
                // Gone from the server; make a new link below.
                store.remove(id: record.id)
            }
        }

        let key = ShareLinkCrypto.randomKey()
        let envelope = try await seal(payload, key: key)
        let created = try await client.create(envelope, expiry: expiry)
        let record = ShareLinkStore.Record(id: created.id, title: payload.title,
                                           filePath: fileURL.path, createdAt: .now,
                                           expiresAt: created.expiresAt)
        try store.add(record, secrets: .init(key: Base64URL.encode(key),
                                             ownerToken: created.ownerToken))
        return try webLink(id: created.id, key: key, base: baseURL)
    }

    /// Deletes the file's link on the server and forgets it here. A link the
    /// server no longer has is already stopped.
    static func stopSharing(fileURL: URL, store: ShareLinkStore = .shared) async throws {
        guard let record = store.record(forFile: fileURL) else { return }
        if let baseURL = ShareLinkFeature.baseURL, let secrets = store.secrets(for: record) {
            do {
                try await ShareLinkClient(baseURL: baseURL)
                    .delete(id: record.id, ownerToken: secrets.ownerToken)
            } catch ShareLinkClient.Failure.notFound {
            }
        }
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
        default:
            L("Markdown Preview could not reach the sharing server. Try again later.")
        }
    }

    // MARK: - Private

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
