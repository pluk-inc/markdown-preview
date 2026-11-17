//
//  QuickLookSetup.swift
//  quick-look-setup
//
//  The one conversation the helper has with the user: turn the competing
//  extensions off, or turn the ones it turned off earlier back on.
//

import AppKit
import UniformTypeIdentifiers

struct QuickLookSetup {
    /// The Markdown Preview app this helper is embedded in:
    /// `<app>/Contents/Helpers/<helper>.app`.
    private static let hostApp = Bundle.main.bundleURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private let turnedOff = TurnedOffExtensions()

    func run() {
        do {
            try converse()
        } catch {
            show(L("The Quick Look extensions could not be changed."), error.localizedDescription)
        }
    }

    private func converse() throws {
        // Found by what it is, not by its file name, so a renamed extension
        // target still resolves.
        let plugIns = Bundle(url: Self.hostApp)?.builtInPlugInsURL
        let candidates = plugIns.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
        guard let plugIns,
              let ownPath = candidates.map({ plugIns.appendingPathComponent($0).path })
                  .first(where: QuickLookExtensionScan.isPreviewExtension(at:)),
              let ownIdentifier = Bundle(path: ownPath)?.bundleIdentifier
        else {
            throw PlugInKit.Failure(message: Self.hostApp.path)
        }
        let ownContentTypes = Set(QuickLookExtensionScan.supportedContentTypes(ofExtensionAt: ownPath))

        let extensions = try PlugInKit.previewExtensions()
        let competitors = QuickLookExtensionScan.competitors(
            in: extensions,
            ownIdentifier: ownIdentifier,
            ownContentTypes: ownContentTypes,
            contentTypes: { QuickLookExtensionScan.supportedContentTypes(ofExtensionAt: $0.path) },
            conforms: { type, ownType in
                guard let type = UTType(type), let ownType = UTType(ownType) else { return false }
                return type.conforms(to: ownType)
            }
        )
        let earlier = turnedOff.entries

        if !competitors.isEmpty {
            try offerToTurnOff(competitors, ownIdentifier: ownIdentifier, earlier: earlier)
            return
        }

        // Nothing competes. Ours can still be off, from System Settings.
        if extensions.contains(where: { $0.identifier == ownIdentifier && $0.election == .ignore }) {
            try PlugInKit.setElection(.use, forIdentifier: ownIdentifier)
            PlugInKit.restartQuickLook()
        }

        let onlyOne = L("Markdown Preview is the only Quick Look extension turned on for Markdown files.")
        guard !earlier.isEmpty else {
            show(onlyOne)
            return
        }
        let alert = makeAlert(onlyOne, turnedOffList(earlier))
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Turn Back On"))
        if alert.runModal() == .alertSecondButtonReturn {
            try turnBackOn(earlier)
        }
    }

    private func turnedOffList(_ earlier: [TurnedOffExtensions.Entry]) -> String {
        String(format: L("These extensions were turned off for it:\n\n%@"), bulletList(earlier.map(\.name)))
    }

    private func turnBackOn(_ earlier: [TurnedOffExtensions.Entry]) throws {
        for entry in earlier {
            try PlugInKit.setElection(entry.election, forIdentifier: entry.identifier)
            turnedOff.remove(entry.identifier)
        }
        PlugInKit.restartQuickLook()
        show(L("The other Quick Look extensions are on again."))
    }

    /// `earlier` is not empty when a new competitor arrived after an earlier
    /// visit, or a change failed part of the way through. The way back must
    /// stay open then, so the same alert offers it.
    private func offerToTurnOff(
        _ competitors: [QuickLookExtension], ownIdentifier: String, earlier: [TurnedOffExtensions.Entry]
    ) throws {
        var information = String(
            format: L("macOS shows the preview from only one Quick Look extension for each file type, and has no setting to choose which one. To let Markdown Preview show the preview, these extensions must be turned off:\n\n%@\n\nThis turns off their previews for all file types. You can turn them on again from Settings → Advanced in Markdown Preview."),
            bulletList(competitors.map(\.displayName))
        )
        if !earlier.isEmpty {
            information += "\n\n" + turnedOffList(earlier)
        }
        let alert = makeAlert(L("Use Markdown Preview for Quick Look previews of Markdown files?"), information)
        alert.addButton(withTitle: L("Turn Off"))
        alert.addButton(withTitle: L("Cancel"))
        if !earlier.isEmpty {
            alert.addButton(withTitle: L("Turn Back On"))
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertThirdButtonReturn: return try turnBackOn(earlier)
        default: return
        }

        for competitor in competitors {
            // Recorded before the change, so a failure part of the way
            // through still leaves every changed extension restorable.
            turnedOff.add(competitor)
            try PlugInKit.setElection(.ignore, forIdentifier: competitor.identifier)
        }
        try PlugInKit.setElection(.use, forIdentifier: ownIdentifier)
        PlugInKit.restartQuickLook()
        show(
            L("Markdown Preview now shows the Quick Look preview for Markdown files."),
            L("Finder shows the new preview the next time you press Space on a Markdown file.")
        )
    }

    // MARK: - Alerts

    private func makeAlert(_ message: String, _ information: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.icon = NSWorkspace.shared.icon(forFile: Self.hostApp.path)
        return alert
    }

    private func show(_ message: String, _ information: String = "") {
        let alert = makeAlert(message, information)
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }

    /// One line per app. Two extensions of one app (or two copies of an app)
    /// show as one name.
    private func bulletList(_ names: [String]) -> String {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { "• \($0)" }.joined(separator: "\n")
    }

    // MARK: - Strings

    /// The helper has no strings of its own: they live in the main app's
    /// `Localizable.strings`, so they go through the same translation flow.
    /// The helper's own bundle is English only, and Foundation matches the
    /// languages of any other bundle against the main bundle's, so the
    /// language is picked here: the user's list against the ones the app
    /// ships.
    private func L(_ key: String) -> String {
        Self.strings?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    private static let strings: Bundle? = {
        guard let host = Bundle(url: hostApp),
              let language = Bundle.preferredLocalizations(
                  from: host.localizations, forPreferences: Locale.preferredLanguages
              ).first,
              let path = host.path(forResource: language, ofType: "lproj")
        else { return nil }
        return Bundle(path: path)
    }()
}

/// The extensions this helper turned off, with the election each had before,
/// so "Turn Back On" restores the user's own choice and never touches an
/// extension the user turned off in System Settings.
struct TurnedOffExtensions {
    struct Entry {
        let identifier: String
        let name: String
        let election: QuickLookExtension.Election
    }

    private let defaults = UserDefaults.standard
    private let key = "turnedOffExtensions"

    var entries: [Entry] {
        stored.compactMap { identifier, value in
            guard let name = value["name"], let election = value["election"].flatMap(QuickLookExtension.Election.init)
            else { return nil }
            return Entry(identifier: identifier, name: name, election: election)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func add(_ competitor: QuickLookExtension) {
        var stored = stored
        // An extension already listed keeps its first record: that one holds
        // the election from before this helper changed anything.
        guard stored[competitor.identifier] == nil else { return }
        stored[competitor.identifier] = ["name": competitor.displayName, "election": competitor.election.rawValue]
        defaults.set(stored, forKey: key)
    }

    func remove(_ identifier: String) {
        var stored = stored
        stored[identifier] = nil
        defaults.set(stored, forKey: key)
    }

    private var stored: [String: [String: String]] {
        defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
    }
}
