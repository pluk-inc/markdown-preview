//
//  DocumentWindowController.swift
//  md-preview
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import UniformTypeIdentifiers

extension NSToolbarItem.Identifier {
    static let openWith = NSToolbarItem.Identifier("OpenWith")
    static let openInLLM = NSToolbarItem.Identifier("OpenInLLM")
    static let inspector = NSToolbarItem.Identifier("Inspector")
    static let share = NSToolbarItem.Identifier("Share")
    static let search = NSToolbarItem.Identifier("Search")
    static let sidebarMenu = NSToolbarItem.Identifier("SidebarMenu")
    static let printDocument = NSToolbarItem.Identifier("PrintDocument")
    static let copyMarkdown = NSToolbarItem.Identifier("CopyMarkdown")
    static let zoom = NSToolbarItem.Identifier("Zoom")
}

private extension Array where Element == NSToolbarItem.Identifier {
    mutating func insertAfterOpenWith(_ identifier: NSToolbarItem.Identifier) {
        guard let index = firstIndex(of: .openWith) else {
            append(identifier)
            return
        }
        insert(identifier, at: index + 1)
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate, NSMenuDelegate {

    private var currentFileURL: URL?
    private var currentMarkdown: String?
    private var fileWatcher: FileWatcher?
    private var isInspectorToggleSelected = false
    private weak var openWithItem: NSMenuToolbarItem?
    private weak var openInLLMItem: NSMenuToolbarItem?
    private weak var inspectorItem: NSToolbarItem?
    private weak var inspectorButton: NSButton?
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

    private func setupWindow() {
        documentWindow.styleMask.insert(.fullSizeContentView)
        documentWindow.delegate = self
        let split = MainSplitViewController()
        split.onSelectFile = { [weak self] url in
            self?.present(url: url)
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

    func windowWillClose(_ notification: Notification) {
        fileWatcher?.cancel()
        fileWatcher = nil
    }

    func display(markdown: String, fileURL: URL?) {
        currentFileURL = fileURL
        currentMarkdown = markdown
        documentWindow.title = fileURL?.lastPathComponent ?? "Untitled"
        documentWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        refreshOpenWithItem()
        refreshOpenInLLMItem()
        if let fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
            renderCurrentDocument(text: markdown, fileURL: fileURL)
            startWatching(fileURL)
            offerToBecomeDefaultHandlerIfNeeded()
        }
    }

    private func present(url: URL) {
        if url.isExistingDirectory {
            openFolder(url)
            return
        }

        // Switching to a different file blanks the preview so the previous
        // doc doesn't linger on screen during sheet dismissal + load.
        let isFileSwitch = currentFileURL != nil && currentFileURL != url
        currentFileURL = url
        currentMarkdown = nil
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
        markdownDocument?.replaceFileURL(newURL)
        documentWindow.title = newURL.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(newURL)
        refreshOpenWithItem()
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
        var identifiers: [NSToolbarItem.Identifier] = [
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
        if hasLLMTargetsAvailable {
            identifiers.insertAfterOpenWith(.openInLLM)
        }
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
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
        if hasLLMTargetsAvailable {
            identifiers.insertAfterOpenWith(.openInLLM)
        }
        return identifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarMenu: return makeSidebarMenuItem(willBeInsertedIntoToolbar: flag)
        case .openWith: return makeOpenWithItem()
        case .openInLLM:
            guard hasLLMTargetsAvailable else { return nil }
            return makeOpenInLLMItem()
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

    // MARK: - Open in LLM

    private static let defaultLLMTargetIDKey = "MarkdownPreview.defaultLLMTargetID"
    private static let llmDeepLinkCharacterLimit = 12_000

    private enum LLMHandoff {
        case codexDesktop
        case claudeCodeDesktop
        case chatGPTUniversalLink
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
            handoff: .chatGPTUniversalLink
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
        refreshOpenInLLMItem()
        openInLLM(candidate, fileURL: fileURL)
    }

    private func openInLLM(_ candidate: LLMCandidate, fileURL: URL) {
        let prompt = llmPrompt(for: fileURL)
        let folderURL = fileURL.deletingLastPathComponent()

        switch candidate.target.handoff {
        case .codexDesktop:
            if let url = codexDeepLink(prompt: prompt, folderURL: folderURL) {
                NSWorkspace.shared.open(url)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        case .claudeCodeDesktop where prompt.count <= Self.llmDeepLinkCharacterLimit:
            if let url = claudeCodeDeepLink(prompt: prompt, folderURL: folderURL, fileURL: fileURL) {
                NSWorkspace.shared.open(url)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        case .chatGPTUniversalLink:
            if let url = chatGPTUniversalLink(prompt: prompt) {
                NSWorkspace.shared.open(url)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        default:
            copyPromptAndOpen(candidate: candidate, prompt: prompt)
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

    private func claudeCodeDeepLink(prompt: String, folderURL: URL, fileURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "q", value: prompt),
            URLQueryItem(name: "folder", value: folderURL.path),
            URLQueryItem(name: "file", value: fileURL.path)
        ]
        return components.url
    }

    private func chatGPTUniversalLink(prompt: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chatgpt.com"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "q", value: prompt)
        ]
        return components.url
    }

    private func llmPrompt(for fileURL: URL) -> String {
        """
        Open this Markdown file and use it as the working context:
        \(fileURL.absoluteString)

        The file is on this Mac at:
        \(fileURL.path)
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
        let image = NSImage(systemSymbolName: "info",
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
        "md.obsidian"               // Obsidian
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
        NSDocumentController.shared.openDocument(withContentsOf: fileURL,
                                                 display: true) { [weak self] _, _, error in
            guard let self, let error else { return }
            NSAlert(error: error).beginSheetModal(for: self.documentWindow)
        }
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
        let panel = makeOpenPanel()
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if url.isExistingDirectory {
                self.openFolder(url)
                return
            }
            self.openInNewWindow(url)
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
                                             silentOnFailure: silentOnFailure)
            }
        }
    }

    private func applyLoadedMarkdown(_ text: String, fileURL: URL) {
        currentMarkdown = text
        refreshOpenInLLMItem()
        markdownDocument?.replaceContents(markdown: text, fileURL: fileURL)
        renderCurrentDocument(text: text, fileURL: fileURL)
    }

    private func applyLoadFailure(error: NSError, silentOnFailure: Bool) {
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
