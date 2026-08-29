//
//  DocumentWindowController+EditSession.swift
//  md-preview
//
//  The edit session engine: commit, conflicts, table edits, persistence.
//

import Cocoa
import UniformTypeIdentifiers

extension DocumentWindowController {
    func enterEditMode(autofocus: Bool = false) {
        guard let split = mainSplit, !split.isEditingDocument,
              let markdown = editorDraftMarkdown ?? currentMarkdown else {
            NSSound.beep()
            return
        }

        // Edit the complete source. Frontmatter is stripped only by the
        // read-only renderer; the editor must expose and preserve it.
        let editor = split.enterEditMode(
            markdown: markdown,
            assetBaseURL: currentFileURL?.deletingLastPathComponent(),
            autofocus: autofocus
        )
        editor.cancelRequested = { [weak self] in
            self?.previewPendingEdits()
        }
        editor.contentDidChange = { [weak self] in
            self?.editorChangeRevision += 1
            self?.hasUnsavedEditorChanges = true
            self?.stopAutoSaveTimer()
            self?.startAutoSaveTimerIfNeeded()
        }
        editor.pasteImageRequested = { [weak self] from, to in
            self?.pasteImage(at: from, replacing: to)
        }
        editor.imageClicked = { [weak self] url in
            self?.renameImage(at: url)
        }
        if editorBaselineMarkdown == nil {
            editorBaselineMarkdown = currentMarkdown
            editorChangeRevision = 0
            hasUnsavedEditorChanges = false
        }
        showEditAccessory()
        updateEditToolbarItem()
    }

    /// Switches to preview without resolving the editing session. The preview
    /// renders the in-memory source, while the disk baseline is kept for a
    /// later Save or close decision.
    func previewPendingEdits() {
        guard let split = mainSplit, let editor = split.editorViewController else { return }
        editor.fetchMarkdown { [weak self] markdown in
            guard let self, let markdown else {
                NSSound.beep()
                return
            }
            self.editorDraftMarkdown = markdown
            self.currentMarkdown = markdown
            self.hasUnsavedEditorChanges = markdown != self.editorBaselineMarkdown
            if !self.hasUnsavedEditorChanges {
                self.editorDraftMarkdown = nil
                self.editorBaselineMarkdown = nil
            }
            if let url = self.currentFileURL {
                self.markdownDocument?.replaceContents(markdown: markdown, fileURL: url)
            } else {
                self.markdownDocument?.replaceContents(markdown: markdown)
            }
            // exitEditMode(rerender: true) renders the pending markdown once
            // the editor's scroll anchor has been captured; rendering here as
            // well raced the anchor hand-off and re-laid the preview out
            // twice, which showed as jitter during the mode switch. The
            // formatting accessory likewise stays mounted until the overlay
            // has faded — removing it earlier reflows the content area in
            // the middle of the crossfade.
            self.exitEditMode(rerender: true,
                              preserveUnsavedChanges: true,
                              hidesAccessoryAfterFade: true) {}
        }
    }

    private func saveUntitledMarkdown(
        _ text: String,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled.md"
        panel.message = NSLocalizedString(
            "Choose a name and location for the new Markdown file.",
            comment: "New Markdown file panel prompt"
        )
        panel.prompt = NSLocalizedString("Save", comment: "Untitled Markdown file save panel button")
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion(.cancelled)
                return
            }
            guard self.write(text, to: url) else {
                completion(.cancelled)
                return
            }

            self.currentFileURL = url
            self.documentWindow.title = url.lastPathComponent
            self.markdownDocument?.replaceContents(markdown: text, fileURL: url)
            self.mainSplit?.openFileURLDidChange(url, markdown: text)
            self.resetAutoSaveFeedback()
            self.refreshOpenWithItem()
            self.refreshOpenInLLMItem()
            self.refreshOpenActionsItem()
            self.updateEditToolbarItem()
            self.startWatching(url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            completion(.saved)
        }
    }

    func requestEndEditing(
        keepAccessoryMounted: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        let finish: (Bool) -> Void = { [weak self] success in
            if success, !keepAccessoryMounted {
                self?.dismissEditChrome()
            }
            completion?(success)
        }
        resolveUnsavedEdits { [weak self] resolution in
            guard let self else {
                finish(false)
                return
            }
            switch resolution {
            case .save:
                self.commitEdits(exitAfter: true, completion: finish)
            case .discard:
                self.exitEditModeWithoutSaving {
                    finish(true)
                }
            case .cancel:
                finish(false)
            }
        }
    }

    private func resolveUnsavedEdits(
        completion: @escaping (UnsavedEditResolution) -> Void
    ) {
        guard hasUnsavedEditorChanges || isEditorCommitInFlight else {
            completion(.discard)
            return
        }

        // If an explicit ⌘S is already running, let that request finish
        // instead of presenting a second decision on top of it.
        if isEditorCommitInFlight {
            commitEdits(exitAfter: false) { success in
                completion(success ? .discard : .cancel)
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "Do you want to save your changes?",
            comment: "Unsaved changes alert title"
        )
        let fileName = currentFileURL?.lastPathComponent
            ?? NSLocalizedString("this document", comment: "Fallback document name in alerts")
        alert.informativeText = String(
            format: NSLocalizedString(
                "Your changes to %@ will be lost if you don’t save them.",
                comment: "Unsaved changes alert message"
            ),
            fileName
        )
        alert.addButton(withTitle: NSLocalizedString("Save", comment: "Alert button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        alert.addButton(withTitle: NSLocalizedString("Don’t Save", comment: "Alert button"))
        alert.beginSheetModal(for: documentWindow) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.save)
            case .alertThirdButtonReturn:
                completion(.discard)
            default:
                completion(.cancel)
            }
        }
    }

    private func exitEditModeWithoutSaving(completion: @escaping () -> Void) {
        var shouldRerender = false
        if let baseline = editorBaselineMarkdown {
            currentMarkdown = baseline
            if let url = currentFileURL {
                markdownDocument?.replaceContents(markdown: baseline, fileURL: url)
            }
            shouldRerender = true
        }
        if case let .modified(externalMarkdown) = diskFileState(
            for: currentFileURL,
            expectedMarkdown: editorBaselineMarkdown ?? currentMarkdown
        ) {
            currentMarkdown = externalMarkdown
            if let url = currentFileURL {
                markdownDocument?.replaceContents(markdown: externalMarkdown, fileURL: url)
            }
            shouldRerender = true
        }
        editorDraftMarkdown = nil
        editorBaselineMarkdown = nil
        hasUnsavedEditorChanges = false
        exitEditMode(rerender: shouldRerender, completion: completion)
    }

    /// Serializes the editor, writes the file if the content changed, and
    /// optionally returns to the preview. Stays in edit mode when the save
    /// fails so no edits are lost. `completion(false)` means the commit
    /// did not go through.
    func commitEdits(exitAfter: Bool, completion: ((Bool) -> Void)? = nil) {
        pendingCommitShouldExit = pendingCommitShouldExit || exitAfter
        if let completion {
            pendingCommitCompletions.append(completion)
        }
        guard !isEditorCommitInFlight else {
            pendingEditorCommitRequested = true
            return
        }
        performPendingEditorCommit()
    }

    private func performPendingEditorCommit() {
        let exitAfter = pendingCommitShouldExit
        pendingCommitShouldExit = false
        guard let split = mainSplit else {
            finishEditorCommit(success: false)
            return
        }
        if !isEditing, let body = editorDraftMarkdown {
            performPendingEditorCommit(body: body, editor: nil, exitAfter: exitAfter)
            return
        }
        guard let editor = split.editorViewController else {
            finishEditorCommit(success: true)
            return
        }
        let revision = editorChangeRevision
        isEditorCommitInFlight = true
        editor.fetchMarkdown { [weak self] body in
            guard let self else {
                return
            }
            guard let body else {
                NSSound.beep()
                self.finishEditorCommit(success: false)
                return
            }
            self.performPendingEditorCommit(body: body, editor: editor,
                                            revision: revision, exitAfter: exitAfter)
        }
    }

    private func performPendingEditorCommit(body: String,
                                            editor: EditorViewController?,
                                            revision: Int? = nil,
                                            exitAfter: Bool) {
        isEditorCommitInFlight = true
        if currentFileURL == nil {
            saveUntitledMarkdown(body) { result in
                self.handleEditedMarkdownSaveResult(result,
                                                    body: body,
                                                    editor: editor,
                                                    revision: revision,
                                                    exitAfter: exitAfter)
            }
            return
        }

        let baseline = editorBaselineMarkdown ?? currentMarkdown
        let diskState = diskFileState(for: currentFileURL,
                                      expectedMarkdown: baseline)
        let hasLocalChanges = body != baseline

        if !hasLocalChanges, case let .modified(externalMarkdown) = diskState {
            // Nothing local needs preserving, so adopt the newer disk
            // version without presenting a needless conflict dialog.
            adoptExternalMarkdown(externalMarkdown,
                                  editor: editor,
                                  exitAfter: exitAfter)
            return
        }

        guard hasUnsavedEditorChanges, hasLocalChanges else {
            if revision == nil || revision == editorChangeRevision {
                hasUnsavedEditorChanges = false
            }
            switch diskState {
            case .unchanged:
                completeSuccessfulEditorCommit(exitAfter: exitAfter,
                                               rerender: false)
            case .modified:
                // Handled above.
                break
            case .missing, .unreadable:
                saveEditedMarkdown(body, diskState: diskState) { result in
                    self.handleEditedMarkdownSaveResult(result,
                                                        body: body,
                                                        editor: editor,
                                                        revision: revision,
                                                        exitAfter: exitAfter)
                }
            }
            return
        }
        saveEditedMarkdown(body, diskState: diskState) { result in
            self.handleEditedMarkdownSaveResult(result,
                                                body: body,
                                                editor: editor,
                                                revision: revision,
                                                exitAfter: exitAfter)
        }
    }

    private func handleEditedMarkdownSaveResult(_ result: EditedMarkdownSaveResult,
                                                body: String,
                                                editor: EditorViewController?,
                                                revision: Int?,
                                                exitAfter: Bool) {
        switch result {
        case .saved:
            currentMarkdown = body
            if let url = currentFileURL {
                markdownDocument?.replaceContents(markdown: body, fileURL: url)
            }
            editorDraftMarkdown = nil
            editorBaselineMarkdown = isEditing && !exitAfter ? body : nil
            if revision == nil || revision == editorChangeRevision {
                hasUnsavedEditorChanges = false
            }
            completeSuccessfulEditorCommit(exitAfter: exitAfter, rerender: true)
        case let .reloaded(externalMarkdown):
            adoptExternalMarkdown(externalMarkdown,
                                  editor: editor,
                                  exitAfter: exitAfter)
        case .cancelled:
            finishEditorCommit(success: false)
        }
    }

    private func adoptExternalMarkdown(_ markdown: String,
                                       editor: EditorViewController?,
                                       exitAfter: Bool) {
        currentMarkdown = markdown
        editorDraftMarkdown = nil
        editorBaselineMarkdown = isEditing && !exitAfter ? markdown : nil
        editorChangeRevision = 0
        hasUnsavedEditorChanges = false
        if let url = currentFileURL {
            markdownDocument?.replaceContents(markdown: markdown, fileURL: url)
            if !exitAfter {
                renderCurrentDocument(text: markdown, fileURL: url)
            }
        }
        if !exitAfter {
            editor?.load(
                markdown: markdown,
                assetBaseURL: currentFileURL?.deletingLastPathComponent()
            )
        }
        completeSuccessfulEditorCommit(exitAfter: exitAfter, rerender: true)
    }

    private func completeSuccessfulEditorCommit(exitAfter: Bool, rerender: Bool) {
        if hasUnsavedEditorChanges {
            if exitAfter {
                pendingCommitShouldExit = true
            }
            finishEditorCommit(success: true)
            return
        }
        guard exitAfter else {
            finishEditorCommit(success: true)
            return
        }
        exitEditMode(rerender: rerender) { [weak self] in
            self?.finishEditorCommit(success: true)
        }
    }

    private func finishEditorCommit(success: Bool) {
        isEditorCommitInFlight = false
        if pendingEditorCommitRequested {
            pendingEditorCommitRequested = false
            isPerformingAutomaticSave = false
            performPendingEditorCommit()
            return
        }
        if success,
           pendingCommitShouldExit
            || (hasUnsavedEditorChanges && !isPerformingAutomaticSave) {
            startAutoSaveTimerIfNeeded()
            performPendingEditorCommit()
            return
        }

        if hasUnsavedEditorChanges {
            startAutoSaveTimerIfNeeded()
        } else {
            stopAutoSaveTimer()
        }

        pendingEditorCommitRequested = false
        pendingCommitShouldExit = false
        let completions = pendingCommitCompletions
        pendingCommitCompletions.removeAll()
        for completion in completions {
            completion(success)
        }
    }

    private func exitEditMode(rerender: Bool,
                              preserveUnsavedChanges: Bool = false,
                              hidesAccessoryAfterFade: Bool = false,
                              completion: @escaping () -> Void) {
        guard let split = mainSplit else {
            completion()
            return
        }
        split.editorViewController?.contentDidChange = nil
        split.editorViewController?.cancelRequested = nil
        split.editorViewController?.pasteImageRequested = nil
        split.editorViewController?.imageClicked = nil
        documentWindow.makeFirstResponder(nil)
        let overlayHidden: (() -> Void)? = hidesAccessoryAfterFade
            ? { [weak self] in self?.dismissEditChrome() }
            : nil
        split.exitEditMode(waitForPreviewRender: rerender,
                           overlayHidden: overlayHidden) { [weak self] in
            guard let self else {
                completion()
                return
            }
            if !preserveUnsavedChanges {
                self.hasUnsavedEditorChanges = false
            }
            if self.editAccessory == nil {
                self.updateEditToolbarItem()
            }
            if rerender, let markdown = self.currentMarkdown {
                self.renderCurrentDocument(text: markdown, fileURL: self.currentFileURL)
            }
            completion()
        }
    }

    func diskFileState(for url: URL?, expectedMarkdown: String?) -> DiskFileState {
        guard let url, let expectedMarkdown else { return .unreadable }
        do {
            let diskMarkdown = try String(contentsOf: url, encoding: .utf8)
            return diskMarkdown == expectedMarkdown ? .unchanged : .modified(diskMarkdown)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
    }

    func saveEditedMarkdown(_ text: String,
                            diskState: DiskFileState,
                            completion: @escaping (EditedMarkdownSaveResult) -> Void) {
        guard let url = currentFileURL else {
            completion(.cancelled)
            return
        }
        if isPerformingAutomaticSave {
            guard case .unchanged = diskState else {
                completion(.cancelled)
                return
            }
        }
        switch diskState {
        case .unchanged:
            persistEditedMarkdown(text, to: url, completion: completion)
        case let .modified(externalMarkdown):
            presentExternalEditConflict(localMarkdown: text,
                                        externalMarkdown: externalMarkdown,
                                        fileURL: url,
                                        completion: completion)
        case .missing:
            presentUnavailableFileConflict(localMarkdown: text,
                                           fileURL: url,
                                           reason: NSLocalizedString(
                                               "The file was removed while it was open.",
                                               comment: "Unavailable file conflict reason"
                                           ),
                                           overwriteTitle: NSLocalizedString(
                                               "Recreate File",
                                               comment: "Unavailable file conflict button"
                                           ),
                                           completion: completion)
        case .unreadable:
            presentUnavailableFileConflict(localMarkdown: text,
                                           fileURL: url,
                                           reason: NSLocalizedString(
                                               "The file could not be read to verify that it is unchanged.",
                                               comment: "Unavailable file conflict reason"
                                           ),
                                           overwriteTitle: NSLocalizedString(
                                               "Save Anyway",
                                               comment: "Unavailable file conflict button"
                                           ),
                                           completion: completion)
        }
    }

    func toggleTaskCheckbox(onLine sourceLine: Int, checked: Bool) {
        guard !isEditing,
              let baseline = currentMarkdown,
              let updated = TaskCheckboxSource.settingChecked(
                checked, onLine: sourceLine, in: baseline
              ),
              updated != baseline else {
            rerenderCurrentPreview()
            return
        }

        let diskState = diskFileState(for: currentFileURL, expectedMarkdown: baseline)
        saveEditedMarkdown(updated, diskState: diskState) { [weak self] result in
            guard let self else { return }
            switch result {
            case .saved:
                self.currentMarkdown = updated
                if let url = self.currentFileURL {
                    self.markdownDocument?.replaceContents(markdown: updated, fileURL: url)
                    self.renderCurrentDocument(text: updated, fileURL: url)
                }
            case let .reloaded(externalMarkdown):
                self.currentMarkdown = externalMarkdown
                if let url = self.currentFileURL {
                    self.markdownDocument?.replaceContents(markdown: externalMarkdown, fileURL: url)
                    self.renderCurrentDocument(text: externalMarkdown, fileURL: url)
                }
            case .cancelled:
                self.rerenderCurrentPreview()
            }
        }
    }

    func applyTableEdit(_ request: MarkdownTableEditRequest) {
        guard !isEditing,
              let baseline = currentMarkdown else {
            rerenderCurrentPreview()
            return
        }
        let updated = request.edits.reduce(Optional(baseline)) { markdown, edit in
            markdown.flatMap {
                MarkdownTableSource.applying(
                    edit,
                    fromLine: request.startLine,
                    throughLine: request.endLine,
                    in: $0
                )
            }
        }
        guard let updated,
              updated != baseline else {
            rerenderCurrentPreview()
            return
        }

        let diskState = diskFileState(for: currentFileURL, expectedMarkdown: baseline)
        let actionName = tableUndoActionName(for: request.edits)
        saveEditedMarkdown(updated, diskState: diskState) { [weak self] result in
            guard let self else { return }
            switch result {
            case .saved:
                self.currentMarkdown = updated
                if let url = self.currentFileURL {
                    self.markdownDocument?.replaceContents(markdown: updated, fileURL: url)
                    self.renderCurrentDocument(text: updated, fileURL: url)
                    self.registerTableUndo(
                        restoring: baseline,
                        expectedCurrentMarkdown: updated,
                        fileURL: url,
                        actionName: actionName
                    )
                }
            case let .reloaded(externalMarkdown):
                self.tableUndoManager.removeAllActions()
                self.currentMarkdown = externalMarkdown
                if let url = self.currentFileURL {
                    self.markdownDocument?.replaceContents(markdown: externalMarkdown, fileURL: url)
                    self.renderCurrentDocument(text: externalMarkdown, fileURL: url)
                }
            case .cancelled:
                self.rerenderCurrentPreview()
            }
        }
    }

    private func tableUndoActionName(for edits: [MarkdownTableEdit]) -> String {
        for edit in edits.reversed() {
            switch edit {
            case .setCell:
                return NSLocalizedString("Edit Table Cell", comment: "Table edit undo action")
            case .insertRowBefore, .insertRowAfter:
                return NSLocalizedString("Add Row", comment: "Table edit undo action")
            case .deleteRow:
                return NSLocalizedString("Delete Row", comment: "Table edit undo action")
            case .insertColumnBefore, .insertColumnAfter:
                return NSLocalizedString("Add Column", comment: "Table edit undo action")
            case .deleteColumn:
                return NSLocalizedString("Delete Column", comment: "Table edit undo action")
            }
        }
        return NSLocalizedString("Edit Table", comment: "Table edit undo action")
    }

    private func registerTableUndo(restoring markdown: String,
                                   expectedCurrentMarkdown: String,
                                   fileURL: URL,
                                   actionName: String) {
        tableUndoManager.registerUndo(withTarget: self) { target in
            target.restoreTableMarkdown(
                markdown,
                expectedCurrentMarkdown: expectedCurrentMarkdown,
                fileURL: fileURL,
                actionName: actionName
            )
        }
        tableUndoManager.setActionName(actionName)
    }

    private func restoreTableMarkdown(_ markdown: String,
                                      expectedCurrentMarkdown: String,
                                      fileURL: URL,
                                      actionName: String) {
        guard !isEditing,
              !isTableUndoSaveInFlight,
              currentFileURL?.standardizedFileURL == fileURL.standardizedFileURL,
              currentMarkdown == expectedCurrentMarkdown else {
            tableUndoManager.removeAllActions()
            return
        }

        // Register while UndoManager is actively undoing or redoing so AppKit
        // puts this inverse operation on the opposite stack immediately. The
        // file write can become asynchronous if sandbox permission is needed.
        registerTableUndo(
            restoring: expectedCurrentMarkdown,
            expectedCurrentMarkdown: markdown,
            fileURL: fileURL,
            actionName: actionName
        )
        isTableUndoSaveInFlight = true
        let diskState = diskFileState(for: currentFileURL,
                                      expectedMarkdown: expectedCurrentMarkdown)
        saveEditedMarkdown(markdown, diskState: diskState) { [weak self] result in
            guard let self else { return }
            self.isTableUndoSaveInFlight = false
            switch result {
            case .saved:
                self.currentMarkdown = markdown
                self.markdownDocument?.replaceContents(markdown: markdown, fileURL: fileURL)
                self.renderCurrentDocument(text: markdown, fileURL: fileURL)
            case let .reloaded(externalMarkdown):
                self.tableUndoManager.removeAllActions()
                self.currentMarkdown = externalMarkdown
                self.markdownDocument?.replaceContents(
                    markdown: externalMarkdown,
                    fileURL: fileURL
                )
                self.renderCurrentDocument(text: externalMarkdown, fileURL: fileURL)
            case .cancelled:
                self.tableUndoManager.removeAllActions()
                self.rerenderCurrentPreview()
            }
        }
    }

    func rerenderCurrentPreview() {
        guard let url = currentFileURL, let markdown = currentMarkdown else { return }
        renderCurrentDocument(text: markdown, fileURL: url)
    }

    private func presentExternalEditConflict(
        localMarkdown: String,
        externalMarkdown: String,
        fileURL: URL,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "This document changed on disk",
            comment: "External edit conflict alert title"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "Another app changed %@. Cancel keeps your changes unsaved. Choose which version to keep.",
                comment: "External edit conflict alert message"
            ),
            fileURL.lastPathComponent
        )
        alert.addButton(withTitle: NSLocalizedString("Keep My Changes", comment: "Conflict alert button"))
        alert.addButton(withTitle: NSLocalizedString("Reload from Disk", comment: "Conflict alert button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        alert.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self else {
                completion(.cancelled)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                self.persistEditedMarkdown(localMarkdown, to: fileURL, completion: completion)
            case .alertSecondButtonReturn:
                // The sheet may remain open while another editor writes
                // again. Reload the latest bytes instead of the snapshot
                // captured when the conflict was first detected.
                if let latestMarkdown = try? String(contentsOf: fileURL, encoding: .utf8) {
                    completion(.reloaded(latestMarkdown))
                } else {
                    completion(.reloaded(externalMarkdown))
                }
            default:
                completion(.cancelled)
            }
        }
    }

    private func presentUnavailableFileConflict(
        localMarkdown: String,
        fileURL: URL,
        reason: String,
        overwriteTitle: String,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString(
            "Unable to verify the document on disk",
            comment: "Unavailable file conflict alert title"
        )
        alert.informativeText = String(
            format: NSLocalizedString(
                "%@ Cancel keeps your changes unsaved.",
                comment: "Unavailable file conflict alert message"
            ),
            reason
        )
        alert.addButton(withTitle: overwriteTitle)
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        alert.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                completion(.cancelled)
                return
            }
            self.persistEditedMarkdown(localMarkdown, to: fileURL, completion: completion)
        }
    }

    private func persistEditedMarkdown(
        _ text: String,
        to url: URL,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        if write(text, to: url) {
            completion(.saved)
            return
        }
        guard !isPerformingAutomaticSave else {
            completion(.cancelled)
            return
        }
        // Sandbox denied the write — the file came in through the read-only
        // filesystem exception (folder navigator) rather than a user-selected
        // grant. A save panel pointed at the same file converts the user's
        // confirmation into a read-write grant.
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.message = NSLocalizedString(
            "Markdown Preview needs your permission to save this file.",
            comment: "Save panel permission message"
        )
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let chosen = panel.url else {
                completion(.cancelled)
                return
            }
            let ok = self.write(text, to: chosen)
            if ok, chosen.standardizedFileURL != url.standardizedFileURL {
                // Saved under a different name — follow the new file.
                self.handleRename(to: chosen)
            }
            completion(ok ? .saved : .cancelled)
        }
    }

    private func write(_ text: String, to url: URL) -> Bool {
        // Atomic first (safe against partial writes); a file-scoped sandbox
        // grant can deny the temp-file rename, so fall back to in-place.
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            do {
                try text.write(to: url, atomically: false, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
    }
}
