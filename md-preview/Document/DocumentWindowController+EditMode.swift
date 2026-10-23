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
        isEditing || (currentMarkdown != nil && !isReceivedShare)
    }

    /// A document opened from someone else's share link: read-only, because
    /// opening the link again replaces it.
    var isReceivedShare: Bool {
        ShareLinkOpener.isReceivedCopy(currentFileURL)
    }

    /// A received share's folder holds only the document and its images, so
    /// its window shows the Table of Contents instead of the files.
    func showOutlineForReceivedShare() {
        guard isReceivedShare, let split = mainSplit, split.sidebarMode == .files else { return }
        split.setSidebarMode(.outline, remember: false)
        syncSidebarToolbarState()
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
        if editing {
            button.toolTip = NSLocalizedString("Stop editing and return to preview", comment: "Edit toolbar item tooltip while editing")
        } else if isReceivedShare {
            button.toolTip = NSLocalizedString("Shared documents are read-only", comment: "Edit toolbar item tooltip for a received shared document")
        } else {
            button.toolTip = NSLocalizedString("Edit document", comment: "Edit toolbar item tooltip")
        }
        button.isEnabled = canToggleEditMode
    }

    @objc private func toggleEditAction(_ sender: Any?) {
        toggleEditMode()
    }

    func toggleEditMode() {
        if isEditing {
            previewPendingEdits()
        } else {
            // Enter without placing a caret or selecting the toolbar search
            // field. Clicking the document will focus the editor explicitly.
            window?.makeFirstResponder(nil)
            enterEditMode()
        }
    }
}
