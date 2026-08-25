//
//  ProjectNavigatorView.swift
//  md-preview
//

import Cocoa

private final class FileNode {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdwn"]

    let url: URL
    let isDirectory: Bool
    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var displayName: String { url.lastPathComponent }

    /// Children if `children()` has populated the cache; nil otherwise.
    var cachedChildren: [FileNode]? { loadedChildren }

    func invalidateCache() { loadedChildren = nil }

    func children() -> [FileNode] {
        if let cached = loadedChildren { return cached }
        guard isDirectory else {
            loadedChildren = []
            return []
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let nodes: [FileNode] = entries.compactMap { entry in
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { return FileNode(url: entry, isDirectory: true) }
            guard FileNode.markdownExtensions.contains(entry.pathExtension.lowercased()) else { return nil }
            return FileNode(url: entry, isDirectory: false)
        }
        let sorted = nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        loadedChildren = sorted
        return sorted
    }
}

final class ProjectNavigatorView: NSView {

    var onSelectFile: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var rootNode: FileNode?
    /// The file whose document is actually open. Keep this separate from the
    /// outline's transient click selection so a pending Save/Don't Save/Cancel
    /// decision cannot make the navigator disagree with the editor.
    private var currentFileURL: URL?
    // One watcher per loaded directory; kept in sync with which FileNodes
    // currently have a populated children cache.
    private var watchers: [URL: DirectoryWatcher] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.indentationPerLevel = 14
        outlineView.refusesFirstResponder = true

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        outlineView.menu = contextMenu

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setRoot(_ url: URL?) {
        cancelAllWatchers()
        rootNode = url.map { FileNode(url: $0.standardizedFileURL, isDirectory: true) }
        outlineView.reloadData()
        if let rootNode {
            outlineView.expandItem(rootNode)
            syncWatchers()
        }
    }

    // MARK: - Folder watching

    private func syncWatchers() {
        var live: Set<URL> = []
        if let rootNode { collectLoadedDirectories(rootNode, into: &live) }
        for url in live where watchers[url] == nil {
            watchers[url] = DirectoryWatcher(url: url) { [weak self] in
                self?.handleFolderChange()
            }
        }
        for (url, watcher) in watchers where !live.contains(url) {
            watcher.cancel()
            watchers.removeValue(forKey: url)
        }
    }

    private func collectLoadedDirectories(_ node: FileNode, into set: inout Set<URL>) {
        guard node.isDirectory else { return }
        set.insert(node.url.standardizedFileURL)
        guard let kids = node.cachedChildren else { return }
        for child in kids where child.isDirectory {
            collectLoadedDirectories(child, into: &set)
        }
    }

    private func cancelAllWatchers() {
        for watcher in watchers.values { watcher.cancel() }
        watchers.removeAll()
    }

    private func handleFolderChange() {
        let selectedURL = currentlySelectedURL()
        refreshTree()
        if let selectedURL { setCurrentFile(selectedURL) }
    }

    /// Reloads the outline from disk while preserving expansion state.
    /// Selection is left to the caller.
    private func refreshTree() {
        let expandedURLs = collectExpandedURLs()
        if let rootNode { invalidateCaches(rootNode) }
        outlineView.reloadData()
        if let rootNode {
            outlineView.expandItem(rootNode)
            reExpand(rootNode, expanded: expandedURLs)
        }
        syncWatchers()
    }

    private func invalidateCaches(_ node: FileNode) {
        guard node.isDirectory, let kids = node.cachedChildren else { return }
        for child in kids where child.isDirectory {
            invalidateCaches(child)
        }
        node.invalidateCache()
    }

    private func collectExpandedURLs() -> Set<URL> {
        var result: Set<URL> = []
        func walk(_ item: Any?) {
            let count = outlineView.numberOfChildren(ofItem: item)
            for i in 0..<count {
                let child = outlineView.child(i, ofItem: item)
                if let node = child as? FileNode, outlineView.isItemExpanded(node) {
                    result.insert(node.url.standardizedFileURL)
                    walk(child)
                }
            }
        }
        walk(nil)
        return result
    }

    private func currentlySelectedURL() -> URL? {
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FileNode else { return nil }
        return node.url.standardizedFileURL
    }

    private func reExpand(_ node: FileNode, expanded: Set<URL>) {
        guard node.isDirectory else { return }
        for child in node.children() where child.isDirectory {
            if expanded.contains(child.url.standardizedFileURL) {
                outlineView.expandItem(child)
                reExpand(child, expanded: expanded)
            }
        }
    }

    func setCurrentFile(_ url: URL?) {
        currentFileURL = url?.standardizedFileURL
        guard let url, let rootNode else {
            outlineView.deselectAll(nil)
            return
        }
        let target = url.standardizedFileURL
        var path: [FileNode] = []
        if !collectPath(to: target, from: rootNode, into: &path) {
            // Cache might be stale (file was just renamed and our
            // DirectoryWatcher hasn't fired yet). Refresh from disk once
            // and retry before giving up.
            refreshTree()
            path = []
            guard collectPath(to: target, from: rootNode, into: &path) else {
                outlineView.deselectAll(nil)
                return
            }
        }
        for ancestor in path.dropLast() {
            outlineView.expandItem(ancestor)
        }
        if let leaf = path.last {
            let row = outlineView.row(forItem: leaf)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
                refreshRowTextColors()
            }
        }
    }

    private func collectPath(to targetURL: URL,
                             from root: FileNode,
                             into path: inout [FileNode]) -> Bool {
        // Skip subtrees that can't contain the target.
        guard targetURL.isDescendantOrSame(of: root.url) else { return false }

        for child in root.children() {
            if child.url.standardizedFileURL == targetURL {
                path.append(child)
                return true
            }
            if child.isDirectory {
                path.append(child)
                if collectPath(to: targetURL, from: child, into: &path) { return true }
                path.removeLast()
            }
        }
        return false
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if !node.isDirectory {
            let requestedURL = node.url.standardizedFileURL
            guard requestedURL != currentFileURL else { return }
            // `shouldSelectItem` keeps the highlight on the committed file,
            // so there's no AppKit selection to undo here — display(markdown:)
            // selects the requested file only after navigation succeeds.
            onSelectFile?(node.url)
        }
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let controller = documentWindowController else { return }
        controller.openInNewTab(url)
    }

    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL,
              let controller = documentWindowController else { return }
        controller.openInNewWindow(url)
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    @objc private func copyContents(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { @concurrent in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
    }
}

extension ProjectNavigatorView: NSMenuDelegate {

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        let url = node.url

        menu.addItem(makeMenuItem(title: NSLocalizedString("Show in Finder", comment: "Project navigator context menu"),
                                  symbol: "folder",
                                  action: #selector(showInFinder(_:)),
                                  url: url))

        if !node.isDirectory {
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: NSLocalizedString("Open in New Tab", comment: "Project navigator context menu"),
                                      symbol: "macwindow",
                                      action: #selector(openInNewTab(_:)),
                                      url: url))
            menu.addItem(makeMenuItem(title: NSLocalizedString("Open in New Window", comment: "Project navigator context menu"),
                                      symbol: "macwindow.badge.plus",
                                      action: #selector(openInNewWindow(_:)),
                                      url: url))
            if let controller = documentWindowController {
                for item in controller.contextMenuEditorItems(for: url) {
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
            menu.addItem(makeMenuItem(title: NSLocalizedString("Copy", comment: "Project navigator context menu"),
                                      symbol: "document.on.clipboard",
                                      action: #selector(copyContents(_:)),
                                      url: url))
        } else {
            menu.addItem(.separator())
        }

        menu.addItem(makeMenuItem(title: NSLocalizedString("Copy Path", comment: "Project navigator context menu"),
                                  symbol: "document.on.document",
                                  action: #selector(copyPath(_:)),
                                  url: url))
    }

    private func makeMenuItem(title: String,
                              symbol: String,
                              action: Selector,
                              url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private var documentWindowController: DocumentWindowController? {
        outlineView.window?.windowController as? DocumentWindowController
    }

    /// Theme accent for the selected file row — the link color, matching
    /// the TOC outline's treatment. Nil without a link override.
    fileprivate var themeAccent: NSColor? {
        let isDark = effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return ThemeColorsSetting.current.color(.linkColor, isDark ? .dark : .light)
    }

    func refreshRowTextColors() {
        let accent = themeAccent ?? .controlAccentColor
        let selected = outlineView.selectedRow
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(
                atColumn: 0, row: row, makeIfNecessary: false
            ) as? NSTableCellView, let textField = cell.textField else { continue }
            textField.textColor = row == selected ? accent : .labelColor
        }
    }
}

extension ProjectNavigatorView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.children().count }
        return rootNode == nil ? 0 : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children()[index] }
        return rootNode!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory && !node.children().isEmpty
    }
}

extension ProjectNavigatorView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: NSTableCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.usesSingleLineMode = true
            textField.maximumNumberOfLines = 1
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = node.displayName
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        let row = outlineView.row(forItem: node)
        cell.textField?.textColor = row >= 0 && row == outlineView.selectedRow
            ? (themeAccent ?? .controlAccentColor)
            : .labelColor
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        QuietSelectionRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 24
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshRowTextColors()
    }

    /// A click must not move the selection away from the committed file:
    /// the highlight only follows after navigation actually succeeds
    /// (`setCurrentFile`). Preventing the native selection here is what
    /// stops the O → X → O bounce on file switches. Directories stay
    /// selectable — they have no navigation side effect.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        if node.isDirectory { return true }
        return node.url.standardizedFileURL == currentFileURL?.standardizedFileURL
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        // Newly-loaded subtree needs its own watcher.
        syncWatchers()
    }
}

private final class DirectoryWatcher {
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleChange() }
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

    /// FS events arrive in bursts (Finder rewrites + xattr updates). Coalesce.
    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func cancel() {
        debounce?.cancel()
        source?.cancel()
        source = nil
    }
}
