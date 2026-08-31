//
//  DocumentWindowController+EditMode.swift
//  md-preview
//
//  Entering and leaving edit mode from the toolbar.
//

import Cocoa

extension DocumentWindowController {
    // MARK: - Edit mode

    var mainSplit: MainSplitViewController? {
        documentWindow.contentViewController as? MainSplitViewController
    }

    var isEditing: Bool {
        mainSplit?.isEditingDocument ?? false
    }

    var canToggleEditMode: Bool {
        isEditing || currentMarkdown != nil
    }

    var canFormatMarkdown: Bool { isEditing }

    func formatMarkdown(_ command: String) {
        guard isEditing else { return }
        mainSplit?.editorViewController?.exec(command)
    }

    var hasPendingEditorChanges: Bool {
        hasUnsavedEditorChanges || isEditorCommitInFlight
    }

    func commitPendingEditsForTermination(completion: @escaping (Bool) -> Void) {
        guard isEditing || hasPendingEditorChanges else {
            completion(true)
            return
        }
        requestEndEditing(completion: completion)
    }

    func makeEditItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let edit = NSLocalizedString("Edit", comment: "Edit toolbar item label")
        let image = NSImage(systemSymbolName: "highlighter",
                            accessibilityDescription: edit) ?? NSImage()
        image.isTemplate = true

        let (item, button) = makeToggleButtonItem(identifier: .editDocument,
                                                  image: image,
                                                  label: edit,
                                                  action: #selector(toggleEditAction(_:)))
        item.autovalidates = false

        if willBeInsertedIntoToolbar {
            editButton = button
        }
        applyEditToolbarState(to: button)
        return item
    }

    func updateEditToolbarItem() {
        guard let editButton else { return }
        applyEditToolbarState(to: editButton)
    }

    private func applyEditToolbarState(to button: NSButton) {
        let editing = isEditing
        button.state = editing ? .on : .off
        button.toolTip = editing
            ? NSLocalizedString("Stop editing and return to preview", comment: "Edit toolbar item tooltip while editing")
            : NSLocalizedString("Edit document", comment: "Edit toolbar item tooltip")
        button.isEnabled = editing || currentMarkdown != nil
    }

    @objc private func toggleEditAction(_ sender: Any?) {
        toggleEditMode()
    }

    func toggleEditMode() {
        if isEditing {
            previewPendingEdits()
        } else {
            enterEditMode()
        }
    }
}
