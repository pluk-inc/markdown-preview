//
//  MarkdownDocumentController.swift
//  md-preview
//

import Cocoa

final class MarkdownDocumentController: NSDocumentController {
    static let recentDocumentsDidClear = Notification.Name("MarkdownDocumentController.recentDocumentsDidClear")

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        NotificationCenter.default.post(name: Self.recentDocumentsDidClear, object: self)
    }

    override func beginOpenPanel(
        _ openPanel: NSOpenPanel,
        forTypes inTypes: [String]?
    ) async -> Int {
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        openPanel.message = NSLocalizedString(
            "Choose a Markdown file or folder",
            comment: "Open panel prompt"
        )
        // The file types come from `inTypes`, the document types in
        // Info.plist: super replaces `allowedContentTypes` with them.
        return await super.beginOpenPanel(openPanel, forTypes: inTypes)
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        if url.isExistingDirectory,
           let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openFolder(url)
            completionHandler(nil, false, nil)
            return
        }

        super.openDocument(
            withContentsOf: url,
            display: displayDocument,
            completionHandler: completionHandler
        )
    }

    override func openUntitledDocumentAndDisplay(_ displayDocument: Bool) throws -> NSDocument {
        let document = try super.openUntitledDocumentAndDisplay(displayDocument)
        if displayDocument {
            (document.windowControllers.first as? DocumentWindowController)?
                .enterEditMode(autofocus: true)
        }
        return document
    }
}
