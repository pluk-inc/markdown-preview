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

    override init() {
        super.init()
        hasUndoManager = false
    }

    override nonisolated class var autosavesInPlace: Bool {
        false
    }

    override var isDocumentEdited: Bool {
        false
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
        throw CocoaError(.fileWriteNoPermission)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(save(_:)),
             #selector(saveAs(_:)),
             #selector(saveTo(_:)),
             #selector(revertToSaved(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    func replaceContents(markdown: String, fileURL: URL) {
        markdownStorage.withLock { $0 = markdown }
        replaceFileURL(fileURL)
    }

    func replaceFileURL(_ fileURL: URL) {
        self.fileURL = fileURL
        updateChangeCount(.changeCleared)
    }
}
