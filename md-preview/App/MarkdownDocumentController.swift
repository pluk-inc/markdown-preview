//
//  MarkdownDocumentController.swift
//  md-preview
//

import Cocoa
import UniformTypeIdentifiers

final class MarkdownDocumentController: NSDocumentController {
    static let recentDocumentsDidClear = Notification.Name("MarkdownDocumentController.recentDocumentsDidClear")

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        NotificationCenter.default.post(name: Self.recentDocumentsDidClear, object: self)
    }

    private static let markdownFileExtensions = ["md", "markdown", "mdown", "mdx", "txt"]

    /// Set by File ▸ New Tab for the next open panel only.
    private var nextOpenPanelOpensTab = false
    /// Set while that panel is up, until the document it produces has
    /// opened (or turned out to be open already). Armed before the panel
    /// runs because its New Document button opens the untitled document
    /// while the panel is still up — the panel then returns as cancelled.
    private var pendingPanelTabOpen = false
    private let previewHandoffDeadline = Date().addingTimeInterval(5)
    private var handoffQueries: [UUID: (observer: NSObjectProtocol, completion: (URL?) -> Void)] = [:]

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
        openPanel.allowedContentTypes = Self.markdownFileExtensions
            .compactMap { UTType(filenameExtension: $0) }
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

        if Date() < previewHandoffDeadline, url.isFileURL,
           MarkdownAssetResolution.isMarkdownDocument(url),
           let appID = Bundle.main.bundleIdentifier {
            (NSApp.delegate as? AppDelegate)?.beginQuickLookHandoff()
            queryQuickLook(source: url, appID: appID) { [weak self] target in
                guard let self else { return }
                var documentURL = url
                var fragment: String?
                if let target {
                    if target.scheme?.lowercased() == ExternalOpenScheme.scheme {
                        documentURL = ExternalOpenScheme.resolvedURL(opening: target) ?? url
                        fragment = ExternalOpenScheme.fragment(opening: target)
                    } else {
                        ExternalLinkOpener.open(target, window: nil)
                    }
                }
                self.openDocumentNormally(withContentsOf: documentURL, display: displayDocument) { document, wasOpen, error in
                    DocumentWindowController.scrollToAnchorWhenReady(fragment, in: document)
                    completionHandler(document, wasOpen, error)
                }
            }
            return
        }

        openDocumentNormally(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    private func openDocumentNormally(
        withContentsOf url: URL,
        display: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        super.openDocument(
            withContentsOf: url,
            display: display,
            completionHandler: completionHandler
        )
    }

    /// Finder's host opens the previewed file. During startup ask the live
    /// extension before making a document window. Query each source independently
    /// so restoring another document cannot steal the clicked link. After the
    /// startup window, opens are immediate; unanswered queries cost at most 0.3s.
    private func queryQuickLook(source: URL, appID: String, completion: @escaping (URL?) -> Void) {
        let query = QuickLookLinkHandoff.Query(id: UUID(), source: source)
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: QuickLookLinkHandoff.notification("reply", appID: appID),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let reply = QuickLookLinkHandoff.decode(QuickLookLinkHandoff.Reply.self, object: note.object),
                  reply.id == query.id, QuickLookLinkHandoff.isSupported(reply.target) else { return }
            MainActor.assumeIsolated { self?.completeQuickLookQuery(query.id, target: reply.target) }
        }
        handoffQueries[query.id] = (observer, completion)
        DistributedNotificationCenter.default().postNotificationName(
            QuickLookLinkHandoff.notification("query", appID: appID),
            object: QuickLookLinkHandoff.encode(query), userInfo: nil, deliverImmediately: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.completeQuickLookQuery(query.id, target: nil)
        }
    }

    private func completeQuickLookQuery(_ id: UUID, target: URL?) {
        guard let query = handoffQueries.removeValue(forKey: id) else { return }
        DistributedNotificationCenter.default().removeObserver(query.observer)
        query.completion(target)
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
