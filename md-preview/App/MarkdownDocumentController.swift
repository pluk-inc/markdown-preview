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

    /// Set by File ▸ New Tab for the next open panel only.
    private var nextOpenPanelOpensTab = false
    /// Set while that panel is up, until the document it produces has
    /// opened (or turned out to be open already). Armed before the panel
    /// runs because its New Document button opens the untitled document
    /// while the panel is still up — the panel then returns as cancelled.
    private var pendingPanelTabOpen = false

    /// File ▸ New Tab. Runs the same panel as File ▸ Open — including the
    /// system's New Document button, which only the document controller's
    /// own panel gets — and opens whatever it produces as a tab of the
    /// front window.
    func openDocumentInNewTab(_ sender: Any?) {
        nextOpenPanelOpensTab = true
        openDocument(sender)
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
        if nextOpenPanelOpensTab {
            nextOpenPanelOpensTab = false
            pendingPanelTabOpen = true
            DocumentWindowController.markNextWindowAsTab()
        }
        let response = await super.beginOpenPanel(openPanel, forTypes: inTypes)
        if response == NSApplication.ModalResponse.cancel.rawValue {
            clearPendingPanelTabOpen()
        }
        return response
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        let completionHandler = finishingPanelTabOpen(completionHandler)
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
        defer { clearPendingPanelTabOpen() }
        let document = try super.openUntitledDocumentAndDisplay(displayDocument)
        if displayDocument {
            (document.windowControllers.first as? DocumentWindowController)?
                .enterEditMode(autofocus: true)
        }
        return document
    }

    /// A file that is already open, or a folder, creates no window, so the
    /// one-shot tab request would otherwise leak to the next unrelated open.
    private func finishingPanelTabOpen(
        _ completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) -> (NSDocument?, Bool, Error?) -> Void {
        guard pendingPanelTabOpen else { return completionHandler }
        return { [weak self] document, wasAlreadyOpen, error in
            self?.clearPendingPanelTabOpen()
            completionHandler(document, wasAlreadyOpen, error)
        }
    }

    private func clearPendingPanelTabOpen() {
        guard pendingPanelTabOpen else { return }
        pendingPanelTabOpen = false
        DocumentWindowController.nextWindowRequestsTab = false
    }
}
