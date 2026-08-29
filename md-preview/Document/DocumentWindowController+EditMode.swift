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

    func makeEditSubitem() -> NSToolbarItem {
        let edit = NSLocalizedString("Edit", comment: "Edit toolbar item label")
        let image = NSImage(systemSymbolName: "highlighter",
                            accessibilityDescription: edit) ?? NSImage()
        image.isTemplate = true

        let item = NSToolbarItem(itemIdentifier: .editDocument)
        item.label = edit
        item.toolTip = NSLocalizedString("Edit document", comment: "Edit toolbar item tooltip")
        item.image = image
        item.target = self
        item.action = #selector(toggleEditAction(_:))
        item.autovalidates = false
        return item
    }

    func updateEditToolbarItem() {
        guard let editItem else { return }
        applyEditToolbarState(to: editItem)
    }

    func applyEditToolbarState(to item: NSToolbarItemGroup) {
        let editing = isEditing
        item.setSelected(editing, at: 2)
        let toolTip = editing
            ? NSLocalizedString("Stop editing and return to preview", comment: "Edit toolbar item tooltip while editing")
            : NSLocalizedString("Edit document", comment: "Edit toolbar item tooltip")
        item.subitems[2].toolTip = toolTip
        item.subitems[2].isEnabled = editing || currentMarkdown != nil
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
