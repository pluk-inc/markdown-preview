//
//  AlwaysOnTopPolicy.swift
//  md-preview
//
//  Decision logic and storage behind the "Always on Top" setting. Kept free of
//  AppKit so the SPM helper tests can exercise it without a GUI host.
//

import CoreGraphics
import Foundation

enum AlwaysOnTopPolicy {
    /// Raw `NSWindow.Level` value a document window takes for a given pinned
    /// state.
    ///
    /// Pinned windows sit at the floating level, which keeps them above the
    /// windows of *other* applications. That is the entire point here, and it
    /// is deliberately the opposite of `MermaidDiagramPopup`, whose panel
    /// stays at the normal level so a diagram never escapes the app it
    /// belongs to. Both choices are intentional: the diagram popup follows the
    /// document, whereas this window is one the reader has explicitly asked to
    /// keep in sight while working in something else.
    /// - Parameters:
    ///   - isPinned: Whether the reader has asked to keep windows in sight.
    ///   - isFullScreen: Whether the window is currently full screen. AppKit
    ///     will not let a window above the normal level go full screen, so a
    ///     pinned window loses Enter Full Screen and its green traffic light.
    ///     A full-screen window owns its own Space, where floating above other
    ///     applications means nothing, so the pin is suspended for the duration
    ///     rather than fought with. It is kept as *intent* by the setting and
    ///     reapplied on the way out. Required rather than defaulted: a caller
    ///     that forgets it reintroduces exactly the bug this parameter exists
    ///     to prevent.
    static func windowLevel(isPinned: Bool, isFullScreen: Bool) -> Int {
        let floats = isPinned && !isFullScreen
        return Int(CGWindowLevelForKey(floats ? .floatingWindow : .normalWindow))
    }

    /// Raw `NSWindow.Level` value the Settings window takes.
    ///
    /// Settings sits one step above whatever the preview windows are using, so
    /// the window you change a preference in cannot be buried by the windows
    /// that preference applies to — which is otherwise exactly what happens the
    /// moment Always on Top is on. It drops back to the normal level when the
    /// pin is off: Settings floating above every other application is a side
    /// effect nobody asked for, and this app only earns that while the reader
    /// has explicitly asked its windows to stay in front.
    static func settingsWindowLevel(isPinned: Bool) -> Int {
        guard isPinned else { return Int(CGWindowLevelForKey(.normalWindow)) }
        return windowLevel(isPinned: true, isFullScreen: false) + 1
    }

    // MARK: - Storage

    /// Always on Top is a way of *reading*, not a property of one document:
    /// someone who wants a checklist in sight while working elsewhere wants it
    /// for whichever document is open, not for the one window they happened to
    /// toggle. So a single stored value drives every preview window — the ones
    /// already open, the ones opened later, and the ones opened after a
    /// relaunch — and the toolbar and menu affordances read and write it.
    static let defaultsKey = "MarkdownPreview.alwaysOnTop"

    static var isEnabled: Bool {
        get { read(from: .standard) }
        set { write(newValue, to: .standard) }
    }

    static func read(from defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }

    /// Off clears the key rather than storing `false`, matching how appearance
    /// and content width persist: an untouched preference leaves no trace.
    static func write(_ isEnabled: Bool, to defaults: UserDefaults?) {
        if isEnabled {
            defaults?.set(true, forKey: defaultsKey)
        } else {
            defaults?.removeObject(forKey: defaultsKey)
        }
    }
}
