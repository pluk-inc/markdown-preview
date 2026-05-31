//
//  AppDelegate.swift
//  md-preview
//

import Cocoa
import Sparkle
import UniformTypeIdentifiers

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private weak var hideSidebarMenuItem: NSMenuItem?
    private weak var outlineMenuItem: NSMenuItem?
    private weak var filesMenuItem: NSMenuItem?
    private var isOpeningDocumentFromPrompt = false
    private var isPromptingForDocument = false
    private var isDocumentPromptScheduled = false

    private static let markdownFileExtensions = ["md", "markdown", "mdown", "txt"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSidebarViewMenuItems()
        installGoMenu()
        installZoomMenuItemIcons()
        scheduleDocumentPrompt(requiresNoDocuments: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        scheduleDocumentPrompt(requiresNoDocuments: true)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            scheduleDocumentPrompt(requiresNoDocuments: true)
            return false
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.updater.checkForUpdates()
    }

    @IBAction func openDocument(_ sender: Any?) {
        promptForDocument()
    }

    @IBAction func performFindPanelAction(_ sender: Any?) {
        activeDocumentWindowController?.handleFindAction(sender)
    }

    @IBAction func performTextFinderAction(_ sender: Any?) {
        activeDocumentWindowController?.handleFindAction(sender)
    }

    @objc private func hideSidebarFromMenu(_ sender: Any?) {
        activeDocumentWindowController?.hideSidebarFromMenu(sender)
        syncSidebarViewMenuState()
    }

    @objc private func selectOutlineMode(_ sender: Any?) {
        activeDocumentWindowController?.selectOutlineMode(sender)
        syncSidebarViewMenuState()
    }

    @objc private func selectFilesMode(_ sender: Any?) {
        activeDocumentWindowController?.selectFilesMode(sender)
        syncSidebarViewMenuState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        syncSidebarViewMenuState()
        switch menuItem.action {
        case #selector(hideSidebarFromMenu(_:)),
             #selector(selectOutlineMode(_:)),
             #selector(selectFilesMode(_:)),
             #selector(performFindPanelAction(_:)),
             #selector(performTextFinderAction(_:)):
            return activeDocumentWindowController != nil
        default:
            return true
        }
    }

    private var activeDocumentWindowController: DocumentWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? DocumentWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? DocumentWindowController {
            return controller
        }
        return NSDocumentController.shared.documents
            .flatMap(\.windowControllers)
            .compactMap { $0 as? DocumentWindowController }
            .first
    }

    private func promptForDocument() {
        guard !isPromptingForDocument else { return }
        isPromptingForDocument = true
        defer { isPromptingForDocument = false }

        let panel = makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.isExistingDirectory {
            openFolder(url)
            return
        }

        isOpeningDocumentFromPrompt = true
        NSDocumentController.shared.openDocument(withContentsOf: url,
                                                 display: true) { [weak self] _, _, error in
            self?.isOpeningDocumentFromPrompt = false
            guard let error else { return }
            NSAlert(error: error).runModal()
        }
    }

    private func scheduleDocumentPrompt(requiresNoDocuments: Bool = false) {
        guard !isPromptingForDocument,
              !isDocumentPromptScheduled else { return }

        isDocumentPromptScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDocumentPromptScheduled = false
            guard !requiresNoDocuments || NSDocumentController.shared.documents.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.promptForDocument()
        }
    }

    private func openFolder(_ url: URL) {
        if let controller = activeDocumentWindowController {
            controller.openFolder(url)
            return
        }

        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let controller = document.windowControllers.first as? DocumentWindowController else {
            return
        }
        controller.openFolder(url)
    }

    private func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a Markdown file or folder"
        panel.allowedContentTypes = Self.markdownFileExtensions
            .compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    private func installGoMenu() {
        guard let mainMenu = NSApp.mainMenu,
              mainMenu.items.first(where: { $0.title == "Go" }) == nil else { return }

        func arrow(_ functionKey: Int) -> String {
            UnicodeScalar(functionKey).map { String(Character($0)) } ?? ""
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        func makeItem(_ title: String,
                      action: Selector,
                      keyEquivalent: String,
                      modifiers: NSEvent.ModifierFlags,
                      symbol: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(symbolConfig) {
                image.isTemplate = true
                item.image = image
            }
            return item
        }

        let menu = NSMenu(title: "Go")

        menu.addItem(makeItem("Up",
                              action: #selector(NSResponder.scrollLineUp(_:)),
                              keyEquivalent: arrow(NSUpArrowFunctionKey),
                              modifiers: [],
                              symbol: "arrow.up"))
        menu.addItem(makeItem("Down",
                              action: #selector(NSResponder.scrollLineDown(_:)),
                              keyEquivalent: arrow(NSDownArrowFunctionKey),
                              modifiers: [],
                              symbol: "arrow.down"))
        menu.addItem(makeItem("Page Up",
                              action: #selector(NSResponder.scrollPageUp(_:)),
                              keyEquivalent: arrow(NSPageUpFunctionKey),
                              modifiers: [],
                              symbol: "chevron.up.square"))
        menu.addItem(makeItem("Page Down",
                              action: #selector(NSResponder.scrollPageDown(_:)),
                              keyEquivalent: arrow(NSPageDownFunctionKey),
                              modifiers: [],
                              symbol: "chevron.down.square"))

        menu.addItem(.separator())

        menu.addItem(makeItem("Previous Item",
                              action: #selector(MarkdownWebView.mdScrollPreviousHeading(_:)),
                              keyEquivalent: arrow(NSUpArrowFunctionKey),
                              modifiers: .option,
                              symbol: "arrow.up.document"))
        menu.addItem(makeItem("Next Item",
                              action: #selector(MarkdownWebView.mdScrollNextHeading(_:)),
                              keyEquivalent: arrow(NSDownArrowFunctionKey),
                              modifiers: .option,
                              symbol: "arrow.down.document"))

        menu.addItem(.separator())

        menu.addItem(makeItem("Top of Document",
                              action: #selector(NSResponder.scrollToBeginningOfDocument(_:)),
                              keyEquivalent: arrow(NSUpArrowFunctionKey),
                              modifiers: .command,
                              symbol: "arrow.up.to.line"))
        menu.addItem(makeItem("Bottom of Document",
                              action: #selector(NSResponder.scrollToEndOfDocument(_:)),
                              keyEquivalent: arrow(NSDownArrowFunctionKey),
                              modifiers: .command,
                              symbol: "arrow.down.to.line"))

        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goItem.submenu = menu

        let insertIndex = mainMenu.items.firstIndex(where: { $0.title == "Window" })
            ?? mainMenu.items.count
        mainMenu.insertItem(goItem, at: insertIndex)
    }

    private func installZoomMenuItemIcons() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu else { return }
        let icons: [(title: String, symbol: String)] = [
            ("Actual Size", "magnifyingglass"),
            ("Zoom In", "plus.magnifyingglass"),
            ("Zoom Out", "minus.magnifyingglass")
        ]
        for (title, symbol) in icons {
            guard let item = viewMenu.items.first(where: { $0.title == title }),
                  let image = NSImage(systemSymbolName: symbol,
                                      accessibilityDescription: title)
            else { continue }
            image.isTemplate = true
            item.image = image
        }
    }

    private func installSidebarViewMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu else { return }

        if let existing = viewMenu.items.first(where: { $0.title == "Show Sidebar" }) {
            viewMenu.removeItem(existing)
        }
        guard viewMenu.items.first(where: { $0.action == #selector(hideSidebarFromMenu(_:)) }) == nil else {
            return
        }

        let insertIndex = (viewMenu.items.firstIndex(where: { $0.isSeparatorItem }) ?? -1) + 1

        let hide = makeSidebarViewMenuItem(title: "Hide Sidebar",
                                           symbol: "sidebar.leading",
                                           keyEquivalent: "1",
                                           action: #selector(hideSidebarFromMenu(_:)))
        viewMenu.insertItem(hide, at: insertIndex)
        hideSidebarMenuItem = hide

        let outline = makeSidebarViewMenuItem(title: "Table of Contents",
                                              symbol: "list.bullet.indent",
                                              keyEquivalent: "2",
                                              action: #selector(selectOutlineMode(_:)))
        viewMenu.insertItem(outline, at: insertIndex + 1)
        outlineMenuItem = outline

        let files = makeSidebarViewMenuItem(title: "Project Navigator",
                                            symbol: "folder",
                                            keyEquivalent: "3",
                                            action: #selector(selectFilesMode(_:)))
        viewMenu.insertItem(files, at: insertIndex + 2)
        filesMenuItem = files

        viewMenu.insertItem(.separator(), at: insertIndex + 3)
    }

    private func makeSidebarViewMenuItem(title: String,
                                         symbol: String,
                                         keyEquivalent: String,
                                         action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.option, .command]
        item.target = self
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.isTemplate = true
            item.image = image
        }
        return item
    }

    private func syncSidebarViewMenuState() {
        guard let state = activeDocumentWindowController?.sidebarMenuState else {
            hideSidebarMenuItem?.state = .off
            outlineMenuItem?.state = .off
            filesMenuItem?.state = .off
            return
        }
        hideSidebarMenuItem?.state = state.sidebarVisible ? .off : .on
        outlineMenuItem?.state = (state.sidebarVisible && state.mode == .outline) ? .on : .off
        filesMenuItem?.state = (state.sidebarVisible && state.mode == .files) ? .on : .off
    }
}
