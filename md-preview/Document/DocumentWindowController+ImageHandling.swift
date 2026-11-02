//
//  DocumentWindowController+ImageHandling.swift
//  Markdown Preview
//

import AppKit

extension DocumentWindowController {
    func pasteImage(at from: Int, replacing to: Int) {
        guard isEditing else { return }
        guard let data = clipboardPNGData() else {
            presentImageError(
                NSError(domain: "MarkdownPreview.ImagePaste", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString(
                        "The clipboard does not contain an image.",
                        comment: "Image paste error"
                    )
                ])
            )
            return
        }
        pasteImage(data, at: from, replacing: to)
    }

    private func pasteImage(_ data: Data, at from: Int, replacing to: Int,
                            expectedMarkdown: String? = nil,
                            completion: ((Result<String, Error>?) -> Void)? = nil) {
        guard isEditing, let editor = mainSplit?.editorViewController else {
            completion?(nil)
            return
        }
        guard let markdownURL = currentFileURL else {
            pendingUntitledImagePastes.append((data, from, to))
            guard pendingUntitledImagePastes.count == 1 else { return }
            let revision = editorChangeRevision
            let sessionID = inspectorRefreshSessionID
            commitEdits(exitAfter: false) { [weak self, weak editor] saved in
                guard let self else { return }
                let pastes = self.pendingUntitledImagePastes
                self.pendingUntitledImagePastes.removeAll()
                guard saved, let editor,
                      self.mainSplit?.editorViewController === editor else { return }
                guard revision == self.editorChangeRevision,
                      sessionID == self.inspectorRefreshSessionID,
                      let markdown = self.currentMarkdown else {
                    self.presentQueuedImageError(count: pastes.count)
                    return
                }
                self.pasteUntitledImages(pastes, editor: editor, markdown: markdown)
            }
            return
        }

        do {
            try insertPastedImage(data,
                                  forMarkdownFile: markdownURL,
                                  editor: editor,
                                  from: from,
                                  to: to,
                                  expectedMarkdown: expectedMarkdown,
                                  completion: completion)
        } catch {
            presentImagePermissionPanel(data,
                                        markdownURL: markdownURL,
                                        editor: editor,
                                        from: from,
                                        to: to,
                                        expectedMarkdown: expectedMarkdown,
                                        completion: completion)
        }
    }

    private func pasteUntitledImages(_ pastes: [(data: Data, from: Int, to: Int)],
                                     editor: EditorViewController,
                                     markdown: String) {
        guard let paste = pastes.first,
              mainSplit?.editorViewController === editor,
              let markdownURL = currentFileURL else { return }
        guard paste.from >= 0, paste.to >= paste.from,
              paste.to <= markdown.utf16.count else {
            presentQueuedImageError(count: pastes.count)
            return
        }
        pasteImage(paste.data, at: paste.from, replacing: paste.to,
                   expectedMarkdown: markdown) { [weak self, weak editor] result in
            guard let result, let self, let editor,
                  self.mainSplit?.editorViewController === editor,
                  self.currentFileURL == markdownURL else { return }
            guard case let .success(insertedMarkdown) = result else {
                self.presentQueuedImageError(count: pastes.count)
                return
            }
            let updated = (markdown as NSString).replacingCharacters(
                in: NSRange(location: paste.from, length: paste.to - paste.from), with: insertedMarkdown
            )
            // Live edits invalidate the captured ranges even when the save succeeds.
            guard self.currentMarkdown == updated else {
                if pastes.count > 1 { self.presentQueuedImageError(count: pastes.count - 1) }
                return
            }
            let length = insertedMarkdown.utf16.count
            let end = paste.from + length
            let delta = length - (paste.to - paste.from)
            // Pending ranges refer to the document before the preceding insertion.
            let remaining = pastes.dropFirst().map { next in
                guard next.to > paste.from || next.from >= paste.from else { return next }
                let from = next.from < paste.from ? next.from
                    : next.from >= paste.to ? next.from + delta : end
                let to = next.to < paste.from ? next.to
                    : next.to >= paste.to ? next.to + delta : end
                return (data: next.data, from: from, to: to)
            }
            self.pasteUntitledImages(remaining, editor: editor, markdown: updated)
        }
    }

    private func presentQueuedImageError(count: Int) {
        presentImageError(NSError(domain: "MarkdownPreview.ImagePaste", code: 4, userInfo: [
            NSLocalizedDescriptionKey: String(format: NSLocalizedString(
                "Queued image paste failed (%ld remaining). Please paste again.",
                comment: "Queued image paste stopped after an editor change or insertion failure"
            ), count)
        ]))
    }

    private func insertPastedImage(_ data: Data,
                                   forMarkdownFile markdownURL: URL,
                                   editor: EditorViewController,
                                   from: Int,
                                   to: Int,
                                   expectedMarkdown: String? = nil,
                                   completion: ((Result<String, Error>?) -> Void)? = nil) throws {
        let imageURL = try MarkdownAssetResolution.savePastedImage(
            data,
            forMarkdownFile: markdownURL
        )
        guard let relativePath = MarkdownAssetResolution.markdownPath(
            for: imageURL,
            from: markdownURL
        ) else {
            try? FileManager.default.removeItem(at: imageURL)
            throw NSError(domain: "MarkdownPreview.ImagePaste",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                              "The pasted image could not be placed next to the Markdown file.",
                              comment: "Image paste destination error"
                          )])
        }
        let label = imageURL.deletingPathExtension().lastPathComponent
        let markdown = "![\(label)](\(relativePath))"
        editor.insertMarkdown(
            markdown,
            from: from,
            to: to,
            expectedMarkdown: expectedMarkdown
        ) { [weak self, weak editor] inserted in
            guard inserted else {
                try? FileManager.default.removeItem(at: imageURL)
                let error = NSError(domain: "MarkdownPreview.ImagePaste",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                                "The pasted image could not be inserted into the document.",
                                comment: "Image paste insertion error"
                            )])
                if let completion {
                    completion(.failure(error))
                } else {
                    self?.presentImageError(error)
                }
                return
            }
            guard let self, let editor else { return }
            self.hasUnsavedEditorChanges = true
            let sessionID = self.inspectorRefreshSessionID
            self.commitEdits(exitAfter: false) { [weak self, weak editor] saved in
                guard let self, let editor,
                      self.mainSplit?.editorViewController === editor,
                      self.currentFileURL == markdownURL else {
                    completion?(nil)
                    return
                }
                guard sessionID == self.inspectorRefreshSessionID else {
                    if self.currentMarkdown?.contains(relativePath) != true {
                        try? FileManager.default.removeItem(at: imageURL)
                    }
                    completion?(nil)
                    return
                }
                completion?(saved ? .success(markdown) : nil)
            }
        }
    }

    private func presentImagePermissionPanel(_ data: Data,
                                             markdownURL: URL,
                                             editor: EditorViewController,
                                             from: Int,
                                             to: Int,
                                             expectedMarkdown: String? = nil,
                                             completion: ((Result<String, Error>?) -> Void)? = nil) {
        let parentDirectory = markdownURL.deletingLastPathComponent().standardizedFileURL
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentDirectory
        panel.message = NSLocalizedString(
            "Choose the folder containing this Markdown file to save the pasted image.",
            comment: "Image paste permission message"
        )
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let chosen = panel.url else {
                completion?(nil)
                return
            }
            guard self.isEditing, self.currentFileURL == markdownURL,
                  self.mainSplit?.editorViewController === editor else {
                completion?(nil)
                return
            }
            guard chosen.standardizedFileURL == parentDirectory else {
                completion?(nil)
                self.presentImageError(
                    NSError(domain: "MarkdownPreview.ImagePaste",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                                "Choose the folder containing this Markdown file.",
                                comment: "Image paste folder validation error"
                            )])
                )
                return
            }
            do {
                try self.insertPastedImage(data,
                                           forMarkdownFile: markdownURL,
                                           editor: editor,
                                           from: from,
                                           to: to,
                                           expectedMarkdown: expectedMarkdown,
                                           completion: completion)
            } catch {
                if let completion {
                    completion(.failure(error))
                } else {
                    self.presentImageError(error)
                }
            }
        }
    }

    private func clipboardPNGData() -> Data? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png),
           NSBitmapImageRep(data: data) != nil {
            return data
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return png
        }
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff) {
            return bitmap.representation(using: .png, properties: [:])
        }
        return nil
    }

    private func presentImageError(_ error: Error) {
        NSAlert(error: error).beginSheetModal(for: documentWindow)
    }

    func renameImage(at imageURL: URL) {
        guard !isEditorCommitInFlight else {
            commitEdits(exitAfter: false) { [weak self] success in
                guard success else { return }
                self?.renameImage(at: imageURL)
            }
            return
        }
        guard let markdownURL = currentFileURL else { return }
        let picturesDirectory = MarkdownAssetResolution.picturesDirectory(
            forMarkdownFile: markdownURL
        ).standardizedFileURL
        guard imageURL.standardizedFileURL.deletingLastPathComponent() == picturesDirectory,
              FileManager.default.fileExists(atPath: imageURL.path) else { return }

        let presentRename: (String) -> Void = { [weak self] markdown in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Rename Image", comment: "Image rename alert title")
            alert.informativeText = NSLocalizedString(
                "Choose a new name for this image.",
                comment: "Image rename alert message"
            )
            let field = NSTextField(string: imageURL.deletingPathExtension().lastPathComponent)
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Image rename button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: self.documentWindow) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                self.applyImageRename(
                    imageURL,
                    newName: field.stringValue,
                    markdownURL: markdownURL,
                    markdown: markdown
                )
            }
        }

        if let editor = mainSplit?.editorViewController {
            editor.fetchMarkdown { markdown in
                guard let markdown else { return }
                presentRename(markdown)
            }
        } else if let markdown = currentMarkdown {
            presentRename(markdown)
        }
    }

    private func applyImageRename(_ imageURL: URL,
                                  newName: String,
                                  markdownURL: URL,
                                  markdown: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            NSSound.beep()
            return
        }
        let extensionName = imageURL.pathExtension
        let enteredExtension = URL(fileURLWithPath: trimmed).pathExtension
        guard enteredExtension.isEmpty
                || enteredExtension.caseInsensitiveCompare(extensionName) == .orderedSame else {
            NSSound.beep()
            return
        }
        let fileName = enteredExtension.isEmpty
            ? "\(trimmed).\(extensionName)"
            : trimmed
        let imageDirectory = imageURL.deletingLastPathComponent().standardizedFileURL
        let destination = imageDirectory
            .appendingPathComponent(fileName, isDirectory: false)
        guard destination.standardizedFileURL != imageURL.standardizedFileURL,
              destination.standardizedFileURL.deletingLastPathComponent() == imageDirectory,
              !FileManager.default.fileExists(atPath: destination.path),
              let oldPath = MarkdownAssetResolution.markdownPath(
                for: imageURL,
                from: markdownURL
              ),
              let newPath = MarkdownAssetResolution.markdownPath(
                for: destination,
                from: markdownURL
              ),
              let updated = MarkdownAssetResolution.replacingImagePath(
                in: markdown,
                from: oldPath,
                to: newPath
              ),
              updated != markdown else {
            NSSound.beep()
            return
        }

        do {
            try FileManager.default.moveItem(at: imageURL, to: destination)
        } catch {
            presentImageError(error)
            return
        }

        let diskState = diskFileState(
            for: currentFileURL,
            expectedMarkdown: editorBaselineMarkdown ?? currentMarkdown
        )
        saveEditedMarkdown(updated, diskState: diskState) { [weak self] result in
            guard let self else { return }
            switch result {
            case .saved:
                self.currentMarkdown = updated
                self.markdownDocument?.replaceContents(markdown: updated, fileURL: markdownURL)
                if let editor = self.mainSplit?.editorViewController {
                    editor.replaceMarkdown(updated)
                    self.editorDraftMarkdown = nil
                    self.editorBaselineMarkdown = updated
                    self.editorChangeRevision = 0
                    self.hasUnsavedEditorChanges = false
                }
                self.renderCurrentDocument(text: updated, fileURL: markdownURL)
            case let .reloaded(externalMarkdown):
                self.restoreRenamedImage(from: destination, to: imageURL)
                self.adoptExternalMarkdown(
                    externalMarkdown,
                    editor: self.mainSplit?.editorViewController,
                    exitAfter: false
                )
            case .cancelled:
                self.restoreRenamedImage(from: destination, to: imageURL)
                self.rerenderCurrentPreview()
            }
        }
    }

    private func restoreRenamedImage(from destination: URL, to original: URL) {
        do {
            try FileManager.default.moveItem(at: destination, to: original)
        } catch {
            presentImageError(error)
        }
    }
}
