import AppKit

/// Shared by the renderer, document windows, and Quick Look.
nonisolated enum ExternalLinkPolicy {
    static let blockedSchemes = ["javascript", "vbscript", "data", "file", "about", "blob", "filesystem", "md-asset"]
    static let defaultsKey = "MarkdownPreview.approvedLinkSchemes"
    static let generationKey = defaultsKey + ".generation"

    enum Decision: Equatable { case blocked, open, confirm }

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        return !blockedSchemes.contains(scheme)
    }

    static func decision(for url: URL, defaults: UserDefaults?) -> Decision {
        guard isExternal(url), let scheme = url.scheme?.lowercased() else { return .blocked }
        if ["http", "https", "mailto", "md-preview"].contains(scheme)
            || (defaults?.bool(forKey: approvalKey(for: scheme, defaults: defaults)) ?? false) {
            return .open
        }
        return .confirm
    }

    static func remember(_ url: URL, defaults: UserDefaults?) {
        guard isExternal(url), let scheme = url.scheme?.lowercased() else { return }
        defaults?.set(true, forKey: approvalKey(for: scheme, defaults: defaults))
    }

    /// Separate keys avoid read-modify-write races between the app and Quick Look.
    /// Reset rotates the namespace: a writer holding an old key cannot restore it.
    static func approvalKey(for scheme: String, defaults: UserDefaults?) -> String {
        let generation = defaults?.string(forKey: generationKey) ?? "initial"
        return defaultsKey + "." + generation + "." + scheme.lowercased()
    }

    static func reset(defaults: UserDefaults?) {
        defaults?.set(UUID().uuidString, forKey: generationKey)
    }
}

@MainActor
enum ExternalLinkOpener {
    /// Called only for an explicit link activation or the Open Link menu action.
    static func open(_ url: URL, window: NSWindow?) {
        let defaults = AppearanceMode.sharedDefaults()
        let decision = ExternalLinkPolicy.decision(for: url, defaults: defaults)
        guard decision != .blocked else { return }
        if decision == .open {
            NSWorkspace.shared.open(url)
            return
        }
        guard window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            alert.messageText = NSLocalizedString("No application can open this link", comment: "External link")
            alert.informativeText = url.absoluteString
            alert.addButton(withTitle: NSLocalizedString("OK", comment: "External link"))
            if let window { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
            return
        }
        let appName = FileManager.default.displayName(atPath: application.path)
        alert.messageText = String(format: NSLocalizedString("Allow this document to open “%@”?", comment: "External link"), appName)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "External link"))
        alert.addButton(withTitle: NSLocalizedString("Allow", comment: "External link"))
        let alwaysAllow = alert.addButton(withTitle: NSLocalizedString("Always Allow", comment: "External link"))
        alwaysAllow.toolTip = String(format: NSLocalizedString("Allow all %@: links in documents and Quick Look.", comment: "External link"), url.scheme!.lowercased())
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else { return }
            if response == .alertThirdButtonReturn {
                ExternalLinkPolicy.remember(url, defaults: defaults)
            }
            NSWorkspace.shared.open(url)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }
}
