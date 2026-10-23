//
//  ShareLinkStore.swift
//  md-preview
//
//  The links this Mac created. Secrets (link key, owner token)
//  live in the Keychain, one item per share; the list without secrets lives
//  in Application Support. Expired entries drop out when the list loads.
//

import Foundation
import Security

/// Windows learn about changes through `didChangeNotification`.
@MainActor
final class ShareLinkStore {

    static let shared = ShareLinkStore()

    struct Record: Codable, Equatable {
        let id: String
        var title: String
        /// Standardized path of the shared file, to find its link again.
        let filePath: String
        let createdAt: Date
        var expiresAt: Date
    }

    struct Secrets: Codable, Equatable {
        /// base64url of the 32-byte link key.
        let key: String
        let ownerToken: String
    }

    private(set) var records: [Record] = []
    private let fileURL: URL

    init(fileURL: URL = ShareLinkStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("SharedLinks", isDirectory: true)
            .appendingPathComponent("links.json")
    }

    func record(forFile url: URL) -> Record? {
        let path = url.standardizedFileURL.path
        return records.first { $0.filePath == path && $0.expiresAt > .now }
    }

    func secrets(for record: Record) -> Secrets? {
        ShareLinkKeychain.read(account: record.id)
            .flatMap { try? JSONDecoder().decode(Secrets.self, from: $0) }
    }

    /// Replaces any earlier record for the same file, so `record(forFile:)`
    /// finds this one; an older record whose secrets were lost would hide it.
    func add(_ record: Record, secrets: Secrets) throws {
        try ShareLinkKeychain.write(JSONEncoder().encode(secrets), account: record.id)
        for replaced in records where replaced.filePath == record.filePath && replaced.id != record.id {
            ShareLinkKeychain.delete(account: replaced.id)
        }
        let previous = records
        records.removeAll { $0.id == record.id || $0.filePath == record.filePath }
        records.append(record)
        do {
            try save()
        } catch {
            // A record that is not on disk is lost on the next launch; the
            // caller revokes the link instead.
            records = previous
            ShareLinkKeychain.delete(account: record.id)
            throw error
        }
    }

    func update(_ record: Record) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        saveLogging()
    }

    func remove(id: String) {
        ShareLinkKeychain.delete(account: id)
        records.removeAll { $0.id == id }
        saveLogging()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Record].self, from: data)
        else { return }
        let now = Date.now
        for expired in stored where expired.expiresAt <= now {
            ShareLinkKeychain.delete(account: expired.id)
        }
        records = stored.filter { $0.expiresAt > now }
        if records.count != stored.count { saveLogging() }
    }

    /// Posted after the list changes, so windows can update their subtitle.
    static let didChangeNotification = Notification.Name("ShareLinkStoreDidChange")

    private func save() throws {
        defer { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }

    /// For changes that leave nothing unmanaged if they are not saved: a
    /// later expiry, or a link that is already revoked.
    private func saveLogging() {
        do {
            try save()
        } catch {
            NSLog("ShareLinkStore: could not save the link list: \(error)")
        }
    }
}

/// Generic-password items under one service, keyed by share ID.
nonisolated enum ShareLinkKeychain {

    static let service = "doc.md-preview.share-link"

    static func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, account: String) throws {
        delete(account: account)
        var item = baseQuery(account: account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
