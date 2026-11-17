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

    /// What the extension list says about Markdown files right now.
    private struct Scan {
        let ownIdentifier: String
        let ownIsOff: Bool
        let competitors: [QuickLookExtension]
    }

    private func scan() throws -> Scan {
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
        return Scan(
            ownIdentifier: ownIdentifier,
            ownIsOff: extensions.contains { $0.identifier == ownIdentifier && $0.election == .ignore },
            competitors: competitors
        )
    }

    /// Writes the state for the main app, which cannot ask `pluginkit`
    /// itself: the apps that compete with ours, and the ones this helper
    /// turned off. A failed scan removes the file, so the main app shows
    /// nothing rather than an old answer.
    func writeStatus() {
        let file = Self.statusFile
        guard let scan = try? scan() else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let status: [String: [String]] = [
            "competitors": uniqueNames(scan.competitors.map(\.displayName)),
            "turnedOff": uniqueNames(turnedOff.entries.map(\.name)),
        ]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (status as NSDictionary).write(to: file)
    }

    /// `~/Library/Application Support/<helper bundle id>/status.plist`. The
    /// main app builds the same path from the helper's bundle id.
    private static let statusFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "quick-look-setup")
        .appendingPathComponent("status.plist")

    private func converse() throws {
        let scan = try scan()
        let earlier = turnedOff.entries

        if !scan.competitors.isEmpty {
            try offerToUse(scan, earlier: earlier)
            return
        }

        // Nothing competes. Ours can still be off, from System Settings.
        if scan.ownIsOff {
            try PlugInKit.setElection(.use, forIdentifier: scan.ownIdentifier)
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
        String(format: L("These extensions were turned off for it:\n\n%@"),
               uniqueNames(earlier.map(\.name)).map { "• \($0)" }.joined(separator: "\n"))
    }

    private func turnBackOn(_ earlier: [TurnedOffExtensions.Entry]) throws {
        for entry in earlier {
            try PlugInKit.setElection(entry.election, forIdentifier: entry.identifier)
            turnedOff.remove(entry.identifier)
        }
        PlugInKit.restartQuickLook()
    }

    /// The question the system asks for a default web browser, for Quick
    /// Look: keep the current app, or use ours.
    ///
    /// `earlier` is not empty when a new competitor arrived after an earlier
    /// visit, or a change failed part of the way through. The way back must
    /// stay open then, so the same alert offers it.
    private func offerToUse(_ scan: Scan, earlier: [TurnedOffExtensions.Entry]) throws {
        let names = uniqueNames(scan.competitors.map(\.displayName)).map(quoted)
        let list = ListFormatter()
        list.locale = Self.stringsLocale
        let others = list.string(from: names) ?? names.joined(separator: ", ")
        var information = String(
            format: L("%@ will no longer show Quick Look previews for any file type. You can turn this back on in Settings → Advanced in Markdown Preview."),
            others
        )
        if !earlier.isEmpty {
            information += "\n\n" + turnedOffList(earlier)
        }
        let alert = makeAlert(
            String(format: L("Do you want to use %1$@ for Quick Look previews of Markdown files, or keep using %2$@?"),
                   quoted(Self.hostName), others),
            information
        )
        alert.addButton(withTitle: String(format: L("Use %@"), quoted(Self.hostName)))
        alert.addButton(withTitle: names.count == 1 ? String(format: L("Keep %@"), names[0]) : L("Keep Current"))
        if !earlier.isEmpty {
            alert.addButton(withTitle: L("Turn Back On"))
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn: break
        case .alertThirdButtonReturn: return try turnBackOn(earlier)
        default: return
        }

        for competitor in scan.competitors {
            // Recorded before the change, so a failure part of the way
            // through still leaves every changed extension restorable.
            turnedOff.add(competitor)
            try PlugInKit.setElection(.ignore, forIdentifier: competitor.identifier)
        }
        try PlugInKit.setElection(.use, forIdentifier: scan.ownIdentifier)
        PlugInKit.restartQuickLook()
    }

    /// The name of the app this helper belongs to, as Finder shows it.
    private static let hostName = FileManager.default.displayName(atPath: hostApp.path)
        .replacingOccurrences(of: ".app", with: "")

    /// An app name in the quotation marks of the language the strings are in.
    private func quoted(_ name: String) -> String {
        let locale = Self.stringsLocale
        return (locale.quotationBeginDelimiter ?? "“") + name + (locale.quotationEndDelimiter ?? "”")
    }

    /// The language the strings are in, from the name of their `.lproj`
    /// folder. Lists and quotation marks follow it, not the process locale:
    /// the two differ when the system language has no translation here.
    private static let stringsLocale = strings.map {
        Locale(identifier: $0.bundleURL.deletingPathExtension().lastPathComponent)
    } ?? .current

    /// One entry per app. Two extensions of one app (or two copies of an
    /// app) show as one name.
    private func uniqueNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
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
