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
        updateChangeCount(.changeCleared)
    }
}
