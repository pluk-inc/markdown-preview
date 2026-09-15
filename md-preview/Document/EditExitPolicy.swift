//
//  EditExitPolicy.swift
//  md-preview
//
//  What happens to unsaved edits when the reader leaves edit mode. Kept free
//  of AppKit so the SPM helper tests can exercise it without a GUI host.
//

import Foundation

enum EditExitPolicy {
    /// What the reader can do with unsaved edits when leaving edit mode.
    enum ExitChoice: Equatable {
        /// Write the file, then show the preview.
        case save
        /// Show the preview with the edits kept as an unsaved draft, which
        /// Save can still write later. Nothing touches the disk.
        case continueUnsaved
        /// Discard the edits and return to the last saved version. Confirmed
        /// separately, because it cannot be undone.
        case revert
    }

    /// Button order in the leave-edit-mode alert. The first button answers
    /// Return, so it is Save: Return must never discard anything.
    static let exitButtonOrder: [ExitChoice] = [.save, .continueUnsaved, .revert]

    /// The choice Escape triggers. Escape in the editor is itself one of the
    /// ways to leave edit mode, so pressing it again on the alert keeps the
    /// edits and leaves -- which is what leaving did before the alert existed.
    static let escapeChoice: ExitChoice = .continueUnsaved

    /// Maps a zero-based alert button index back to its choice. Anything
    /// unexpected keeps the edits and writes nothing.
    static func exitChoice(forButtonAt index: Int) -> ExitChoice {
        exitButtonOrder.indices.contains(index) ? exitButtonOrder[index] : .continueUnsaved
    }

    /// Whether leaving edit mode should ask what to do with the edits.
    ///
    /// Compares the editor's source with the last saved version rather than
    /// trusting the "has changes" flag: typing and then undoing it leaves
    /// nothing to decide about, and the flag stays set in that case. An
    /// unknown saved version asks, since that is the side that loses nothing.
    static func needsExitPrompt(currentSource: String,
                                savedSource: String?,
                                exitsSilently: Bool) -> Bool {
        guard !exitsSilently else { return false }
        return currentSource != savedSource
    }

    // MARK: - Save availability

    /// File › Save (⌘S) and the toolbar Save button share this rule: only
    /// when there are unsaved changes, in edit mode or after leaving it with
    /// the changes kept.
    ///
    /// The editor reports a change asynchronously, so in principle a ⌘S
    /// pressed within milliseconds of the last keystroke can arrive before
    /// that report and beep instead of saving. That is the accepted cost of
    /// never offering Save when there is nothing to save.
    static func isSaveCommandEnabled(hasUnsavedChanges: Bool) -> Bool {
        hasUnsavedChanges
    }

    /// File › Save As… (⇧⌘S): writes a copy, so it makes sense for any open
    /// document, changed or not.
    static func isSaveAsCommandEnabled(hasDocument: Bool) -> Bool {
        hasDocument
    }

    /// File › Revert to Saved (⌘R): like Save, only with unsaved changes --
    /// and only when there is a version on disk to go back to, which an
    /// untitled document does not have.
    static func isRevertCommandEnabled(hasUnsavedChanges: Bool, hasFile: Bool) -> Bool {
        hasFile && hasUnsavedChanges
    }

    // MARK: - Setting

    static let defaultsKey = "MarkdownPreview.exitsEditModeSilently"

    /// Leave edit mode without asking, keeping unsaved edits as a draft -- the
    /// behaviour before the prompt existed. Off by default.
    static var exitsSilently: Bool {
        get { read(from: .standard) }
        set { write(newValue, to: .standard) }
    }

    static func read(from defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }

    /// Off clears the key rather than storing `false`, as the other
    /// preferences do: an untouched preference leaves no trace.
    static func write(_ exitsSilently: Bool, to defaults: UserDefaults?) {
        if exitsSilently {
            defaults?.set(true, forKey: defaultsKey)
        } else {
            defaults?.removeObject(forKey: defaultsKey)
        }
    }
}
