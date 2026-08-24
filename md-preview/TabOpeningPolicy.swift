//
//  TabOpeningPolicy.swift
//  md-preview
//
//  Decides whether a document being opened joins the front window as a tab or
//  gets a window of its own. Kept free of AppKit so the SPM helper tests can
//  exercise it without a GUI host.
//

import Foundation

enum TabOpeningPolicy {
    /// Mirrors `NSWindow.TabbingPreference`, which the controller translates at
    /// the call site. Restated here so the decision stays testable.
    enum SystemPreference {
        case manual
        case inFullScreen
        case always
    }

    /// - Parameters:
    ///   - isExplicitTabRequest: The open came from "Open in New Tab", ⌘T, or
    ///     the tab bar's "+", which asks for a tab whatever anything else says.
    ///   - opensDocumentsInTabs: This app's own preference — the reader wants
    ///     one Markdown Preview window with the documents inside it.
    ///   - systemPreference: macOS's "Prefer tabs when opening documents".
    ///   - hostIsFullScreen: Whether the window that would host the tab is in
    ///     full screen, which is the only thing `inFullScreen` turns on.
    static func joinsExistingTabGroup(isExplicitTabRequest: Bool,
                                      opensDocumentsInTabs: Bool,
                                      systemPreference: SystemPreference,
                                      hostIsFullScreen: Bool) -> Bool {
        if isExplicitTabRequest || opensDocumentsInTabs { return true }
        switch systemPreference {
        case .always: return true
        case .inFullScreen: return hostIsFullScreen
        case .manual: return false
        }
    }

    // MARK: - Storage

    /// The app's own preference, deliberately additive to the system one: it
    /// can only turn tabbing *on*. Someone who has set macOS to always prefer
    /// tabs already gets them, and "Open in New Window" still opens a window —
    /// an explicit request for one window beats a standing preference for none.
    static let defaultsKey = "MarkdownPreview.opensDocumentsInTabs"

    static var isEnabled: Bool {
        get { read(from: .standard) }
        set { write(newValue, to: .standard) }
    }

    static func read(from defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }

    /// Off clears the key rather than storing `false`, as the other
    /// preferences do: an untouched preference leaves no trace.
    static func write(_ isEnabled: Bool, to defaults: UserDefaults?) {
        if isEnabled {
            defaults?.set(true, forKey: defaultsKey)
        } else {
            defaults?.removeObject(forKey: defaultsKey)
        }
    }
}
