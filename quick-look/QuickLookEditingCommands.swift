//
//  QuickLookEditingCommands.swift
//  quick-look
//
//  Created by Fauzaan on 8/15/26.
//

import Foundation

/// Editing key equivalents the Quick Look preview must claim itself. The
/// Quick Look host processes (Finder, QuickLookUIService) carry no Edit
/// menu, so ⌘A / ⌘C never dispatch as menu key equivalents — without an
/// explicit claim the events die in the host and Select All / Copy do
/// nothing in the preview.
nonisolated enum QuickLookEditingCommands {
    enum Command: Equatable {
        case selectAll
        case copy
    }

    /// Mirrors `NSEvent.ModifierFlags.command.rawValue` (asserted in tests).
    static let commandKeyMask: UInt = 1 << 20
    /// Mirrors `NSEvent.ModifierFlags.capsLock.rawValue`.
    static let capsLockKeyMask: UInt = 1 << 16
    /// Mirrors `NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue`.
    static let deviceIndependentModifierMask: UInt = 0xFFFF_0000

    /// Maps a key-equivalent press to a preview editing command. Only a
    /// bare ⌘ chord qualifies (caps lock tolerated); any other modifier
    /// leaves the event for WebKit's own handling.
    static func command(
        forCharactersIgnoringModifiers characters: String?,
        modifierFlags: UInt
    ) -> Command? {
        let modifiers = modifierFlags
            & deviceIndependentModifierMask
            & ~capsLockKeyMask
        guard modifiers == commandKeyMask else { return nil }

        switch characters?.lowercased() {
        case "a":
            return .selectAll
        case "c":
            return .copy
        default:
            return nil
        }
    }
}
