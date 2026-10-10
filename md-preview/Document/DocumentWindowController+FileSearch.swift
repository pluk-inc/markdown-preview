//
//  DocumentWindowController+FileSearch.swift
//  md-preview
//
//  Wires the Search for Document palette to the window: which project it
//  searches, and what opening a result actually does.
//

import Cocoa

extension DocumentWindowController {

    /// The folder the sidebar has mounted. The search palette looks at exactly
    /// this, so what it offers always agrees with what the navigator shows.
    var projectRootURL: URL? {
        (documentWindow.contentViewController as? MainSplitViewController)?.projectRootURL
    }

    @objc func searchForDocument(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        // Keep modal document operations in control of keyboard focus.
        guard documentWindow.attachedSheet == nil else {
            NSSound.beep()
            return
        }

        if let existing = fileSearchPalette {
            existing.view.window?.makeKeyAndOrderFront(nil)
            return
        }
        let palette = FileSearchPanelController(projectRoot: split.projectRootURL)
        palette.onOpen = { [weak self] url, target in
            self?.openSearchResult(url, in: target)
        }
        palette.onRequestOpenFolder = { [weak self] in
            self?.openDocument(nil)
        }
        palette.onDismiss = { [weak self] in self?.fileSearchPalette = nil }
        fileSearchPalette = palette
        palette.present(relativeTo: documentWindow)
    }

    /// Offered in Customize Toolbar but deliberately absent from the default
    /// set: the toolbar already carries a search *field* for in-document find,
    /// and two magnifiers side by side would read as the same feature twice.
    /// A distinct symbol for the same reason — this one searches for a
    /// document, the field searches inside one.
    func makeSearchForDocumentItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .searchForDocument)
        let label = NSLocalizedString("Search for Document", comment: "Search for Document toolbar item label")
        item.label = label
        item.paletteLabel = label
        item.toolTip = NSLocalizedString("Search for a file by name",
                                         comment: "Search for Document toolbar item tooltip")
        item.image = NSImage(systemSymbolName: "doc.text.magnifyingglass",
                             accessibilityDescription: label)
        item.isBordered = true
        item.action = #selector(searchForDocument(_:))
        return item
    }

    /// Recent files are available even without a mounted project.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.action == #selector(searchForDocument(_:)) else { return true }
        return true
    }

    func openSearchResult(_ url: URL, in target: FileSearchPanelController.OpenTarget) {
        switch target {
        case .currentTab:
            // An alias of the edited document is still the current file.
            // Leave any pending open alone when this selection is a no-op.
            guard currentFileURL.map(FileSearchResults.resolvedIdentity)
                != FileSearchResults.resolvedIdentity(url) else { return }
            let requestID = UUID()
            searchOpenRequestID = requestID
            let preserveEditMode = isEditing || pendingEditModeURL != nil
            if isEditing || hasPendingEditorChanges {
                requestEndEditing(keepAccessoryMounted: true) { [weak self] success in
                    guard let self, success, self.searchOpenRequestID == requestID else { return }
                    self.readSearchResult(url, requestID: requestID, preserveEditMode: preserveEditMode)
                }
            } else {
                readSearchResult(url, requestID: requestID, preserveEditMode: preserveEditMode)
            }
        case .newTab:
            openInNewTab(url)
        case .newWindow:
            openInNewWindow(url)
        }
    }

    private func readSearchResult(_ url: URL, requestID: UUID, preserveEditMode: Bool) {
        let originalURL = currentFileURL
        // Read after the save decision, but before replacing the current tab.
        // Navigation uses this content directly, with no second fallible read.
        Task { @concurrent [weak self] in
            let result = Result { try String(contentsOf: url, encoding: .utf8) }
            await self?.finishSearchOpen(result, url: url, originalURL: originalURL,
                                        requestID: requestID, preserveEditMode: preserveEditMode)
        }
    }

    private func finishSearchOpen(_ result: Result<String, Error>, url: URL,
                                  originalURL: URL?, requestID: UUID, preserveEditMode: Bool) {
        // windowWillClose invalidates the request. A background tab may be
        // hidden after opening another tab, but its pending read is still valid.
        guard searchOpenRequestID == requestID, currentFileURL == originalURL,
              documentWindow.attachedSheet == nil else { return }
        // Editing may have resumed during a slow read. Resolve it and read
        // again afterward rather than applying content from before that decision.
        if isEditing || hasPendingEditorChanges {
            openSearchResult(url, in: .currentTab)
            return
        }
        searchOpenRequestID = nil
        switch result {
        case .success(let markdown):
            present(url: url, preservingEditMode: preserveEditMode,
                    intent: .normal, fragment: nil, loadedMarkdown: markdown)
        case .failure(let error):
            if preserveEditMode { enterEditMode() }
            NSAlert(error: error).beginSheetModal(for: documentWindow)
        }
    }
}
