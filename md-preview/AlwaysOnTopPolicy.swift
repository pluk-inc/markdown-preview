//
//  AlwaysOnTopPolicy.swift
//  md-preview
//
//  Pure decision logic behind the "Always on Top" window toggle. Kept free of
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
    static func windowLevel(isPinned: Bool) -> Int {
        Int(CGWindowLevelForKey(isPinned ? .floatingWindow : .normalWindow))
    }

    /// The windows a single toggle applies to.
    ///
    /// A tab group presents as one on-screen window, so pinning an individual
    /// tab would be ambiguous — whichever tab happened to be frontmost would
    /// decide whether the group floats, and the menu check mark would flip as
    /// the reader switched tabs. Toggling therefore pins the whole group and
    /// every tab reports the same state back.
    ///
    /// - Parameters:
    ///   - window: The window whose toggle the reader used.
    ///   - tabGroup: The windows sharing that window's tab group, or `nil`
    ///     when the window is not tabbed.
    /// - Returns: Every window that should take the new level.
    static func affectedWindows<Window>(toggling window: Window,
                                        tabGroup: [Window]?) -> [Window] {
        guard let tabGroup, !tabGroup.isEmpty else { return [window] }
        return tabGroup
    }
}
