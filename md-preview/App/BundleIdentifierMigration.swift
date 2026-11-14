//
//  BundleIdentifierMigration.swift
//  md-preview
//
//  The app moved from the `doc.md-preview` bundle id to `sh.pluk.md-preview`
//  (another team holds the old App ID, and iCloud needs one of our own).
//  A sandboxed app's settings and files live in a container named after
//  its bundle id, so the first launch under the new id starts empty. This
//  copies the settings and the Application Support files over from the old
//  container, once, before anything reads them.
//
//  The old container stays as it is: the sandbox lets this app read it
//  (same team, plus the read-only filesystem exception) but not change it.
//
//  What does not move:
//  - Security-scoped bookmarks. They belong to the app that made them, so
//    the reader allows write access to a folder again.
//  - Keychain items. The share-link keys keep their service name; macOS
//    asks the reader once before this id may read a key the old id wrote.
//  - Caches, and File > Open Recent, which macOS keeps per bundle id.
//

import Foundation

nonisolated enum BundleIdentifierMigration {

    static let currentPrefix = "sh.pluk.md-preview"
    static let oldPrefix = "doc.md-preview"

    static let doneKey = "MarkdownPreview.didMigrateBundleIdentifier"
    /// Set when the release app moved, for the one-time check of the
    /// `md-preview` command, which starts the app by bundle id.
    static let commandLineToolCheckKey = "MarkdownPreview.shouldCheckCommandLineTool"
    /// Same key as `DocumentWindowController.didOfferDefaultHandlerKey`.
    static let defaultHandlerOfferKey = "MarkdownPreview.didOfferAsDefaultHandler"

    /// `ProjectNavigator.WriteAccessBookmarks`: bookmarks of the old id
    /// never resolve here, and an entry that does not resolve is kept.
    private static let skippedKeys: Set<String> = ["ProjectNavigator.WriteAccessBookmarks"]
    private static let skippedSupportItems: Set<String> = ["CrashReporter"]
    static let attemptsKey = "MarkdownPreview.bundleIdentifierMigrationAttempts"
    static let maximumAttempts = 3
    private static let partialSuffix = ".migrating"

    /// The id this copy had before the move: `sh.pluk.md-preview.dev` was
    /// `doc.md-preview.dev`. Nil for an id that is not ours.
    static func oldIdentifier(for identifier: String) -> String? {
        guard identifier == currentPrefix || identifier.hasPrefix(currentPrefix + ".") else { return nil }
        return oldPrefix + identifier.dropFirst(currentPrefix.count)
    }

    /// Call first in `main`, before anything reads a setting.
    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey),
              let identifier = Bundle.main.bundleIdentifier,
              let oldIdentifier = oldIdentifier(for: identifier),
              let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first
        else { return }
        let library = URL.realHomeDirectory.appendingPathComponent("Library", isDirectory: true)
        run(oldIdentifier: oldIdentifier,
            oldLibrary: library.appendingPathComponent("Containers/\(oldIdentifier)/Data/Library",
                                                       isDirectory: true),
            defaults: defaults,
            domainName: identifier,
            applicationSupport: support,
            launchServicesPreferences: library.appendingPathComponent(
                "Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"))
    }

    /// Never replaces a setting or a file the new id already has. Files go
    /// first and the done mark last, so a run cut short starts again at the
    /// next launch and copies what is missing.
    static func run(oldIdentifier: String,
                    oldLibrary: URL,
                    defaults: UserDefaults,
                    domainName: String,
                    applicationSupport: URL,
                    launchServicesPreferences: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: oldLibrary.path) else {
            // A new install: nothing to bring, and nothing to look for again.
            defaults.set(true, forKey: doneKey)
            return
        }
        let preferencesURL = oldLibrary.appendingPathComponent("Preferences/\(oldIdentifier).plist")
        var oldSettings: [String: Any] = [:]
        if fileManager.fileExists(atPath: preferencesURL.path) {
            // Unreadable now may be readable later: leave the mark unset.
            guard let stored = NSDictionary(contentsOf: preferencesURL) as? [String: Any] else { return }
            oldSettings = stored
        }

        // A file that did not copy gets the next launches to try again,
        // with the settings still unread so a later run changes nothing the
        // reader set since. After the last attempt the settings move anyway.
        let attempt = defaults.integer(forKey: attemptsKey) + 1
        let copied = copySupportItems(
            from: oldLibrary.appendingPathComponent("Application Support", isDirectory: true),
            to: applicationSupport)
        if !copied && attempt < maximumAttempts {
            defaults.set(attempt, forKey: attemptsKey)
            return
        }
        defaults.removeObject(forKey: attemptsKey)

        var skipped = skippedKeys
        if isDefaultHandler(oldIdentifier, in: launchServicesPreferences) {
            // The reader's choice of default app names the old id, so the
            // offer to open Markdown files runs once more.
            skipped.insert(defaultHandlerOfferKey)
        }
        let present = defaults.persistentDomain(forName: domainName) ?? [:]
        for (key, value) in oldSettings where present[key] == nil && !skipped.contains(key) {
            defaults.set(value, forKey: key)
        }
        if oldIdentifier == oldPrefix {
            defaults.set(true, forKey: commandLineToolCheckKey)
        }
        defaults.set(true, forKey: doneKey)
    }

    /// False when an item is missing at the destination afterwards. Each
    /// item is copied beside its place and renamed into it, so a copy cut
    /// short never leaves half a folder that the next run takes for whole.
    private static func copySupportItems(from source: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return true }
        guard let items = try? fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return false }
        try? fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var copiedAll = true
        for item in items where !skippedSupportItems.contains(item.lastPathComponent) {
            // The container links some folders to the reader's Library.
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard !isLink, !fileManager.fileExists(atPath: target.path) else { continue }
            let partial = destination.appendingPathComponent(item.lastPathComponent + partialSuffix)
            try? fileManager.removeItem(at: partial)
            do {
                try fileManager.copyItem(at: item, to: partial)
                try fileManager.moveItem(at: partial, to: target)
            } catch {
                NSLog("BundleIdentifierMigration: could not copy \(item.lastPathComponent): \(error)")
                try? fileManager.removeItem(at: partial)
                copiedAll = false
            }
        }
        return copiedAll
    }

    /// True when the reader chose `identifier` to open a file type.
    static func isDefaultHandler(_ identifier: String, in launchServicesPreferences: URL) -> Bool {
        guard let handlers = NSDictionary(contentsOf: launchServicesPreferences)?["LSHandlers"]
                as? [[String: Any]] else { return false }
        let roles = ["LSHandlerRoleAll", "LSHandlerRoleViewer", "LSHandlerRoleEditor"]
        return handlers.contains { handler in
            handler["LSHandlerContentType"] != nil && roles.contains {
                (handler[$0] as? String)?.caseInsensitiveCompare(identifier) == .orderedSame
            }
        }
    }

    // MARK: - Command line tool

    /// The line that starts the app in the `md-preview` command of a release
    /// before the move. The installer replaces a command that has it.
    static let outdatedLauncherMarker = "exec open -b \"\(oldPrefix)\""

    /// The `md-preview` command a release before the move installed: it
    /// starts the app by the old bundle id, which no app has any more.
    static func hasOutdatedCommandLineTool(in directories: [URL]) -> Bool {
        directories.contains { directory in
            ["md-preview", "markdown-preview"].contains { name in
                let url = directory.appendingPathComponent(name)
                guard let script = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return script.contains(outdatedLauncherMarker)
            }
        }
    }
}
