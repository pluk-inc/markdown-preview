//
//  MarkdownDocument.swift
//  md-preview
//

import Cocoa
import Synchronization

final class MarkdownDocument: NSDocument {

    private nonisolated let markdownStorage = Mutex("")
    private nonisolated let folderStorage = Mutex<URL?>(nil)

    var markdown: String {
        markdownStorage.withLock { $0 }
    }

    private var folderURL: URL? {
        folderStorage.withLock { $0 }
    }

    /// True while the document is in the middle of a save operation.
    /// Used by DocumentWindowController to suppress FileWatcher callbacks
    /// that would otherwise show a false "external change" alert.
    private nonisolated let savingStorage = Mutex(false)

    var isSaving: Bool {
        savingStorage.withLock { $0 }
    }

    /// Whether the file at `url` was written by something other than this
    /// document. The document records the file's modification date at every
    /// load and save (`fileModificationDate`); a FileWatcher event whose
    /// on-disk date is not newer than that record came from our own write
    /// and must not be treated as an external change. This closes the race
    /// where the watcher's debounced callback lands after `isSaving` has
    /// already been reset.
    func isFileModifiedExternally(at url: URL) -> Bool {
        guard let recorded = fileModificationDate else { return true }
        guard let diskDate = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate else { return true }
        return diskDate > recorded
    }

    override init() {
        super.init()
        hasUndoManager = false  // NSTextView manages its own undo stack
    }

    override nonisolated class var autosavesInPlace: Bool {
        true
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        if let folderURL {
            controller.display(markdown: "", fileURL: nil)
            controller.openFolder(folderURL)
            return
        }
        controller.display(markdown: markdown, fileURL: fileURL)
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        if url.isExistingDirectory {
            folderStorage.withLock { $0 = url.standardizedFileURL }
            markdownStorage.withLock { $0 = "" }
            return
        }

        let data = try Data(contentsOf: url)
        try read(from: data, ofType: typeName)
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        folderStorage.withLock { $0 = nil }
        markdownStorage.withLock { $0 = text }
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        let text = markdownStorage.withLock { $0 }
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    override nonisolated func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        savingStorage.withLock { $0 = true }
        defer { savingStorage.withLock { $0 = false } }
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
    }

    /// Updates the document's markdown content and marks it as edited.
    ///
    /// Called by the editor pane when the user types. Triggers autosave via
    /// `updateChangeCount(.changeDone)`.
    ///
    /// - Parameter newText: The full document text from the editor.
    func setMarkdown(_ newText: String) {
        markdownStorage.withLock { $0 = newText }
        updateChangeCount(.changeDone)
    }

    /// Synchronously writes any unsaved edits to the current file.
    ///
    /// Called before the window controller re-points the document at a
    /// different file (project-navigator switch), so edits to the previous
    /// file are never discarded by the change-count reset in
    /// `replaceFileURL`, and a pending autosave can never land on the new
    /// URL with the old file's text.
    func persistPendingEdits() {
        guard isDocumentEdited, let url = fileURL else { return }
        do {
            try writeSafely(to: url,
                            ofType: fileType ?? "net.daringfireball.markdown",
                            for: .saveOperation)
            fileModificationDate = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            updateChangeCount(.changeCleared)
        } catch {
            presentError(error)
        }
    }

    /// Reverting (File ▸ Revert To Saved) re-reads storage via `read(from:)`,
    /// which knows nothing about the window's editor/preview panes. Refresh
    /// them from the re-read content so the command visibly takes effect —
    /// otherwise the editor keeps the rejected text and the next keystroke
    /// would autosave it right back over the file.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        fileModificationDate = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        for controller in windowControllers {
            (controller as? DocumentWindowController)?.documentDidRevert()
        }
    }

    /// Replaces both the markdown content and the file URL.
    ///
    /// Used when switching to a different file in the project navigator.
    /// Clears the document's dirty state via `updateChangeCount(.changeCleared)`.
    func replaceContents(markdown: String, fileURL: URL) {
        markdownStorage.withLock { $0 = markdown }
        replaceFileURL(fileURL)
    }

    func replaceFileURL(_ fileURL: URL) {
        self.fileURL = fileURL
        // Record the on-disk modification date so FileWatcher events caused
        // by this document's own subsequent saves can be told apart from
        // genuinely external writes (see `isFileModifiedExternally`).
        fileModificationDate = try? fileURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        updateChangeCount(.changeCleared)
    }
}
