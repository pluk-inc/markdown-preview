//
//  DocumentWindowController+AlwaysOnTop.swift
//  md-preview
//
//  The Always-on-Top toggle and menu validation.
//

import Cocoa

extension DocumentWindowController {
    /// The toolbar button and the menu item both drive the one app-wide
    /// preference, so the toggle goes through the app delegate rather than
    /// changing this window: every open window follows, not just this one.
    @objc func toggleAlwaysOnTop(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.applyAlwaysOnTopSetting(!isAlwaysOnTop)
    }

    /// Takes the current setting: called on every open window when it changes,
    /// and once on a window being created so it opens already floating.
    func applyAlwaysOnTopSetting() {
        applyAlwaysOnTopLevel(isFullScreen: documentWindow.styleMask.contains(.fullScreen))
        alwaysOnTopItem?.setSelected(isAlwaysOnTop, at: 0)
    }

    /// The pin is intent, not the level itself: the level is recomputed on both
    /// full-screen transitions, so the toolbar toggle stays lit across them and
    /// the window floats again on the way out.
    func applyAlwaysOnTopLevel(isFullScreen: Bool) {
        documentWindow.level = NSWindow.Level(
            rawValue: AlwaysOnTopPolicy.windowLevel(isPinned: isAlwaysOnTop,
                                                    isFullScreen: isFullScreen)
        )
    }

    var isAlwaysOnTop: Bool { AlwaysOnTopPolicy.isEnabled }

    /// The pin icon doubles as the state indicator. An `NSMenuItem` draws its
    /// image and its check mark in the same leading slot, so beside an icon the
    /// tick is easy to miss and the item reads as neither on nor off. Filling
    /// the pin makes the state legible at a glance; `state` is still set, so
    /// VoiceOver and the menu's own semantics stay correct.
    private static func alwaysOnTopMenuImage(isPinned: Bool) -> NSImage? {
        let image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: NSLocalizedString("Always on Top",
                                                        comment: "Always on Top menu item")
        )
        image?.isTemplate = true
        return image
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveDocument(_:)) {
            return isEditing
        }
        if menuItem.action == #selector(toggleAlwaysOnTop(_:)) {
            menuItem.state = isAlwaysOnTop ? .on : .off
            menuItem.image = Self.alwaysOnTopMenuImage(isPinned: isAlwaysOnTop)
            return true
        }
        syncSidebarMenuState()
        return true
    }
}
