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
        isEditing || (currentFileURL != nil && currentMarkdown != nil)
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

    func makeEditItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .editDocument)
        let edit = NSLocalizedString("Edit", comment: "Edit toolbar item label")
        item.label = edit
        item.paletteLabel = edit
        item.toolTip = NSLocalizedString("Edit document", comment: "Edit toolbar item tooltip")

        let image = NSImage(systemSymbolName: "highlighter",
                            accessibilityDescription: edit) ?? NSImage()
        image.isTemplate = true
        let button = NSButton(image: image,
                              target: self,
                              action: #selector(toggleEditAction(_:)))
        button.setButtonType(.pushOnPushOff)
        button.toolTip = item.toolTip
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 32),
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])

        item.view = container
        editButton = button
        editItem = item
        updateEditToolbarItem()
        return item
    }

    func updateEditToolbarItem() {
        let editing = isEditing
        editButton?.state = editing ? .on : .off
        editItem?.toolTip = editing
            ? NSLocalizedString("Stop editing and return to preview", comment: "Edit toolbar item tooltip while editing")
            : NSLocalizedString("Edit document", comment: "Edit toolbar item tooltip")
        editButton?.toolTip = editItem?.toolTip
        editButton?.isEnabled = editing || (currentFileURL != nil && currentMarkdown != nil)
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
