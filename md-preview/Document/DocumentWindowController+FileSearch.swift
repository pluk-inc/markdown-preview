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

    /// Without this the button would stay enabled with no project mounted,
    /// while the menu item greyed out — the default validation only checks
    /// that something in the responder chain answers the selector, and this
    /// one always does.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.action == #selector(searchForDocument(_:)) else { return true }
        return projectRootURL != nil
    }

    func openSearchResult(_ url: URL, in target: FileSearchPanelController.OpenTarget) {
        switch target {
        case .currentTab:
            // Returns early by design when the file is already showing, which
            // is the right nothing-to-do.
            present(url: url)
        case .newTab:
            openInNewTab(url)
        case .newWindow:
            openInNewWindow(url)
        }
    }
}
