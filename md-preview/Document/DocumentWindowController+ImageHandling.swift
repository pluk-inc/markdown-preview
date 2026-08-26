//
//  DocumentWindowController+ImageHandling.swift
//  Markdown Preview
//

import AppKit

extension DocumentWindowController {
    func pasteImage(at from: Int, replacing to: Int) {
        guard isEditing,
              let markdownURL = currentFileURL,
              let editor = mainSplit?.editorViewController else { return }
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

        do {
            try insertPastedImage(data,
                                  forMarkdownFile: markdownURL,
                                  editor: editor,
                                  from: from,
                                  to: to)
        } catch {
            presentImagePermissionPanel(data,
                                        markdownURL: markdownURL,
                                        editor: editor,
                                        from: from,
                                        to: to)
        }
    }

    private func insertPastedImage(_ data: Data,
                                   forMarkdownFile markdownURL: URL,
                                   editor: EditorViewController,
                                   from: Int,
                                   to: Int) throws {
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
        editor.insertMarkdown(
            "![\(label)](\(relativePath))",
            from: from,
            to: to
        )
    }

    private func presentImagePermissionPanel(_ data: Data,
                                             markdownURL: URL,
                                             editor: EditorViewController,
                                             from: Int,
                                             to: Int) {
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
            guard let self, response == .OK, let chosen = panel.url else { return }
            guard chosen.standardizedFileURL == parentDirectory else {
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
                                           to: to)
            } catch {
                self.presentImageError(error)
            }
        }
    }

    private func clipboardPNGData() -> Data? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) {
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

        let diskState = diskFileState(for: currentFileURL, expectedMarkdown: markdown)
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
                self.currentMarkdown = externalMarkdown
                self.markdownDocument?.replaceContents(
                    markdown: externalMarkdown,
                    fileURL: markdownURL
                )
                self.renderCurrentDocument(text: externalMarkdown, fileURL: markdownURL)
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
