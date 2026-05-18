//
//  AppDelegate.swift
//  md-preview
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Sparkle
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let openWith = NSToolbarItem.Identifier("OpenWith")
    static let inspector = NSToolbarItem.Identifier("Inspector")
    static let share = NSToolbarItem.Identifier("Share")
    static let search = NSToolbarItem.Identifier("Search")
    static let sidebarMenu = NSToolbarItem.Identifier("SidebarMenu")
    static let printDocument = NSToolbarItem.Identifier("PrintDocument")
    static let copyMarkdown = NSToolbarItem.Identifier("CopyMarkdown")
    static let zoom = NSToolbarItem.Identifier("Zoom")
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    @IBOutlet var window: NSWindow!

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var pendingLaunchURL: URL?
    private var hasLaunched = false
    private var currentFileURL: URL?
    private var currentMarkdown: String?
    private var fileWatcher: FileWatcher?
    private var isInspectorToggleSelected = false
    private weak var openWithItem: NSMenuToolbarItem?
    private weak var inspectorItem: NSToolbarItem?
    private weak var inspectorButton: NSButton?
    private weak var copyItem: NSToolbarItem?
    private var copyFeedbackWork: DispatchWorkItem?
    private weak var searchField: NSSearchField?
    private weak var sidebarMenu: NSMenu?
    private weak var sidebarPopUpButton: NSPopUpButton?
    private weak var hideSidebarMenuItem: NSMenuItem?
    private weak var outlineMenuItem: NSMenuItem?
    private weak var filesMenuItem: NSMenuItem?
    private var findBar: FindBar?
    private var findBarAccessory: NSTitlebarAccessoryViewController?
    private var searchMode: SearchMode = .contains
    private var pendingFindWork: DispatchWorkItem?
    private static let findDebounceDelay: TimeInterval = 0.10

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if hasLaunched {
            present(url: url)
        } else {
            pendingLaunchURL = url
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        window.styleMask.insert(.fullSizeContentView)
        let split = MainSplitViewController()
        split.onSelectFile = { [weak self] url in
            self?.present(url: url)
        }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.center()
        window.setFrameAutosaveName("MainWindow")

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        window.toolbarStyle = .automatic

        installFindBar()
        installSidebarViewMenuItems()
        installGoMenu()
        installZoomMenuItemIcons()

        hasLaunched = true

        if let url = pendingLaunchURL {
            pendingLaunchURL = nil
            present(url: url)
            return
        }

        let panel = makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else {
            NSApp.terminate(nil)
            return
        }
        present(url: url)
    }

    private func present(url: URL) {
        // Switching to a different file blanks the preview so the previous
        // doc doesn't linger on screen during sheet dismissal + load.
        let isFileSwitch = currentFileURL != nil && currentFileURL != url
        currentFileURL = url
        currentMarkdown = nil
        window.title = url.lastPathComponent
        if isFileSwitch {
            (window.contentViewController as? MainSplitViewController)?.clearContent()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshOpenWithItem()
        loadFile(at: url)
        startWatching(url)
        offerToBecomeDefaultHandlerIfNeeded()
    }

    private func startWatching(_ url: URL) {
        fileWatcher?.cancel()
        let watcher = FileWatcher(url: url) { [weak self] in
            guard let self, self.currentFileURL == url else { return }
            self.loadFile(at: url, silentOnFailure: true)
        }
        watcher.onRename = { [weak self] newURL in
            self?.handleRename(to: newURL)
        }
        fileWatcher = watcher
    }

    /// The currently-open file moved (Finder rename, editor save-as, etc).
    /// Update the open URL and propagate it to the title, recent docs,
    /// Open With list, sidebar selection, and inspector — without
    /// re-rendering the WebView, since the markdown content didn't change.
    private func handleRename(to newURL: URL) {
        guard currentFileURL != nil else { return }
        currentFileURL = newURL
        window.title = newURL.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(newURL)
        refreshOpenWithItem()
        startWatching(newURL)
        if let markdown = currentMarkdown {
            (window.contentViewController as? MainSplitViewController)?
                .openFileURLDidChange(newURL, markdown: markdown)
        } else {
            loadFile(at: newURL, silentOnFailure: true)
        }
    }

    private static let didOfferDefaultHandlerKey = "MarkdownPreview.didOfferAsDefaultHandler"

    private func offerToBecomeDefaultHandlerIfNeeded() {
        let key = Self.didOfferDefaultHandlerKey
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        guard let markdownType = UTType("net.daringfireball.markdown")
                ?? UTType(filenameExtension: "md") else { return }

        let currentDefaultID = NSWorkspace.shared.urlForApplication(toOpen: markdownType)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        if currentDefaultID == Bundle.main.bundleIdentifier {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        UserDefaults.standard.set(true, forKey: key)
        Task { @concurrent in
            try? await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL,
                toOpen: markdownType
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            promptForFileAndPresent()
        }
        return true
    }

    private func promptForFileAndPresent() {
        let panel = makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        present(url: url)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .sidebarMenu,
            .sidebarTrackingSeparator,
            .openWith,
            .space,
            .zoom,
            .inspector,
            .share,
            .search
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .sidebarMenu,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .space,
            .openWith,
            .inspector,
            .share,
            .search,
            .printDocument,
            .copyMarkdown,
            .zoom
        ]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarMenu: return makeSidebarMenuItem(willBeInsertedIntoToolbar: flag)
        case .openWith: return makeOpenWithItem()
        case .inspector: return makeInspectorItem()
        case .share: return makeShareItem()
        case .search: return makeSearchItem()
        case .printDocument: return makePrintItem()
        case .copyMarkdown: return makeCopyItem()
        case .zoom: return makeZoomItem()
        default: return nil
        }
    }

    private func makeSidebarMenuItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .sidebarMenu)
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Sidebar options"

        // NSPopUpButton (pull-down) so a single click anywhere on the button
        // opens the menu and the chevron renders natively. NSMenuToolbarItem
        // either splits the click (icon vs chevron) or auto-promotes the first
        // item out of the dropdown — neither matches the Preview-style pulldown.
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.bezelStyle = .toolbar
        popup.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier("SidebarMenu")
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildSidebarMenu(menu)
        popup.menu = menu
        popup.sizeToFit()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])

        item.view = container
        if willBeInsertedIntoToolbar {
            sidebarMenu = menu
            sidebarPopUpButton = popup
            syncSidebarMenuState()
        }
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sidebarMenu else { return }
        rebuildSidebarMenu(menu)
        syncSidebarMenuState()
    }

    private func rebuildSidebarMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // Pull-down NSPopUpButton uses the first item as the always-visible
        // button face (showing only the icon thanks to imagePosition). The
        // dropdown shows items 2+, so the button face is reserved here.
        let face = NSMenuItem()
        face.image = sidebarFaceImage()
        menu.addItem(face)

        let hide = NSMenuItem(title: "Hide Sidebar",
                              action: #selector(hideSidebarFromMenu(_:)),
                              keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let outline = NSMenuItem(title: "Table of Contents",
                                 action: #selector(selectOutlineMode(_:)),
                                 keyEquivalent: "")
        outline.target = self
        menu.addItem(outline)

        let files = NSMenuItem(title: "Project Navigator",
                               action: #selector(selectFilesMode(_:)),
                               keyEquivalent: "")
        files.target = self
        menu.addItem(files)
        syncSidebarMenuState(for: menu)
    }

    private func syncSidebarMenuState() {
        syncSidebarViewMenuState()
        if let sidebarMenu {
            syncSidebarMenuState(for: sidebarMenu)
        }
    }

    private func syncSidebarViewMenuState() {
        let state = currentSidebarMenuState()
        hideSidebarMenuItem?.state = state.sidebarVisible ? .off : .on
        outlineMenuItem?.state = (state.sidebarVisible && state.mode == .outline) ? .on : .off
        filesMenuItem?.state = (state.sidebarVisible && state.mode == .files) ? .on : .off
    }

    private func syncSidebarMenuState(for menu: NSMenu) {
        let state = currentSidebarMenuState()
        menu.items.first { $0.action == #selector(hideSidebarFromMenu(_:)) }?.state = state.sidebarVisible ? .off : .on
        menu.items.first { $0.action == #selector(selectOutlineMode(_:)) }?.state = (state.sidebarVisible && state.mode == .outline) ? .on : .off
        menu.items.first { $0.action == #selector(selectFilesMode(_:)) }?.state = (state.sidebarVisible && state.mode == .files) ? .on : .off
    }

    private func currentSidebarMenuState() -> (sidebarVisible: Bool, mode: SidebarViewController.Mode) {
        let split = window.contentViewController as? MainSplitViewController
        let sidebarVisible = split?.isSidebarVisible ?? false
        let mode = split?.sidebarMode ?? .outline
        return (sidebarVisible, mode)
    }

    private func sidebarFaceImage() -> NSImage {
        let image = NSImage(systemSymbolName: "sidebar.leading",
                            accessibilityDescription: "Sidebar") ?? NSImage()
        image.isTemplate = true
        return image
    }

    @objc private func toggleSidebarFromMenu(_ sender: Any?) {
        (window.contentViewController as? MainSplitViewController)?.toggleSidebar()
        syncSidebarMenuState()
    }

    @objc private func hideSidebarFromMenu(_ sender: Any?) {
        guard let split = window.contentViewController as? MainSplitViewController,
              split.isSidebarVisible else { return }
        split.toggleSidebar()
        syncSidebarMenuState()
    }

    @objc private func selectOutlineMode(_ sender: Any?) {
        guard let split = window.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.outline)
        split.showSidebar()
        syncSidebarMenuState()
    }

    @objc private func selectFilesMode(_ sender: Any?) {
        guard let split = window.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.files)
        split.showSidebar()
        syncSidebarMenuState()
    }

    private func installGoMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }

        func arrow(_ functionKey: Int) -> String {
            UnicodeScalar(functionKey).map { String(Character($0)) } ?? ""
        }

        // Uniform point size keeps narrow glyphs (arrow.up/down) aligned with
        // wider ones (arrow.up.document, chevron.up.circle) in the icon column.
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

        // The XIB ships with a "Show Sidebar" item using the system
        // toggleSidebar: action. Replace it with the three-state menu Apple
        // uses in Preview (Hide Sidebar / Table of Contents / Folder Contents).
        if let existing = viewMenu.items.first(where: { $0.title == "Show Sidebar" }) {
            viewMenu.removeItem(existing)
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        syncSidebarMenuState()
        return true
    }

    private func makeInspectorItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .inspector)
        item.label = "Inspector"
        item.paletteLabel = "Get Info"
        item.toolTip = "Show the inspector"

        let button = NSButton(image: inspectorImage(),
                              target: self,
                              action: #selector(toggleInspectorAction(_:)))
        button.setButtonType(.pushOnPushOff)
        button.toolTip = item.toolTip
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 32),
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])

        item.view = container
        inspectorButton = button
        inspectorItem = item
        refreshInspectorToggleItem()
        return item
    }

    private func makeShareItem() -> NSToolbarItem {
        let item = NSSharingServicePickerToolbarItem(itemIdentifier: .share)
        item.label = "Share"
        item.paletteLabel = "Share"
        item.toolTip = "Share document"
        item.delegate = self
        return item
    }

    private func makePrintItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .printDocument)
        item.label = "Print"
        item.paletteLabel = "Print"
        item.toolTip = "Print document"
        item.image = NSImage(systemSymbolName: "printer",
                             accessibilityDescription: "Print")
        item.isBordered = true
        item.action = #selector(MainSplitViewController.printMarkdown(_:))
        return item
    }

    private func makeCopyItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .copyMarkdown)
        item.label = "Copy"
        item.paletteLabel = "Copy"
        item.toolTip = "Copy Markdown source to clipboard"
        item.image = copyIdleImage()
        item.isBordered = true
        item.target = self
        item.action = #selector(copyMarkdownAction(_:))
        copyItem = item
        return item
    }

    @objc private func copyMarkdownAction(_ sender: Any?) {
        guard let markdown = currentMarkdown, !markdown.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        flashCopyFeedback()
    }

    private static let copyFeedbackDuration: TimeInterval = 1.2

    private func flashCopyFeedback() {
        guard let item = copyItem else { return }
        copyFeedbackWork?.cancel()
        item.image = copyConfirmedImage()
        let work = DispatchWorkItem { [weak self] in
            self?.copyItem?.image = self?.copyIdleImage()
        }
        copyFeedbackWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.copyFeedbackDuration, execute: work
        )
    }

    private func copyIdleImage() -> NSImage? {
        NSImage(systemSymbolName: "document.on.document",
                accessibilityDescription: "Copy")
    }

    private func copyConfirmedImage() -> NSImage? {
        NSImage(systemSymbolName: "checkmark",
                accessibilityDescription: "Copied")
    }

    private func makeZoomItem() -> NSToolbarItemGroup {
        let smaller = NSImage(systemSymbolName: "textformat.size.smaller",
                              accessibilityDescription: "Zoom Out") ?? NSImage()
        let larger = NSImage(systemSymbolName: "textformat.size.larger",
                             accessibilityDescription: "Zoom In") ?? NSImage()
        let group = NSToolbarItemGroup(
            itemIdentifier: .zoom,
            images: [smaller, larger],
            selectionMode: .momentary,
            labels: ["Zoom Out", "Zoom In"],
            target: self,
            action: #selector(zoomSegmentAction(_:))
        )
        group.label = "Zoom"
        group.paletteLabel = "Zoom"
        group.toolTip = "Zoom"
        for (subitem, tooltip) in zip(group.subitems, ["Zoom Out", "Zoom In"]) {
            subitem.toolTip = tooltip
        }
        // .expanded keeps the two-segment "A A" pair visible like Books / Reader,
        // instead of collapsing into a single button + menu when space is tight.
        group.controlRepresentation = .expanded
        if let segmented = group.view as? NSSegmentedControl {
            segmented.setToolTip("Zoom Out", forSegment: 0)
            segmented.setToolTip("Zoom In", forSegment: 1)
        }
        return group
    }

    @objc private func zoomSegmentAction(_ sender: NSToolbarItemGroup) {
        guard let split = window.contentViewController as? MainSplitViewController else { return }
        switch sender.selectedIndex {
        case 0: split.zoomOutDocument(sender)
        case 1: split.zoomInDocument(sender)
        default: break
        }
    }

    private func inspectorImage() -> NSImage {
        let image = NSImage(systemSymbolName: "info",
                            accessibilityDescription: "Inspector") ?? NSImage()
        image.isTemplate = true
        return image
    }

    @objc private func toggleInspectorAction(_ sender: Any) {
        let isVisible = (window.contentViewController as? MainSplitViewController)?
            .toggleInspector() ?? false
        setInspectorToggleSelected(isVisible)
    }

    private func refreshInspectorToggleItem() {
        let isVisible = (window.contentViewController as? MainSplitViewController)?
            .isInspectorVisible ?? false
        setInspectorToggleSelected(isVisible)
    }

    private func setInspectorToggleSelected(_ isSelected: Bool) {
        isInspectorToggleSelected = isSelected
        inspectorButton?.state = isSelected ? .on : .off
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let currentMarkdown else { return [] }
        return [currentMarkdown]
    }

    private func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .search)
        item.label = "Search"
        item.toolTip = "Search in document"
        item.preferredWidthForSearchField = 320
        item.searchField.placeholderString = "Search in Document"
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.target = self
        item.searchField.action = #selector(searchFieldDidChange(_:))
        item.searchField.delegate = self
        searchField = item.searchField
        return item
    }

    @objc private func searchFieldDidChange(_ sender: NSSearchField) {
        // Coalesce per-keystroke finds — running the full DOM rewrite + JS
        // round-trip on every char is the dominant stall source on big docs.
        // Empty queries (e.g. user cleared the field) bypass the debounce so
        // the highlight teardown happens immediately.
        let query = sender.stringValue
        pendingFindWork?.cancel()
        if query.isEmpty {
            pendingFindWork = nil
            runFind(query: query)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.runFind(query: query)
        }
        pendingFindWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.findDebounceDelay, execute: work
        )
    }

    private func runFind(query: String, backwards: Bool = false) {
        // Explicit nav (Enter / prev / next / mode change) flushes any pending
        // debounce so the user navigates the freshest results.
        pendingFindWork?.cancel()
        pendingFindWork = nil
        (window.contentViewController as? MainSplitViewController)?
            .find(query, backwards: backwards, mode: searchMode) { [weak self] result in
                self?.applyFindResult(result, query: query)
            }
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField,
              commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        let backwards = NSEvent.modifierFlags.contains(.shift)
        findFromToolbar(backwards: backwards)
        return true
    }

    private func applyFindResult(_ result: FindResult, query: String) {
        if query.isEmpty {
            setFindBarVisible(false)
            return
        }
        findBar?.update(matchCount: result.total, currentIndex: result.index)
        setFindBarVisible(true)
    }

    private func setFindBarVisible(_ visible: Bool) {
        guard let accessory = findBarAccessory, accessory.isHidden == visible else { return }
        accessory.isHidden = !visible
    }

    private func installFindBar() {
        let bar = FindBar(
            frame: NSRect(x: 0, y: 0, width: 600, height: FindBar.preferredHeight)
        )
        bar.autoresizingMask = [.width]
        bar.onPrevious = { [weak self] in self?.findFromToolbar(backwards: true) }
        bar.onNext = { [weak self] in self?.findFromToolbar(backwards: false) }
        bar.onDone = { [weak self] in self?.dismissFindBar() }
        bar.onModeChanged = { [weak self] mode in self?.searchModeDidChange(mode) }
        self.findBar = bar
        self.findBarAccessory = addBottomTitlebarAccessory(bar) { accessory in
            if #available(macOS 26.1, *) {
                accessory.preferredScrollEdgeEffectStyle = .hard
            }
        }
    }

    private func dismissFindBar() {
        searchField?.stringValue = ""
        if let editor = searchField?.currentEditor(),
           window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        runFind(query: "")
    }

    @IBAction func performFindPanelAction(_ sender: Any?) {
        handleFindAction(sender)
    }

    @IBAction func performTextFinderAction(_ sender: Any?) {
        handleFindAction(sender)
    }

    private func handleFindAction(_ sender: Any?) {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? 1
        switch tag {
        case NSTextFinder.Action.nextMatch.rawValue:
            findFromToolbar(backwards: false)
        case NSTextFinder.Action.previousMatch.rawValue:
            findFromToolbar(backwards: true)
        default:
            focusToolbarSearch()
        }
    }

    private func findFromToolbar(backwards: Bool) {
        let query = searchField?.stringValue
            ?? NSPasteboard(name: .find).string(forType: .string)
            ?? ""
        guard !query.isEmpty else {
            focusToolbarSearch()
            return
        }
        runFind(query: query, backwards: backwards)
    }

    private func searchModeDidChange(_ mode: SearchMode) {
        guard mode != searchMode else { return }
        searchMode = mode
        guard findBarAccessory?.isHidden == false,
              let query = searchField?.stringValue, !query.isEmpty else { return }
        runFind(query: query)
    }

    private func focusToolbarSearch() {
        guard let searchField else { return }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    // MARK: - Open With

    private static let markdownFileExtensions = ["md", "markdown", "mdown", "txt"]
    private static let markdownDocTypeExtensions: Set<String> = ["md", "markdown", "mdown"]
    private static let strongMarkdownUTIs: Set<String> = ["net.daringfireball.markdown"]
    private static let plainTextUTIs: Set<String> = [
        "public.plain-text", "public.text",
        "public.utf8-plain-text", "public.utf16-plain-text"
    ]
    private static let textyUTIs: Set<String> = plainTextUTIs.union(strongMarkdownUTIs)
    private static let defaultEditorBundleIDKey = "MarkdownPreview.defaultEditorBundleID"
    private static let defaultEditorURLKey = "MarkdownPreview.defaultEditorURL"
    private static let editorBundleIDPriority = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed",
        "md.obsidian",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.barebones.bbedit",
        "com.panic.Nova",
        "com.coteditor.CotEditor",
        "com.apple.TextEdit",
        "com.apple.dt.Xcode",
        "com.macromates.TextMate",
        "org.vim.MacVim"
    ]
    private static let knownMarkdownEditorBundleIDs: Set<String> = Set(editorBundleIDPriority)

    private func makeOpenWithItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .openWith)
        item.label = "Open With"
        item.paletteLabel = "Open With"
        item.toolTip = "Open in another editor"
        item.target = self
        item.action = #selector(openWithPrimaryAction(_:))
        item.showsIndicator = true
        openWithItem = item
        refreshOpenWithItem()
        return item
    }

    private struct EditorCandidate {
        let url: URL
        let bundleID: String?
    }

    private func refreshOpenWithItem() {
        let candidates = currentFileURL.map { editorCandidates(for: $0) } ?? []
        let resolvedDefault = resolveDefaultEditor(among: candidates)
        let openInTitle = resolvedDefault.map { "Open in \(displayName(for: $0.url))" }
        openWithItem?.label = openInTitle ?? "Open With"
        openWithItem?.image = openWithImage(for: resolvedDefault?.url)
        openWithItem?.toolTip = openInTitle ?? "Open in another editor"
        openWithItem?.menu = buildOpenWithMenu(candidates: candidates,
                                               defaultEditor: resolvedDefault)
    }

    private func openWithImage(for url: URL?) -> NSImage {
        if let url {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 20, height: 20)
            return icon
        }
        return NSImage(systemSymbolName: "highlighter",
                       accessibilityDescription: "Open With") ?? NSImage()
    }

    @objc private func openWithPrimaryAction(_ sender: Any?) {
        guard let fileURL = currentFileURL else { return }
        let candidates = editorCandidates(for: fileURL)
        if let editor = resolveDefaultEditor(among: candidates) {
            launch(fileURL, with: editor.url)
        }
    }

    private func editorCandidates(for fileURL: URL) -> [EditorCandidate] {
        let myBundleID = Bundle.main.bundleIdentifier
        // Every URL Launch Services has registered for our bundle id — covers stale DerivedData /
        // archive copies the sandbox can't introspect by reading their Info.plist.
        var selfURLs: Set<URL> = [canonicalAppURL(Bundle.main.bundleURL)]
        if let myBundleID {
            for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: myBundleID) {
                selfURLs.insert(canonicalAppURL(url))
            }
        }

        var appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        for bundleID in Self.knownMarkdownEditorBundleIDs {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  !appURLs.contains(where: { sameApplication($0, appURL) }) else {
                continue
            }
            appURLs.append(appURL)
        }

        return appURLs.compactMap { appURL in
            if selfURLs.contains(canonicalAppURL(appURL)) { return nil }
            let plist = infoPlist(at: appURL)
            let bundleID = (plist?["CFBundleIdentifier"] as? String)
                ?? Bundle(url: appURL)?.bundleIdentifier
            guard canEditMarkdown(plist: plist) || knownMarkdownEditor(bundleID: bundleID) else { return nil }
            return EditorCandidate(url: appURL, bundleID: bundleID)
        }
    }

    private func knownMarkdownEditor(bundleID: String?) -> Bool {
        bundleID.map(Self.knownMarkdownEditorBundleIDs.contains) ?? false
    }

    private func resolveDefaultEditor(among candidates: [EditorCandidate]) -> EditorCandidate? {
        let myBundleID = Bundle.main.bundleIdentifier
        if let persistedID = UserDefaults.standard.string(forKey: Self.defaultEditorBundleIDKey),
           persistedID != myBundleID {
            if let match = candidates.first(where: { $0.bundleID == persistedID }) {
                return match
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: persistedID) {
                return EditorCandidate(url: url, bundleID: persistedID)
            }
        }

        if let persistedPath = UserDefaults.standard.string(forKey: Self.defaultEditorURLKey) {
            let persistedURL = canonicalAppURL(URL(fileURLWithPath: persistedPath))
            if let match = candidates.first(where: { sameApplication($0.url, persistedURL) }) {
                return match
            }
        }

        for preferred in Self.editorBundleIDPriority {
            if let match = candidates.first(where: { $0.bundleID == preferred }) {
                return match
            }
        }
        return candidates.first
    }

    private func buildOpenWithMenu(candidates: [EditorCandidate],
                                   defaultEditor: EditorCandidate?) -> NSMenu {
        let menu = NSMenu()

        guard currentFileURL != nil else {
            menu.addItem(disabledItem("No document open"))
            return menu
        }
        guard !candidates.isEmpty else {
            menu.addItem(disabledItem("No editors available"))
            return menu
        }

        let header = NSMenuItem()
        header.title = "Open with…"
        header.isEnabled = false
        menu.addItem(header)

        for candidate in candidates {
            let item = NSMenuItem(
                title: displayName(for: candidate.url),
                action: #selector(pickEditor(_:)),
                keyEquivalent: ""
            )
            let icon = NSWorkspace.shared.icon(forFile: candidate.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.target = self
            item.representedObject = candidate
            if let defaultEditor, sameEditor(candidate, defaultEditor) {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    private func displayName(for appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func sameEditor(_ lhs: EditorCandidate, _ rhs: EditorCandidate) -> Bool {
        if let leftID = lhs.bundleID, let rightID = rhs.bundleID {
            return leftID == rightID
        }
        return sameApplication(lhs.url, rhs.url)
    }

    private func sameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalAppURL(lhs) == canonicalAppURL(rhs)
    }

    private func canonicalAppURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func infoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil) as? [String: Any] else {
            return Bundle(url: appURL)?.infoDictionary
        }
        return plist
    }

    private func canEditMarkdown(plist: [String: Any]?) -> Bool {
        guard let docTypes = plist?["CFBundleDocumentTypes"] as? [[String: Any]] else {
            return true
        }

        var matchedAsEditor = false
        var matchedAsViewer = false

        for docType in docTypes {
            let utis = Set((docType["LSItemContentTypes"] as? [String]) ?? [])
            let extensions = Set(((docType["CFBundleTypeExtensions"] as? [String]) ?? [])
                .map { $0.lowercased() })
            let rank = (docType["LSHandlerRank"] as? String) ?? "Default"

            let hasMarkdownUTI = !Self.strongMarkdownUTIs.isDisjoint(with: utis)
            let hasMarkdownExtension = !Self.markdownDocTypeExtensions.isDisjoint(with: extensions)
            // A generic plain-text claim only counts as "real text editor" when the entry's UTI
            // list is purely text-flavored and isn't ranked Alternate. That filters Postico
            // (Alternate) and Numbers (bundles public.plain-text with CSV/TSV import UTIs).
            let isPureTextEntry = !utis.isEmpty && utis.isSubset(of: Self.textyUTIs)
            let isPlainTextEditor = isPureTextEntry && rank != "Alternate"

            guard hasMarkdownUTI || hasMarkdownExtension || isPlainTextEditor else { continue }

            let role = (docType["CFBundleTypeRole"] as? String) ?? "Editor"
            switch role {
            case "Viewer", "QLGenerator": matchedAsViewer = true
            default: matchedAsEditor = true
            }
        }

        if matchedAsEditor { return true }
        if matchedAsViewer { return false }
        return false
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func pickEditor(_ sender: NSMenuItem) {
        guard let candidate = sender.representedObject as? EditorCandidate,
              let fileURL = currentFileURL else { return }
        if let bundleID = candidate.bundleID {
            UserDefaults.standard.set(bundleID, forKey: Self.defaultEditorBundleIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultEditorBundleIDKey)
        }
        UserDefaults.standard.set(candidate.url.path, forKey: Self.defaultEditorURLKey)
        refreshOpenWithItem()
        launch(fileURL, with: candidate.url)
    }

    private func launch(_ fileURL: URL, with appURL: URL) {
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    private struct ContextOpenPayload {
        let fileURL: URL
        let appURL: URL
    }

    func openInNewWindow(_ fileURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.open([fileURL],
                                withApplicationAt: Bundle.main.bundleURL,
                                configuration: config) { _, _ in }
    }

    func contextMenuEditorItems(for fileURL: URL) -> [NSMenuItem] {
        let candidates = editorCandidates(for: fileURL)
        let defaultEditor = resolveDefaultEditor(among: candidates)

        var items: [NSMenuItem] = []

        let externalItem = NSMenuItem(
            title: "Open with External Editor",
            action: #selector(contextLaunchEditor(_:)),
            keyEquivalent: ""
        )
        externalItem.image = NSImage(systemSymbolName: "arrow.up.right.square",
                                     accessibilityDescription: nil)
        if let defaultEditor {
            externalItem.target = self
            externalItem.representedObject = ContextOpenPayload(fileURL: fileURL, appURL: defaultEditor.url)
            externalItem.toolTip = "Open in \(displayName(for: defaultEditor.url))"
        } else {
            externalItem.isEnabled = false
        }
        items.append(externalItem)

        let openAs = NSMenuItem(title: "Open As", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if candidates.isEmpty {
            submenu.addItem(disabledItem("No editors available"))
        } else {
            for candidate in candidates {
                let item = NSMenuItem(
                    title: displayName(for: candidate.url),
                    action: #selector(contextLaunchEditor(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ContextOpenPayload(fileURL: fileURL, appURL: candidate.url)
                let icon = NSWorkspace.shared.icon(forFile: candidate.url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                if let defaultEditor, sameEditor(candidate, defaultEditor) {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }
        openAs.submenu = submenu
        items.append(openAs)

        return items
    }

    @objc private func contextLaunchEditor(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextOpenPayload else { return }
        launch(payload.fileURL, with: payload.appURL)
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.updater.checkForUpdates()
    }

    @IBAction func openDocument(_ sender: Any?) {
        guard window.isVisible else {
            promptForFileAndPresent()
            return
        }
        let panel = makeOpenPanel()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.present(url: url)
        }
    }

    private func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a Markdown file"
        panel.allowedContentTypes = Self.markdownFileExtensions
            .compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    private func loadFile(at url: URL, silentOnFailure: Bool = false) {
        Task { @concurrent [weak self] in
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                await self?.applyLoadedMarkdown(text, fileURL: url)
            } catch {
                // Wrap as NSError (Sendable) so the original presentation —
                // localizedDescription + recovery suggestion — survives the
                // hop back to MainActor.
                let nsError = error as NSError
                await self?.applyLoadFailure(error: nsError,
                                             silentOnFailure: silentOnFailure)
            }
        }
    }

    private func applyLoadedMarkdown(_ text: String, fileURL: URL) {
        currentMarkdown = text
        renderCurrentDocument(text: text, fileURL: fileURL)
    }

    private func applyLoadFailure(error: NSError, silentOnFailure: Bool) {
        guard !silentOnFailure else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    private func renderCurrentDocument(text: String, fileURL: URL) {
        (window.contentViewController as? MainSplitViewController)?
            .display(markdown: text,
                     fileName: fileURL.lastPathComponent,
                     url: fileURL,
                     assetBaseURL: fileURL.deletingLastPathComponent())
    }

    private func addBottomTitlebarAccessory(
        _ view: NSView,
        configure: ((NSTitlebarAccessoryViewController) -> Void)? = nil
    ) -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = view
        accessory.isHidden = true
        configure?(accessory)
        window.addTitlebarAccessoryViewController(accessory)
        return accessory
    }

}

private final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    /// Fired when the watched file is renamed or moved (in Finder, by an
    /// editor, etc.). Detected via `F_GETPATH` on the still-open FD —
    /// the inode follows the file, so the descriptor resolves to the
    /// new path. Plain deletes don't fire this (path unchanged).
    var onRename: ((URL) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        open()
    }

    private func open() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let event = source.data
            // Atomic-rename saves (Vim, VS Code, etc.) replace the inode;
            // re-open the watcher against the path so we keep tracking.
            // For an actual user-visible rename, the FD's resolved path
            // differs from the watcher's URL — surface that to the host.
            if !event.intersection([.delete, .rename, .revoke]).isEmpty {
                if let newURL = self.currentPath(),
                   newURL.standardizedFileURL != self.url.standardizedFileURL {
                    self.onRename?(newURL)
                }
                self.reopen()
            }
            self.scheduleChange()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                Darwin.close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        self.source = source
        source.resume()
    }

    private func reopen() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.open()
        }
    }

    private func currentPath() -> URL? {
        guard fileDescriptor >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileDescriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return URL(fileURLWithFileSystemRepresentation: buffer,
                   isDirectory: false,
                   relativeTo: nil)
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func cancel() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }
}
