//
//  DocumentWindowController.swift
//  md-preview
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let openActions = NSToolbarItem.Identifier("OpenActions")
    static let openWith = NSToolbarItem.Identifier("OpenWith")
    static let openInLLM = NSToolbarItem.Identifier("OpenInLLM")
    static let inspector = NSToolbarItem.Identifier("Inspector")
    static let share = NSToolbarItem.Identifier("Share")
    static let search = NSToolbarItem.Identifier("Search")
    static let sidebarMenu = NSToolbarItem.Identifier("SidebarMenu")
    static let printDocument = NSToolbarItem.Identifier("PrintDocument")
    static let copyMarkdown = NSToolbarItem.Identifier("CopyMarkdown")
    static let zoom = NSToolbarItem.Identifier("Zoom")
    static let editDocument = NSToolbarItem.Identifier("EditDocument")
}

private extension Array where Element == NSToolbarItem.Identifier {
    mutating func insertAfterOpenActions(_ identifier: NSToolbarItem.Identifier) {
        guard let index = firstIndex(of: .openActions) else {
            append(identifier)
            return
        }
        insert(identifier, at: index + 1)
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    private enum DiskFileState {
        case unchanged
        case modified(String)
        case missing
        case unreadable
    }

    private enum EditedMarkdownSaveResult {
        case saved
        case reloaded(String)
        case cancelled
    }

    private enum UnsavedEditResolution {
        case save
        case discard
        case cancel
    }

    private var currentFileURL: URL?
    private var currentMarkdown: String?
    private var fileWatcher: FileWatcher?
    private var isInspectorToggleSelected = false
    private weak var openActionsItem: NSMenuToolbarItem?
    private weak var openWithItem: NSMenuToolbarItem?
    private weak var openInLLMItem: NSMenuToolbarItem?
    private weak var inspectorItem: NSToolbarItem?
    private weak var inspectorButton: NSButton?
    private weak var editItem: NSToolbarItem?
    private weak var editButton: NSButton?
    private var editorChangeRevision = 0
    /// In-memory source shown by preview before the user saves it.
    private var editorDraftMarkdown: String?
    /// Last known on-disk source, retained while preview displays a draft.
    private var editorBaselineMarkdown: String?
    private var isEditorCommitInFlight = false
    private var pendingCommitShouldExit = false
    private var pendingCommitCompletions: [(Bool) -> Void] = []
    /// When sidebar navigation starts from edit mode, the newly loaded file
    /// should return to edit mode instead of dropping the user into preview.
    private var pendingEditModeURL: URL?
    /// Drives the native titlebar subtitle while the editor contains changes
    /// that have not yet been written successfully.
    private var hasUnsavedEditorChanges = false {
        didSet {
            guard oldValue != hasUnsavedEditorChanges else { return }
            documentWindow.subtitle = hasUnsavedEditorChanges ? "Edited" : ""
        }
    }
    private weak var editAccessory: NSTitlebarAccessoryViewController?
    private weak var copyItem: NSToolbarItem?
    private var copyFeedbackWork: DispatchWorkItem?
    private weak var searchField: NSSearchField?
    private weak var sidebarMenu: NSMenu?
    private weak var sidebarPopUpButton: NSPopUpButton?
    private var findBar: FindBar?
    private var findBarAccessory: NSTitlebarAccessoryViewController?
    private var searchMode: SearchMode = .contains
    private var pendingFindWork: DispatchWorkItem?
    private static let findDebounceDelay: TimeInterval = 0.10

    private var documentWindow: NSWindow {
        guard let window else {
            fatalError("DocumentWindowController accessed before its window was loaded")
        }
        return window
    }

    private var markdownDocument: MarkdownDocument? {
        document as? MarkdownDocument
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markdown Preview"
        window.animationBehavior = .default
        window.allowsToolTipsWhenApplicationIsInactive = false
        super.init(window: window)
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One-shot override consumed by the next window's setup: "Open in
    /// New Window" needs that window to skip the native tab group during
    /// its first order-front (when AppKit decides tab placement).
    private static var nextWindowDeclinesTabbing = false
    /// One-shot for explicit tab requests (Open in New Tab, ⌘T, the tab
    /// bar's "+"): the next window joins the frontmost window's tab group
    /// even when the system tabbing preference wouldn't put it there.
    private static var nextWindowRequestsTab = false

    static func markNextWindowAsSeparate() {
        nextWindowDeclinesTabbing = true
    }

    static func markNextWindowAsTab() {
        nextWindowRequestsTab = true
    }

    /// Whether this window was created by an explicit tab request; consumed
    /// by attachToExistingTabGroupIfNeeded on first show.
    private var joinsTabGroupOnFirstShow = false

    private func setupWindow() {
        documentWindow.styleMask.insert(.fullSizeContentView)
        documentWindow.delegate = self
        documentWindow.tabbingIdentifier = "MarkdownDocumentWindow"
        documentWindow.tabbingMode = Self.nextWindowDeclinesTabbing ? .disallowed : .automatic
        joinsTabGroupOnFirstShow = Self.nextWindowRequestsTab && !Self.nextWindowDeclinesTabbing
        Self.nextWindowDeclinesTabbing = false
        Self.nextWindowRequestsTab = false
        let split = MainSplitViewController()
        split.onSelectFile = { [weak self] url in
            self?.present(url: url)
        }
        split.onToggleTaskCheckbox = { [weak self] line, checked in
            self?.toggleTaskCheckbox(onLine: line, checked: checked)
        }
        documentWindow.contentViewController = split
        documentWindow.setContentSize(NSSize(width: 1100, height: 720))
        documentWindow.center()
        documentWindow.setFrameAutosaveName("MainWindow")

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        documentWindow.toolbar = toolbar
        documentWindow.toolbarStyle = .automatic

        installFindBar()
    }

    /// AppKit's automatic tab placement runs when NSDocument shows its
    /// windows — but this controller orders the window front itself (from
    /// makeWindowControllers, before showWindows), so the window is already
    /// visible and placement never happens on its own. Join the frontmost
    /// document window's tab group explicitly on first show instead — but
    /// only when the open was an explicit tab request, or the system
    /// "Prefer tabs when opening documents" setting asks for it. Plain
    /// opens (Finder, ⌘O, recents) otherwise get their own window.
    private func attachToExistingTabGroupIfNeeded() {
        guard !documentWindow.isVisible,
              documentWindow.tabbingMode != .disallowed,
              let host = ([NSApp.mainWindow] + NSApp.orderedWindows)
                  .compactMap({ $0 })
                  .first(where: {
                      $0 !== documentWindow
                          && $0.isVisible
                          && $0.tabbingIdentifier == documentWindow.tabbingIdentifier
                  }) else { return }

        let joins: Bool
        if joinsTabGroupOnFirstShow {
            joins = true
        } else {
            switch NSWindow.userTabbingPreference {
            case .always: joins = true
            case .inFullScreen: joins = host.styleMask.contains(.fullScreen)
            case .manual: joins = false
            @unknown default: joins = false
            }
        }
        guard joins else { return }
        host.addTabbedWindow(documentWindow, ordered: .above)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasPendingEditorChanges else { return true }
        requestEndEditing { [weak self] success in
            guard success else { return }
            // close() skips windowShouldClose, so no re-entry loop.
            self?.documentWindow.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    func display(markdown: String, fileURL: URL?) {
        currentFileURL = fileURL
        currentMarkdown = markdown
        documentWindow.title = fileURL?.lastPathComponent ?? "Untitled"
        attachToExistingTabGroupIfNeeded()
        documentWindow.makeKeyAndOrderFront(nil)
        // Tab placement is settled once the window is shown; a window opened
        // via "Open in New Window" goes back to normal tabbing afterwards
        // (it can host or join tabs on explicit request, but plain opens no
        // longer recapture it).
        documentWindow.tabbingMode = .automatic
        NSApp.activate()
        refreshOpenWithItem()
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
        updateEditToolbarItem()
        if let fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
            renderCurrentDocument(text: markdown, fileURL: fileURL)
            startWatching(fileURL)
            offerToBecomeDefaultHandlerIfNeeded()
        }
    }

    private func present(url: URL) {
        let preserveEditMode = isEditing || pendingEditModeURL != nil
        if isEditing || hasPendingEditorChanges {
            requestEndEditing(keepAccessoryMounted: true) { [weak self] success in
                guard success else { return }
                self?.present(url: url, preservingEditMode: preserveEditMode)
            }
            return
        }
        present(url: url, preservingEditMode: preserveEditMode)
    }

    private func present(url: URL, preservingEditMode: Bool) {
        if url.isExistingDirectory {
            pendingEditModeURL = nil
            openFolder(url)
            return
        }

        // Switching to a different file blanks the preview so the previous
        // doc doesn't linger on screen during sheet dismissal + load.
        let isFileSwitch = currentFileURL != nil && currentFileURL != url
        currentFileURL = url
        currentMarkdown = nil
        pendingEditModeURL = preservingEditMode ? url.standardizedFileURL : nil
        markdownDocument?.replaceFileURL(url)
        documentWindow.title = url.lastPathComponent
        if isFileSwitch {
            (documentWindow.contentViewController as? MainSplitViewController)?.clearContent()
        }
        documentWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshOpenWithItem()
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
        updateEditToolbarItem()
        loadFile(at: url)
        startWatching(url)
        offerToBecomeDefaultHandlerIfNeeded()
    }

    private func startWatching(_ url: URL) {
        fileWatcher?.cancel()
        let watcher = FileWatcher(url: url) { [weak self] in
            // While editing, disk changes (including our own ⌘S writes)
            // must not re-render or clobber the in-progress session. Every
            // commit revalidates the disk contents before writing, so an
            // external edit is either reloaded or resolved explicitly.
            guard let self, self.currentFileURL == url,
                  !self.isEditing, !self.hasPendingEditorChanges else { return }
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
        markdownDocument?.replaceFileURL(newURL)
        documentWindow.title = newURL.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(newURL)
        refreshOpenWithItem()
        refreshOpenActionsItem()
        startWatching(newURL)
        if let markdown = currentMarkdown {
            (documentWindow.contentViewController as? MainSplitViewController)?
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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .sidebarMenu,
            .sidebarTrackingSeparator,
            .openActions,
            .space,
            .zoom,
            .inspector,
            .share,
            .editDocument,
            .search
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .sidebarMenu,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .space,
            .openActions,
            .openWith,
            .editDocument,
            .inspector,
            .share,
            .search,
            .printDocument,
            .copyMarkdown,
            .zoom
        ]
        if hasLLMTargetsAvailable {
            identifiers.insertAfterOpenActions(.openInLLM)
        }
        return identifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarMenu: return makeSidebarMenuItem(willBeInsertedIntoToolbar: flag)
        case .openActions: return makeOpenActionsItem()
        case .openWith: return makeOpenWithItem()
        case .openInLLM:
            guard hasLLMTargetsAvailable else { return nil }
            return makeOpenInLLMItem()
        case .editDocument: return makeEditItem()
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
        if let sidebarMenu {
            syncSidebarMenuState(for: sidebarMenu)
        }
    }

    private func syncSidebarMenuState(for menu: NSMenu) {
        let state = currentSidebarMenuState()
        menu.items.first { $0.action == #selector(hideSidebarFromMenu(_:)) }?.state = state.sidebarVisible ? .off : .on
        menu.items.first { $0.action == #selector(selectOutlineMode(_:)) }?.state = (state.sidebarVisible && state.mode == .outline) ? .on : .off
        menu.items.first { $0.action == #selector(selectFilesMode(_:)) }?.state = (state.sidebarVisible && state.mode == .files) ? .on : .off
    }

    var sidebarMenuState: (sidebarVisible: Bool, mode: SidebarViewController.Mode) {
        currentSidebarMenuState()
    }

    func reloadPreviewForSettingChange() {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .reloadPreviewForSettingChange()
    }

    private func currentSidebarMenuState() -> (sidebarVisible: Bool, mode: SidebarViewController.Mode) {
        let split = documentWindow.contentViewController as? MainSplitViewController
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

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        (documentWindow.contentViewController as? MainSplitViewController)?.toggleSidebar()
        syncSidebarMenuState()
    }

    @objc func hideSidebarFromMenu(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController,
              split.isSidebarVisible else { return }
        split.toggleSidebar()
        syncSidebarMenuState()
    }

    @objc func selectOutlineMode(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.outline)
        split.showSidebar()
        syncSidebarMenuState()
    }

    @objc func selectFilesMode(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.files)
        split.showSidebar()
        syncSidebarMenuState()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(saveDocument(_:)) {
            return isEditing
        }
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

    // MARK: - Edit mode

    private var mainSplit: MainSplitViewController? {
        documentWindow.contentViewController as? MainSplitViewController
    }

    private var isEditing: Bool {
        mainSplit?.isEditingDocument ?? false
    }

    var canToggleEditMode: Bool {
        isEditing || (currentFileURL != nil && currentMarkdown != nil)
    }

    var canFormatMarkdown: Bool { isEditing }

    func formatMarkdown(_ command: String) {
        guard isEditing else { return }
        mainSplit?.editorViewController?.exec(command)
    }

    var hasPendingEditorChanges: Bool {
        hasUnsavedEditorChanges || isEditorCommitInFlight
    }

    func commitPendingEditsForTermination(completion: @escaping (Bool) -> Void) {
        guard isEditing || hasPendingEditorChanges else {
            completion(true)
            return
        }
        requestEndEditing(completion: completion)
    }

    private func makeEditItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .editDocument)
        item.label = "Edit"
        item.paletteLabel = "Edit"
        item.toolTip = "Edit document"

        let image = NSImage(systemSymbolName: "highlighter",
                            accessibilityDescription: "Edit") ?? NSImage()
        image.isTemplate = true
        let button = NSButton(image: image,
                              target: self,
                              action: #selector(toggleEditAction(_:)))
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
        editButton = button
        editItem = item
        updateEditToolbarItem()
        return item
    }

    private func updateEditToolbarItem() {
        let editing = isEditing
        editButton?.state = editing ? .on : .off
        editItem?.toolTip = editing
            ? "Stop editing and return to preview"
            : "Edit document"
        editButton?.toolTip = editItem?.toolTip
        editButton?.isEnabled = editing || (currentFileURL != nil && currentMarkdown != nil)
    }

    @objc private func toggleEditAction(_ sender: Any?) {
        toggleEditMode()
    }

    func toggleEditMode() {
        if isEditing {
            previewPendingEdits()
        } else {
            enterEditMode()
        }
    }

    // MARK: Formatting bar

    /// Second toolbar row with common markdown actions, shown while
    /// editing — like Preview's markup bar.
    private func showEditAccessory() {
        guard editAccessory == nil else { return }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        func formatButton(_ symbol: String, _ command: String, _ tip: String) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(symbolConfig) ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(formatCommand(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(command)
            // Preview-style: small bare icons, bezel only under the pointer.
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.showsBorderOnlyWhileMouseInside = true
            button.toolTip = tip
            // The accessory-bar bezel pads the icon generously; a fixed
            // width tightens the leading/trailing space around the glyph.
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return button
        }

        // Plain button with a composed icon+chevron face: unlike a pull-down,
        // the chevron stays visible when the hover-only bezel is hidden.
        let headingIcon = NSImage(systemSymbolName: "textformat.size",
                                  accessibilityDescription: "Heading")?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()
        let headingChevron = NSImage(systemSymbolName: "chevron.down",
                                     accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)) ?? NSImage()
        let gap: CGFloat = 4
        let faceSize = NSSize(width: headingIcon.size.width + gap + headingChevron.size.width,
                              height: max(headingIcon.size.height, headingChevron.size.height))
        let headingFace = NSImage(size: faceSize, flipped: false) { _ in
            headingIcon.draw(at: NSPoint(x: 0, y: (faceSize.height - headingIcon.size.height) / 2),
                             from: .zero, operation: .sourceOver, fraction: 1)
            headingChevron.draw(at: NSPoint(x: headingIcon.size.width + gap,
                                            y: (faceSize.height - headingChevron.size.height) / 2),
                                from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        headingFace.isTemplate = true
        let headings = NSButton(image: headingFace, target: self,
                                action: #selector(showHeadingMenu(_:)))
        headings.bezelStyle = .accessoryBarAction
        headings.controlSize = .small
        headings.showsBorderOnlyWhileMouseInside = true
        headings.toolTip = "Heading"
        headings.translatesAutoresizingMaskIntoConstraints = false
        headings.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let views: [NSView] = [
            headings,
            separatorView(),
            formatButton("bold", "bold", "Bold"),
            formatButton("italic", "italic", "Italic"),
            formatButton("strikethrough", "strikethrough", "Strikethrough"),
            separatorView(),
            formatButton("list.bullet", "bulletList", "Bulleted List"),
            formatButton("list.number", "orderedList", "Numbered List"),
            formatButton("checklist", "taskList", "Task List"),
            formatButton("text.quote", "quote", "Block Quote"),
            separatorView(),
            formatButton("chevron.left.forwardslash.chevron.right", "code", "Inline Code"),
            formatButton("link", "link", "Link"),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        // Buttons stay tight (2px); the group dividers get room to breathe.
        for (index, view) in views.enumerated() where view is NSBox {
            if index > 0 { stack.setCustomSpacing(8, after: views[index - 1]) }
            stack.setCustomSpacing(8, after: view)
        }
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .bottom
        accessory.fullScreenMinHeight = 34
        // macOS 26 replaced the titlebar separator with scroll edge
        // effects; hard = the classic line under the bar.
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = .hard
        }
        documentWindow.addTitlebarAccessoryViewController(accessory)
        editAccessory = accessory
    }

    private func separatorView() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    private func hideEditAccessory() {
        guard let accessory = editAccessory else { return }
        accessory.removeFromParent()
        editAccessory = nil
    }

    @objc private func formatCommand(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        formatMarkdown(command)
    }

    @objc private func showHeadingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let normalText = NSMenuItem(title: "Normal Text",
                                    action: #selector(headingCommand(_:)),
                                    keyEquivalent: "")
        normalText.target = self
        normalText.tag = 0
        menu.addItem(normalText)
        menu.addItem(.separator())
        for level in 1...3 {
            let item = NSMenuItem(title: "Heading \(level)",
                                  action: #selector(headingCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = level
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                   in: sender)
    }

    @objc private func headingCommand(_ sender: NSMenuItem) {
        formatMarkdown("h\(sender.tag)")
    }

    /// File > Save (⌘S) while editing: write without leaving edit mode.
    /// Intercepts the responder chain ahead of MarkdownDocument, whose
    /// NSDocument save machinery stays disabled.
    @IBAction func saveDocument(_ sender: Any?) {
        guard isEditing || hasPendingEditorChanges else {
            NSSound.beep()
            return
        }
        commitEdits(exitAfter: false)
    }

    private func enterEditMode() {
        guard let split = mainSplit, !split.isEditingDocument,
              currentFileURL != nil,
              let markdown = editorDraftMarkdown ?? currentMarkdown else {
            NSSound.beep()
            return
        }

        // Edit the complete source. Frontmatter is stripped only by the
        // read-only renderer; the editor must expose and preserve it.
        let editor = split.enterEditMode(markdown: markdown)
        editor.cancelRequested = { [weak self] in
            self?.previewPendingEdits()
        }
        editor.contentDidChange = { [weak self] in
            self?.editorChangeRevision += 1
            self?.hasUnsavedEditorChanges = true
        }
        if editorBaselineMarkdown == nil {
            editorBaselineMarkdown = currentMarkdown
            editorChangeRevision = 0
            hasUnsavedEditorChanges = false
        }
        showEditAccessory()
        updateEditToolbarItem()
    }

    /// Switches to preview without resolving the editing session. The preview
    /// renders the in-memory source, while the disk baseline is kept for a
    /// later Save or close decision.
    private func previewPendingEdits() {
        guard let split = mainSplit, let editor = split.editorViewController else { return }
        editor.fetchMarkdown { [weak self] markdown in
            guard let self, let markdown, let url = self.currentFileURL else {
                NSSound.beep()
                return
            }
            self.editorDraftMarkdown = markdown
            self.currentMarkdown = markdown
            self.hasUnsavedEditorChanges = markdown != self.editorBaselineMarkdown
            if !self.hasUnsavedEditorChanges {
                self.editorDraftMarkdown = nil
                self.editorBaselineMarkdown = nil
            }
            self.markdownDocument?.replaceContents(markdown: markdown, fileURL: url)
            self.renderCurrentDocument(text: markdown, fileURL: url)
            self.hideEditAccessory()
            self.exitEditMode(rerender: true, preserveUnsavedChanges: true) {}
        }
    }

    private func requestEndEditing(
        keepAccessoryMounted: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        let finish: (Bool) -> Void = { [weak self] success in
            if success, !keepAccessoryMounted {
                self?.hideEditAccessory()
                self?.updateEditToolbarItem()
            }
            completion?(success)
        }
        resolveUnsavedEdits { [weak self] resolution in
            guard let self else {
                finish(false)
                return
            }
            switch resolution {
            case .save:
                self.commitEdits(exitAfter: true, completion: finish)
            case .discard:
                self.exitEditModeWithoutSaving {
                    finish(true)
                }
            case .cancel:
                finish(false)
            }
        }
    }

    private func resolveUnsavedEdits(
        completion: @escaping (UnsavedEditResolution) -> Void
    ) {
        guard hasUnsavedEditorChanges || isEditorCommitInFlight else {
            completion(.discard)
            return
        }

        // If an explicit ⌘S is already running, let that request finish
        // instead of presenting a second decision on top of it.
        if isEditorCommitInFlight {
            commitEdits(exitAfter: false) { success in
                completion(success ? .discard : .cancel)
            }
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save your changes?"
        let fileName = currentFileURL?.lastPathComponent ?? "this document"
        alert.informativeText = "Your changes to \(fileName) will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: documentWindow) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.save)
            case .alertThirdButtonReturn:
                completion(.discard)
            default:
                completion(.cancel)
            }
        }
    }

    private func exitEditModeWithoutSaving(completion: @escaping () -> Void) {
        var shouldRerender = false
        if let baseline = editorBaselineMarkdown {
            currentMarkdown = baseline
            if let url = currentFileURL {
                markdownDocument?.replaceContents(markdown: baseline, fileURL: url)
            }
            shouldRerender = true
        }
        if case let .modified(externalMarkdown) = diskFileState(
            for: currentFileURL,
            expectedMarkdown: editorBaselineMarkdown ?? currentMarkdown
        ) {
            currentMarkdown = externalMarkdown
            if let url = currentFileURL {
                markdownDocument?.replaceContents(markdown: externalMarkdown, fileURL: url)
            }
            shouldRerender = true
        }
        editorDraftMarkdown = nil
        editorBaselineMarkdown = nil
        hasUnsavedEditorChanges = false
        exitEditMode(rerender: shouldRerender, completion: completion)
    }

    /// Serializes the editor, writes the file if the content changed, and
    /// optionally returns to the preview. Stays in edit mode when the save
    /// fails so no edits are lost. `completion(false)` means the commit
    /// did not go through.
    private func commitEdits(exitAfter: Bool, completion: ((Bool) -> Void)? = nil) {
        pendingCommitShouldExit = pendingCommitShouldExit || exitAfter
        if let completion {
            pendingCommitCompletions.append(completion)
        }
        guard !isEditorCommitInFlight else { return }
        performPendingEditorCommit()
    }

    private func performPendingEditorCommit() {
        let exitAfter = pendingCommitShouldExit
        pendingCommitShouldExit = false
        guard let split = mainSplit else {
            finishEditorCommit(success: false)
            return
        }
        if !isEditing, let body = editorDraftMarkdown {
            performPendingEditorCommit(body: body, editor: nil, exitAfter: exitAfter)
            return
        }
        guard let editor = split.editorViewController else {
            finishEditorCommit(success: true)
            return
        }
        let revision = editorChangeRevision
        isEditorCommitInFlight = true
        editor.fetchMarkdown { [weak self] body in
            guard let self else {
                return
            }
            guard let body else {
                NSSound.beep()
                self.finishEditorCommit(success: false)
                return
            }
            self.performPendingEditorCommit(body: body, editor: editor,
                                            revision: revision, exitAfter: exitAfter)
        }
    }

    private func performPendingEditorCommit(body: String,
                                            editor: EditorViewController?,
                                            revision: Int? = nil,
                                            exitAfter: Bool) {
        isEditorCommitInFlight = true
        let baseline = editorBaselineMarkdown ?? currentMarkdown
        let diskState = diskFileState(for: currentFileURL,
                                      expectedMarkdown: baseline)
        let hasLocalChanges = body != baseline

        if !hasLocalChanges, case let .modified(externalMarkdown) = diskState {
            // Nothing local needs preserving, so adopt the newer disk
            // version without presenting a needless conflict dialog.
            adoptExternalMarkdown(externalMarkdown,
                                  editor: editor,
                                  exitAfter: exitAfter)
            return
        }

        guard hasUnsavedEditorChanges, hasLocalChanges else {
            if revision == nil || revision == editorChangeRevision {
                hasUnsavedEditorChanges = false
            }
            switch diskState {
            case .unchanged:
                completeSuccessfulEditorCommit(exitAfter: exitAfter,
                                               rerender: false)
            case .modified:
                // Handled above.
                break
            case .missing, .unreadable:
                saveEditedMarkdown(body, diskState: diskState) { result in
                    self.handleEditedMarkdownSaveResult(result,
                                                        body: body,
                                                        editor: editor,
                                                        revision: revision,
                                                        exitAfter: exitAfter)
                }
            }
            return
        }
        saveEditedMarkdown(body, diskState: diskState) { result in
            self.handleEditedMarkdownSaveResult(result,
                                                body: body,
                                                editor: editor,
                                                revision: revision,
                                                exitAfter: exitAfter)
        }
    }

    private func handleEditedMarkdownSaveResult(_ result: EditedMarkdownSaveResult,
                                                body: String,
                                                editor: EditorViewController?,
                                                revision: Int?,
                                                exitAfter: Bool) {
        switch result {
        case .saved:
            currentMarkdown = body
            if let url = currentFileURL {
                markdownDocument?.replaceContents(markdown: body, fileURL: url)
            }
            editorDraftMarkdown = nil
            editorBaselineMarkdown = isEditing && !exitAfter ? body : nil
            if revision == nil || revision == editorChangeRevision {
                hasUnsavedEditorChanges = false
            }
            completeSuccessfulEditorCommit(exitAfter: exitAfter, rerender: true)
        case let .reloaded(externalMarkdown):
            adoptExternalMarkdown(externalMarkdown,
                                  editor: editor,
                                  exitAfter: exitAfter)
        case .cancelled:
            finishEditorCommit(success: false)
        }
    }

    private func adoptExternalMarkdown(_ markdown: String,
                                       editor: EditorViewController?,
                                       exitAfter: Bool) {
        currentMarkdown = markdown
        editorDraftMarkdown = nil
        editorBaselineMarkdown = isEditing && !exitAfter ? markdown : nil
        editorChangeRevision = 0
        hasUnsavedEditorChanges = false
        if let url = currentFileURL {
            markdownDocument?.replaceContents(markdown: markdown, fileURL: url)
            if !exitAfter {
                renderCurrentDocument(text: markdown, fileURL: url)
            }
        }
        if !exitAfter {
            editor?.load(markdown: markdown)
        }
        completeSuccessfulEditorCommit(exitAfter: exitAfter, rerender: true)
    }

    private func completeSuccessfulEditorCommit(exitAfter: Bool, rerender: Bool) {
        if hasUnsavedEditorChanges {
            if exitAfter {
                pendingCommitShouldExit = true
            }
            finishEditorCommit(success: true)
            return
        }
        guard exitAfter else {
            finishEditorCommit(success: true)
            return
        }
        exitEditMode(rerender: rerender) { [weak self] in
            self?.finishEditorCommit(success: true)
        }
    }

    private func finishEditorCommit(success: Bool) {
        isEditorCommitInFlight = false
        if success, hasUnsavedEditorChanges || pendingCommitShouldExit {
            performPendingEditorCommit()
            return
        }

        pendingCommitShouldExit = false
        let completions = pendingCommitCompletions
        pendingCommitCompletions.removeAll()
        for completion in completions {
            completion(success)
        }
    }

    private func exitEditMode(rerender: Bool,
                              preserveUnsavedChanges: Bool = false,
                              completion: @escaping () -> Void) {
        guard let split = mainSplit else {
            completion()
            return
        }
        split.editorViewController?.contentDidChange = nil
        split.editorViewController?.cancelRequested = nil
        documentWindow.makeFirstResponder(nil)
        split.exitEditMode(waitForPreviewRender: rerender) { [weak self] in
            guard let self else {
                completion()
                return
            }
            if !preserveUnsavedChanges {
                self.hasUnsavedEditorChanges = false
            }
            if self.editAccessory == nil {
                self.updateEditToolbarItem()
            }
            if rerender, let url = self.currentFileURL, let markdown = self.currentMarkdown {
                self.renderCurrentDocument(text: markdown, fileURL: url)
            }
            completion()
        }
    }

    private func diskFileState(for url: URL?, expectedMarkdown: String?) -> DiskFileState {
        guard let url, let expectedMarkdown else { return .unreadable }
        do {
            let diskMarkdown = try String(contentsOf: url, encoding: .utf8)
            return diskMarkdown == expectedMarkdown ? .unchanged : .modified(diskMarkdown)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
    }

    private func saveEditedMarkdown(_ text: String,
                                    diskState: DiskFileState,
                                    completion: @escaping (EditedMarkdownSaveResult) -> Void) {
        guard let url = currentFileURL else {
            completion(.cancelled)
            return
        }
        switch diskState {
        case .unchanged:
            persistEditedMarkdown(text, to: url, completion: completion)
        case let .modified(externalMarkdown):
            presentExternalEditConflict(localMarkdown: text,
                                        externalMarkdown: externalMarkdown,
                                        fileURL: url,
                                        completion: completion)
        case .missing:
            presentUnavailableFileConflict(localMarkdown: text,
                                           fileURL: url,
                                           reason: "The file was removed while it was open.",
                                           overwriteTitle: "Recreate File",
                                           completion: completion)
        case .unreadable:
            presentUnavailableFileConflict(localMarkdown: text,
                                           fileURL: url,
                                           reason: "The file could not be read to verify that it is unchanged.",
                                           overwriteTitle: "Save Anyway",
                                           completion: completion)
        }
    }

    private func toggleTaskCheckbox(onLine sourceLine: Int, checked: Bool) {
        guard !isEditing,
              let baseline = currentMarkdown,
              let updated = TaskCheckboxSource.settingChecked(
                checked, onLine: sourceLine, in: baseline
              ),
              updated != baseline else {
            rerenderCurrentPreview()
            return
        }

        let diskState = diskFileState(for: currentFileURL, expectedMarkdown: baseline)
        saveEditedMarkdown(updated, diskState: diskState) { [weak self] result in
            guard let self else { return }
            switch result {
            case .saved:
                self.currentMarkdown = updated
                if let url = self.currentFileURL {
                    self.markdownDocument?.replaceContents(markdown: updated, fileURL: url)
                    self.renderCurrentDocument(text: updated, fileURL: url)
                }
            case let .reloaded(externalMarkdown):
                self.currentMarkdown = externalMarkdown
                if let url = self.currentFileURL {
                    self.markdownDocument?.replaceContents(markdown: externalMarkdown, fileURL: url)
                    self.renderCurrentDocument(text: externalMarkdown, fileURL: url)
                }
            case .cancelled:
                self.rerenderCurrentPreview()
            }
        }
    }

    private func rerenderCurrentPreview() {
        guard let url = currentFileURL, let markdown = currentMarkdown else { return }
        renderCurrentDocument(text: markdown, fileURL: url)
    }

    private func presentExternalEditConflict(
        localMarkdown: String,
        externalMarkdown: String,
        fileURL: URL,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This document changed on disk"
        alert.informativeText = "Another app changed \(fileURL.lastPathComponent). Cancel keeps your changes unsaved. Choose which version to keep."
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self else {
                completion(.cancelled)
                return
            }
            switch response {
            case .alertFirstButtonReturn:
                self.persistEditedMarkdown(localMarkdown, to: fileURL, completion: completion)
            case .alertSecondButtonReturn:
                // The sheet may remain open while another editor writes
                // again. Reload the latest bytes instead of the snapshot
                // captured when the conflict was first detected.
                if let latestMarkdown = try? String(contentsOf: fileURL, encoding: .utf8) {
                    completion(.reloaded(latestMarkdown))
                } else {
                    completion(.reloaded(externalMarkdown))
                }
            default:
                completion(.cancelled)
            }
        }
    }

    private func presentUnavailableFileConflict(
        localMarkdown: String,
        fileURL: URL,
        reason: String,
        overwriteTitle: String,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to verify the document on disk"
        alert.informativeText = "\(reason) Cancel keeps your changes unsaved."
        alert.addButton(withTitle: overwriteTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                completion(.cancelled)
                return
            }
            self.persistEditedMarkdown(localMarkdown, to: fileURL, completion: completion)
        }
    }

    private func persistEditedMarkdown(
        _ text: String,
        to url: URL,
        completion: @escaping (EditedMarkdownSaveResult) -> Void
    ) {
        if write(text, to: url) {
            completion(.saved)
            return
        }
        // Sandbox denied the write — the file came in through the read-only
        // filesystem exception (folder navigator) rather than a user-selected
        // grant. A save panel pointed at the same file converts the user's
        // confirmation into a read-write grant.
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.message = "Markdown Preview needs your permission to save this file."
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let chosen = panel.url else {
                completion(.cancelled)
                return
            }
            let ok = self.write(text, to: chosen)
            if ok, chosen.standardizedFileURL != url.standardizedFileURL {
                // Saved under a different name — follow the new file.
                self.handleRename(to: chosen)
            }
            completion(ok ? .saved : .cancelled)
        }
    }

    private func write(_ text: String, to url: URL) -> Bool {
        // Atomic first (safe against partial writes); a file-scoped sandbox
        // grant can deny the temp-file rename, so fall back to in-place.
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            do {
                try text.write(to: url, atomically: false, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Open

    private static let defaultOpenActionKindKey = "MarkdownPreview.defaultOpenActionKind"

    private enum OpenActionKind: String {
        case editor
        case llm
    }

    private enum OpenActionSelection {
        case editor(EditorCandidate)
        case llm(LLMCandidate)
    }

    private func makeOpenActionsItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .openActions)
        item.label = "Open"
        item.paletteLabel = "Open"
        item.toolTip = "Open document in another app"
        item.target = self
        item.action = #selector(openActionsPrimaryAction(_:))
        item.showsIndicator = true
        openActionsItem = item
        refreshOpenActionsItem()
        return item
    }

    private func refreshOpenActionsItem() {
        let editors = currentFileURL.map { editorCandidates(for: $0) } ?? []
        let defaultEditor = resolveDefaultEditor(among: editors)
        let llmApps = llmCandidates()
        let defaultLLM = resolveDefaultLLM(among: llmApps)
        let defaultAction = resolveDefaultOpenAction(editors: editors,
                                                     defaultEditor: defaultEditor,
                                                     llmApps: llmApps,
                                                     defaultLLM: defaultLLM)

        let primaryTitle = openActionsTitle(for: defaultAction)

        openActionsItem?.label = "Open"
        openActionsItem?.image = openActionsImage(for: defaultAction)
        openActionsItem?.toolTip = primaryTitle ?? "Open document in another app"
        openActionsItem?.menu = buildOpenActionsMenu(editorCandidates: editors,
                                                     llmCandidates: llmApps,
                                                     defaultAction: defaultAction)
    }

    private func openActionsTitle(for selection: OpenActionSelection?) -> String? {
        switch selection {
        case .editor(let editor):
            return "Open in \(displayName(for: editor.url))"
        case .llm(let candidate):
            return "Open in \(candidate.target.title)"
        case nil:
            return nil
        }
    }

    private func openActionsImage(for selection: OpenActionSelection?) -> NSImage {
        switch selection {
        case .editor(let editor):
            let editorURL = editor.url
            return openWithImage(for: editorURL)
        case .llm(let candidate):
            return openInLLMImage(for: candidate)
        case nil:
            return openWithImage(for: nil)
        }
    }

    private func resolveDefaultOpenAction(editors: [EditorCandidate],
                                          defaultEditor: EditorCandidate?,
                                          llmApps: [LLMCandidate],
                                          defaultLLM: LLMCandidate?) -> OpenActionSelection? {
        let persistedKind = UserDefaults.standard.string(forKey: Self.defaultOpenActionKindKey)
            .flatMap(OpenActionKind.init(rawValue:))

        switch persistedKind {
        case .llm:
            if let defaultLLM {
                return .llm(defaultLLM)
            }
            if let defaultEditor {
                return .editor(defaultEditor)
            }
        case .editor, nil:
            if let defaultEditor {
                return .editor(defaultEditor)
            }
            if let defaultLLM {
                return .llm(defaultLLM)
            }
        }
        return nil
    }

    private func buildOpenActionsMenu(editorCandidates: [EditorCandidate],
                                      llmCandidates: [LLMCandidate],
                                      defaultAction: OpenActionSelection?) -> NSMenu {
        let menu = NSMenu()

        guard currentFileURL != nil else {
            menu.addItem(disabledItem("No document open"))
            return menu
        }

        if editorCandidates.isEmpty && llmCandidates.isEmpty {
            menu.addItem(disabledItem("No apps available"))
            return menu
        }

        if !editorCandidates.isEmpty {
            let header = NSMenuItem()
            header.title = "Editors"
            header.isEnabled = false
            menu.addItem(header)

            for candidate in editorCandidates {
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
                if case .editor(let selectedEditor) = defaultAction,
                   sameEditor(candidate, selectedEditor) {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        if !llmCandidates.isEmpty {
            if !editorCandidates.isEmpty {
                menu.addItem(.separator())
            }

            let header = NSMenuItem()
            header.title = "AI Apps"
            header.isEnabled = false
            menu.addItem(header)

            for candidate in llmCandidates {
                let item = NSMenuItem(
                    title: candidate.target.title,
                    action: #selector(pickLLMTarget(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = candidate.target.id
                let icon = NSWorkspace.shared.icon(forFile: candidate.appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                if case .llm(let selectedLLM) = defaultAction,
                   candidate.target.id == selectedLLM.target.id {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        return menu
    }

    @objc private func openActionsPrimaryAction(_ sender: Any?) {
        guard let fileURL = currentFileURL else { return }
        let editors = editorCandidates(for: fileURL)
        let defaultEditor = resolveDefaultEditor(among: editors)
        let llmApps = llmCandidates()
        let defaultLLM = resolveDefaultLLM(among: llmApps)
        guard let defaultAction = resolveDefaultOpenAction(editors: editors,
                                                           defaultEditor: defaultEditor,
                                                           llmApps: llmApps,
                                                           defaultLLM: defaultLLM) else {
            NSSound.beep()
            return
        }

        switch defaultAction {
        case .editor(let editor):
            launch(fileURL, with: editor.url)
        case .llm(let target):
            openInLLM(target, fileURL: fileURL)
        }
    }

    // MARK: - Open in LLM

    private static let defaultLLMTargetIDKey = "MarkdownPreview.defaultLLMTargetID"
    private static let llmDeepLinkCharacterLimit = 12_000
    private static let claudeColdLaunchDeepLinkDelay: TimeInterval = 1.25
    private static let chatGPTColdLaunchFileOpenDelay: TimeInterval = 1.25

    private enum LLMHandoff {
        case codexDesktop
        case claudeCodeDesktop
        case chatGPTDocumentOpen
        case copyAndOpen
    }

    private struct LLMTarget {
        let id: String
        let title: String
        let bundleIDs: [String]
        let handoff: LLMHandoff
    }

    private struct LLMCandidate {
        let target: LLMTarget
        let appURL: URL
    }

    private static let llmTargets: [LLMTarget] = [
        LLMTarget(
            id: "codex",
            title: "Codex",
            bundleIDs: ["com.openai.codex"],
            handoff: .codexDesktop
        ),
        LLMTarget(
            id: "claude",
            title: "Claude",
            bundleIDs: ["com.anthropic.claudefordesktop"],
            handoff: .claudeCodeDesktop
        ),
        LLMTarget(
            id: "chatgpt",
            title: "ChatGPT",
            bundleIDs: ["com.openai.chat"],
            handoff: .chatGPTDocumentOpen
        )
    ]

    private var hasLLMTargetsAvailable: Bool {
        !llmCandidates().isEmpty
    }

    private func makeOpenInLLMItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .openInLLM)
        item.label = "Open in LLM"
        item.paletteLabel = "Open in LLM"
        item.toolTip = "Open document in an LLM app"
        item.target = self
        item.action = #selector(openInLLMPrimaryAction(_:))
        item.showsIndicator = true
        openInLLMItem = item
        refreshOpenInLLMItem()
        return item
    }

    private func refreshOpenInLLMItem() {
        let candidates = llmCandidates()
        guard !candidates.isEmpty else {
            removeOpenInLLMToolbarItem()
            return
        }
        let resolvedDefault = resolveDefaultLLM(among: candidates)
        let openInTitle = resolvedDefault.map { "Open in \($0.target.title)" }
        openInLLMItem?.label = openInTitle ?? "Open in LLM"
        openInLLMItem?.image = openInLLMImage(for: resolvedDefault)
        openInLLMItem?.toolTip = openInTitle ?? "Open document in an LLM app"
        openInLLMItem?.menu = buildOpenInLLMMenu(candidates: candidates,
                                                 defaultTarget: resolvedDefault)
    }

    private func removeOpenInLLMToolbarItem() {
        guard let toolbar = documentWindow.toolbar,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .openInLLM }) else {
            return
        }
        toolbar.removeItem(at: index)
    }

    private func openInLLMImage(for candidate: LLMCandidate?) -> NSImage {
        if let appURL = candidate?.appURL {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 20, height: 20)
            return icon
        }
        return NSImage(systemSymbolName: "sparkles",
                       accessibilityDescription: "Open in LLM") ?? NSImage()
    }

    private func llmCandidates() -> [LLMCandidate] {
        Self.llmTargets.compactMap { target in
            let appURL = target.bundleIDs.compactMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }.first
            guard let appURL else { return nil }
            return LLMCandidate(target: target, appURL: appURL)
        }
    }

    private func resolveDefaultLLM(among candidates: [LLMCandidate]) -> LLMCandidate? {
        if let persistedID = UserDefaults.standard.string(forKey: Self.defaultLLMTargetIDKey),
           let match = candidates.first(where: { $0.target.id == persistedID }) {
            return match
        }
        return candidates.first
    }

    private func buildOpenInLLMMenu(candidates: [LLMCandidate],
                                    defaultTarget: LLMCandidate?) -> NSMenu {
        let menu = NSMenu()

        guard currentFileURL != nil else {
            menu.addItem(disabledItem("No document open"))
            return menu
        }
        guard !candidates.isEmpty else {
            menu.addItem(disabledItem("No LLM apps available"))
            return menu
        }

        let header = NSMenuItem()
        header.title = "Open in LLM…"
        header.isEnabled = false
        menu.addItem(header)

        for candidate in candidates {
            let item = NSMenuItem(
                title: candidate.target.title,
                action: #selector(pickLLMTarget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.target.id
            let icon = NSWorkspace.shared.icon(forFile: candidate.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if let defaultTarget, candidate.target.id == defaultTarget.target.id {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openInLLMPrimaryAction(_ sender: Any?) {
        guard let fileURL = currentFileURL else { return }
        let candidates = llmCandidates()
        guard let target = resolveDefaultLLM(among: candidates) else {
            NSSound.beep()
            return
        }
        openInLLM(target, fileURL: fileURL)
    }

    @objc private func pickLLMTarget(_ sender: NSMenuItem) {
        guard let targetID = sender.representedObject as? String,
              let candidate = llmCandidates().first(where: { $0.target.id == targetID }),
              let fileURL = currentFileURL else { return }
        UserDefaults.standard.set(candidate.target.id, forKey: Self.defaultLLMTargetIDKey)
        UserDefaults.standard.set(OpenActionKind.llm.rawValue, forKey: Self.defaultOpenActionKindKey)
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
        openInLLM(candidate, fileURL: fileURL)
    }

    private func openInLLM(_ candidate: LLMCandidate, fileURL: URL) {
        let folderURL = fileURL.deletingLastPathComponent()

        switch candidate.target.handoff {
        case .codexDesktop:
            let prompt = llmPathPrompt(for: fileURL)
            if let url = codexDeepLink(prompt: prompt, folderURL: folderURL) {
                NSWorkspace.shared.open(url)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        case .claudeCodeDesktop:
            let prompt = llmEmbeddedMarkdownPrompt(for: fileURL)
            if prompt.count <= Self.llmDeepLinkCharacterLimit,
               let url = claudeCodeDeepLink(prompt: prompt, folderURL: folderURL) {
                openDeepLink(url, afterLaunchingIfNeeded: candidate, delay: Self.claudeColdLaunchDeepLinkDelay)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        case .chatGPTDocumentOpen:
            openDocumentInChatGPT(fileURL, candidate: candidate)
        default:
            let prompt = llmPathPrompt(for: fileURL)
            copyPromptAndOpen(candidate: candidate, prompt: prompt)
        }
    }

    private func openDeepLink(_ url: URL, afterLaunchingIfNeeded candidate: LLMCandidate, delay: TimeInterval) {
        guard !isRunning(candidate) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: candidate.appURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSSound.beep()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openDocumentInChatGPT(_ fileURL: URL, candidate: LLMCandidate) {
        if isRunning(candidate) {
            sendDocumentOpenEventToChatGPT(fileURL, candidate: candidate)
            return
        }

        let delay = Self.chatGPTColdLaunchFileOpenDelay
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: candidate.appURL,
            configuration: configuration
        ) { [weak self] _, error in
            if error != nil {
                NSSound.beep()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.sendDocumentOpenEventToChatGPT(fileURL, candidate: candidate)
            }
        }
    }

    private func isRunning(_ candidate: LLMCandidate) -> Bool {
        candidate.target.bundleIDs.contains { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
    }

    private func sendDocumentOpenEventToChatGPT(_ fileURL: URL, candidate: LLMCandidate) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: candidate.appURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSSound.beep()
            }
        }
    }

    private func copyPromptAndOpen(candidate: LLMCandidate, prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: candidate.appURL,
            configuration: configuration
        ) { _, _ in }
    }

    private func codexDeepLink(prompt: String, folderURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "prompt", value: prompt),
            URLQueryItem(name: "path", value: folderURL.path)
        ]
        return components.url
    }

    private func claudeCodeDeepLink(prompt: String, folderURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "q", value: prompt),
            URLQueryItem(name: "folder", value: folderURL.path)
        ]
        return components.url
    }

    private func llmPathPrompt(for fileURL: URL) -> String {
        """
        Open this Markdown file and use it as the working context:
        \(fileURL.path)
        """
    }

    private func llmEmbeddedMarkdownPrompt(for fileURL: URL) -> String {
        guard let markdown = currentMarkdown
                ?? (try? String(contentsOf: fileURL, encoding: .utf8)),
              !markdown.isEmpty else {
            return llmPathPrompt(for: fileURL)
        }

        return """
        Use this Markdown document as the working context.

        The local path is included only as a reference. Do not rely on opening it to read the document contents.

        File name: \(fileURL.lastPathComponent)
        Local path: \(fileURL.path)

        Markdown content:
        ````markdown
        \(markdown)
        ````
        """
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
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        switch sender.selectedIndex {
        case 0: split.zoomOutDocument(sender)
        case 1: split.zoomInDocument(sender)
        default: break
        }
    }

    private func inspectorImage() -> NSImage {
        let image = NSImage(systemSymbolName: "info.circle",
                            accessibilityDescription: "Inspector") ?? NSImage()
        image.isTemplate = true
        return image
    }

    @objc private func toggleInspectorAction(_ sender: Any) {
        let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
            .toggleInspector() ?? false
        setInspectorToggleSelected(isVisible)
    }

    private func refreshInspectorToggleItem() {
        let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
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
        (documentWindow.contentViewController as? MainSplitViewController)?
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
           documentWindow.firstResponder === editor {
            documentWindow.makeFirstResponder(nil)
        }
        runFind(query: "")
    }

    @IBAction func performFindPanelAction(_ sender: Any?) {
        handleFindAction(sender)
    }

    @IBAction override func performTextFinderAction(_ sender: Any?) {
        handleFindAction(sender)
    }

    func handleFindAction(_ sender: Any?) {
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
        documentWindow.makeFirstResponder(searchField)
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
    /// Editors we trust to open Markdown even when their Info.plist doesn't pass
    /// `canEditMarkdown`. Markdown-first apps like iA Writer declare a custom
    /// imported UTI (which only *conforms to* `net.daringfireball.markdown`) and
    /// omit `CFBundleTypeExtensions`, so the heuristic can't see them. See #114.
    private static let editorBundleIDAllowlist: Set<String> = [
        "pro.writer.mac",           // iA Writer (Mac App Store / direct)
        "pro.writer.mac-setapp",    // iA Writer (Setapp)
        "abnerworks.Typora",        // Typora
        "com.uranusjr.macdown",     // MacDown
        "md.obsidian"
    ]
    /// Apps that claim a Markdown/plain-text document type but aren't useful as a
    /// text editor — they pass `canEditMarkdown` only as noise. See #114.
    private static let editorBundleIDDenylist: Set<String> = [
        "com.microsoft.Word",
        "com.ideasoncanvas.mindnode.macos",
        "com.somac.subtitleburner"
    ]

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

        return NSWorkspace.shared.urlsForApplications(toOpen: fileURL).compactMap { appURL in
            if selfURLs.contains(canonicalAppURL(appURL)) { return nil }
            let plist = infoPlist(at: appURL)
            let bundleID = (plist?["CFBundleIdentifier"] as? String)
                ?? Bundle(url: appURL)?.bundleIdentifier
            if let bundleID, Self.editorBundleIDDenylist.contains(bundleID) { return nil }
            let isAllowlisted = bundleID.map(Self.editorBundleIDAllowlist.contains) ?? false
            guard isAllowlisted || canEditMarkdown(plist: plist) else { return nil }
            return EditorCandidate(url: appURL, bundleID: bundleID)
        }
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
        UserDefaults.standard.set(OpenActionKind.editor.rawValue, forKey: Self.defaultOpenActionKindKey)
        refreshOpenWithItem()
        refreshOpenActionsItem()
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

    func openInNewTab(_ fileURL: URL) {
        Self.markNextWindowAsTab()
        openDocumentWindow(for: fileURL) {
            // If the document was already open, no window was created and
            // the override wasn't consumed — don't let it leak to the next one.
            Self.nextWindowRequestsTab = false
        }
    }

    func openInNewWindow(_ fileURL: URL) {
        Self.markNextWindowAsSeparate()
        openDocumentWindow(for: fileURL) {
            // If the document was already open, no window was created and
            // the override wasn't consumed — don't let it leak to the next one.
            Self.nextWindowDeclinesTabbing = false
        }
    }

    private func openDocumentWindow(for fileURL: URL, completion: (() -> Void)? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: fileURL,
                                                 display: true) { [weak self] _, _, error in
            completion?()
            guard let self, let error else { return }
            NSAlert(error: error).beginSheetModal(for: self.documentWindow)
        }
    }

    /// Backs the "+" button in the native tab bar and File > New Tab.
    /// There is no untitled-document concept here, so prompt for a file
    /// and open it as a tab — an explicit tab request, unlike ⌘O.
    override func newWindowForTab(_ sender: Any?) {
        promptForDocument(openAsTab: true)
    }

    func openFolder(_ folderURL: URL) {
        let folderURL = folderURL.standardizedFileURL
        if currentFileURL == nil {
            documentWindow.title = folderURL.lastPathComponent
        }
        (documentWindow.contentViewController as? MainSplitViewController)?
            .openFolder(folderURL, selectedFileURL: currentFileURL)
        documentWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        syncSidebarMenuState()
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

    @IBAction func openDocument(_ sender: Any?) {
        promptForDocument(openAsTab: false)
    }

    private func promptForDocument(openAsTab: Bool) {
        let panel = makeOpenPanel()
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if url.isExistingDirectory {
                self.openFolder(url)
                return
            }
            if openAsTab {
                self.openInNewTab(url)
            } else {
                // Plain open: tab placement follows the system
                // "Prefer tabs" setting via attachToExistingTabGroupIfNeeded.
                self.openDocumentWindow(for: url)
            }
        }
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
                                             fileURL: url,
                                             silentOnFailure: silentOnFailure)
            }
        }
    }

    private func applyLoadedMarkdown(_ text: String, fileURL: URL) {
        guard currentFileURL?.standardizedFileURL == fileURL.standardizedFileURL else { return }
        currentMarkdown = text
        refreshOpenInLLMItem()
        updateEditToolbarItem()
        markdownDocument?.replaceContents(markdown: text, fileURL: fileURL)
        renderCurrentDocument(text: text, fileURL: fileURL)
        if pendingEditModeURL == fileURL.standardizedFileURL {
            pendingEditModeURL = nil
            enterEditMode()
        }
    }

    private func applyLoadFailure(error: NSError, fileURL: URL, silentOnFailure: Bool) {
        if pendingEditModeURL == fileURL.standardizedFileURL {
            pendingEditModeURL = nil
            hideEditAccessory()
            updateEditToolbarItem()
        }
        guard !silentOnFailure else { return }
        NSAlert(error: error).beginSheetModal(for: documentWindow)
    }

    private func renderCurrentDocument(text: String, fileURL: URL) {
        (documentWindow.contentViewController as? MainSplitViewController)?
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
        documentWindow.addTitlebarAccessoryViewController(accessory)
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
                   newURL.standardizedFileURL != self.url.standardizedFileURL,
                   !FileManager.default.fileExists(atPath: self.url.path) {
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
