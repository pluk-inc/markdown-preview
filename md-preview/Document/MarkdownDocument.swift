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

    override var allowsDocumentSharing: Bool {
        guard let fileURL else { return false }
        return !fileURL.isExistingDirectory
    }

    override func makeWindowControllers() {
        let signpost = LaunchSignposts.begin("makeWindowController")
        defer { LaunchSignposts.end(signpost) }
        // Start decoding the saved image before the window is built.
        let snapshot = folderURL == nil
            ? DocumentSnapshotCache.shared.prefetch(fileURL: fileURL, markdown: markdown)
            : nil
        let controller = DocumentWindowController()
        controller.pendingSnapshot = snapshot
        addWindowController(controller)
        if let folderURL {
            controller.display(markdown: "", fileURL: nil)
            controller.openFolder(folderURL)
            return
        }
        if fileURL == nil {
            controller.prepareSidebarForUntitledDocument()
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

    /// Finder ▸ Print, `open -p`, and a scripted print reach the document
    /// here, not through the Print menu item. AppKit's version asks for a
    /// synchronous print operation, which a web view cannot give (its
    /// pagination is asynchronous), and throws without one. The print panel
    /// shows even when the sender asked for none: a job should not go to a
    /// printer with a font size and paper the user never saw. For the same
    /// reason the sender's print settings are not applied.
    override func print(
        withSettings printSettings: [NSPrintInfo.AttributeKey: Any],
        showPrintPanel: Bool,
        delegate: Any?,
        didPrint didPrintSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let finish: (Bool) -> Void = { didPrint in
            guard let delegate = delegate as? NSObject, let didPrintSelector,
                  let implementation = delegate.method(for: didPrintSelector) else { return }
            typealias DidPrint = @convention(c) (NSObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(implementation, to: DidPrint.self)(delegate, didPrintSelector, self, didPrint, contextInfo)
        }
        // A file opened only to print has no window yet.
        if windowControllers.isEmpty {
            makeWindowControllers()
            showWindows()
        }
        guard let split = (windowControllers.first as? DocumentWindowController)?.mainSplit else {
            finish(false)
            return
        }
        split.printDocumentWhenPainted(completion: finish)
    }

    func replaceContents(markdown: String, fileURL: URL) {
        markdownStorage.withLock { $0 = markdown }
        replaceFileURL(fileURL)
    }

    func replaceContents(markdown: String) {
        markdownStorage.withLock { $0 = markdown }
        updateChangeCount(.changeCleared)
    }

    /// Release notes are titled by what they hold, not by their cache file
    /// name; AppKit uses this when it syncs the window and tab title.
    override var displayName: String! {
        get { ReleaseNotes.title(for: fileURL) ?? super.displayName }
        set { super.displayName = newValue }
    }

    func replaceFileURL(_ fileURL: URL) {
        self.fileURL = fileURL
        updateChangeCount(.changeCleared)
    }
}
