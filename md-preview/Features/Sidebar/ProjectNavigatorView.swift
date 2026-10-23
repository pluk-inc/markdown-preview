//
//  ProjectNavigatorView.swift
//  md-preview
//

import Cocoa
import UniformTypeIdentifiers

private final class FileNode {
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
            guard ProjectFileIndex.markdownExtensions.contains(entry.pathExtension.lowercased()) else { return nil }
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
    private let filterBar = ProjectNavigatorFilterBar()
    private var rootNode: FileNode?
    /// Paths of the files that match the filter bar, plus every folder
    /// between them and the root, while a filter is active. The data source
    /// hides all other rows of the same tree, so watching, selection and
    /// creating files need no filter cases.
    private var visiblePaths: Set<String>?
    /// Each folder's filtered children. NSOutlineView asks for children one
    /// index at a time, so filtering on every call would be quadratic.
    private var visibleChildren: [ObjectIdentifier: [FileNode]] = [:]
    private var filterTask: Task<Void, Never>?
    /// Set when a folder changes while filtering. A flag rather than a task
    /// argument, so a keystroke that replaces the pending task still drops
    /// the stale walk.
    private var indexIsStale = false
    /// The folders that were open before the filter took over the tree, so
    /// clearing the filter puts the tree back as the reader left it.
    private var expandedBeforeFilter: Set<URL> = []
    private var isFiltering: Bool { !filterBar.filterText.isEmpty || filterBar.showsRecentOnly }
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

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.makeAddMenu = { [weak self] in self?.makeAddMenu() ?? NSMenu() }
        filterBar.onFilterChange = { [weak self] in self?.applyFilter() }
        addSubview(filterBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: filterBar.topAnchor),

            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterBar.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func setRoot(_ url: URL?) {
        cancelAllWatchers()
        filterTask?.cancel()
        visiblePaths = nil
        visibleChildren.removeAll()
        expandedBeforeFilter = []
        rootNode = url.map { FileNode(url: $0.standardizedFileURL, isDirectory: true) }
        outlineView.reloadData()
        if let rootNode {
            outlineView.expandItem(rootNode)
            syncWatchers()
        }
        if isFiltering { applyFilter() }
    }

    // MARK: - Filtering

    /// Narrows the tree to the filter bar's matches. The match runs over the
    /// project file index rather than the outline's lazy nodes, so files in
    /// folders the reader never opened are found too. `reloadingIndex` drops
    /// the cached walk first, for changes on disk.
    private func applyFilter(reloadingIndex: Bool = false) {
        filterTask?.cancel()
        if reloadingIndex { indexIsStale = true }
        guard let rootNode, isFiltering else {
            clearFilter()
            return
        }
        let query = filterBar.filterText
        let recentPaths: Set<String>? = filterBar.showsRecentOnly
            ? Set(NSDocumentController.shared.recentDocumentURLs.map(\.standardizedFileURL.path))
            : nil
        let root = rootNode.url
        filterTask = Task { [weak self] in
            // The field reports every key; wait for a pause in the typing.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            if self.indexIsStale {
                self.indexIsStale = false
                await ProjectFileIndex.shared.invalidate(root: root)
            }
            let snapshot = await ProjectFileIndex.shared.snapshot(for: root)
            let visible = await Self.visiblePaths(in: snapshot, query: query, recentPaths: recentPaths)
            guard !Task.isCancelled else { return }
            self.showFiltered(visible)
        }
    }

    /// The matching files plus every folder between them and the root.
    @concurrent
    private nonisolated static func visiblePaths(in snapshot: ProjectFileIndex.Snapshot,
                                                 query: String,
                                                 recentPaths: Set<String>?) async -> Set<String> {
        let rootPath = snapshot.root.standardizedFileURL.path
        var visible: Set<String> = [rootPath]
        for (index, candidate) in snapshot.candidates.enumerated() {
            guard query.isEmpty || candidate.fileName.localizedCaseInsensitiveContains(query),
                  var url = snapshot.url(at: index)?.standardizedFileURL,
                  recentPaths?.contains(url.path) ?? true else { continue }
            // Stops at the first folder already added; the root always is.
            while visible.insert(url.path).inserted {
                url = url.deletingLastPathComponent()
            }
        }
        return visible
    }

    private func showFiltered(_ visible: Set<String>) {
        if visiblePaths == nil {
            expandedBeforeFilter = collectExpandedURLs()
        }
        visiblePaths = visible
        visibleChildren.removeAll()
        outlineView.reloadData()
        if let rootNode {
            outlineView.expandItem(rootNode, expandChildren: true)
        }
        setCurrentFile(currentFileURL)
    }

    private func clearFilter() {
        guard visiblePaths != nil else { return }
        visiblePaths = nil
        visibleChildren.removeAll()
        outlineView.reloadData()
        if let rootNode {
            outlineView.expandItem(rootNode)
            reExpand(rootNode, expanded: expandedBeforeFilter)
        }
        syncWatchers()
        setCurrentFile(currentFileURL)
    }

    /// The children the outline shows: all of them, or the filter's matches.
    private func shownChildren(of node: FileNode) -> [FileNode] {
        guard let visiblePaths else { return node.children() }
        let key = ObjectIdentifier(node)
        if let cached = visibleChildren[key] { return cached }
        let shown = node.children().filter { visiblePaths.contains($0.url.standardizedFileURL.path) }
        visibleChildren[key] = shown
        return shown
    }

    // MARK: - Adding files

    private func makeAddMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let hasRoot = rootNode != nil
        add(NSLocalizedString("New Empty File", comment: "Project navigator add menu"),
            #selector(newEmptyFile), enabled: hasRoot)
        add(NSLocalizedString("New File from Clipboard", comment: "Project navigator add menu"),
            #selector(newFileFromClipboard),
            enabled: hasRoot && NSPasteboard.general.availableType(from: [.string]) != nil)
        menu.addItem(.separator())
        add(NSLocalizedString("New Folder", comment: "Project navigator add menu"),
            #selector(newFolder), enabled: hasRoot)
        menu.addItem(.separator())
        let folderName = newFileFolder()?.lastPathComponent ?? ""
        add(String(format: NSLocalizedString("Add Files to “%@”…", comment: "Project navigator add menu; folder name"), folderName),
            #selector(addFiles), enabled: hasRoot)
        return menu
    }

    @objc private func newEmptyFile() {
        createItem(contents: Data())
    }

    @objc private func newFileFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        createItem(contents: Data(text.utf8))
    }

    @objc private func newFolder() {
        createItem(contents: nil)
    }

    /// Makes a file with `contents`, or a folder when it is nil, at once
    /// under a default name, shows it in the tree, and puts its name into
    /// editing, as Xcode does. A file opens once the reader confirms the name.
    private func createItem(contents: Data?) {
        guard let folder = newFileFolder() else { return }
        let isFolder = contents == nil
        // A new "Untitled" row may not match the filter; show the full tree.
        filterBar.clearFilter()
        let base = isFolder
            ? NSLocalizedString("New Folder", comment: "Name of a new folder made from the project navigator")
            : NSLocalizedString("Untitled", comment: "Name of a new Markdown file made from the project navigator")
        let create = { () throws -> URL in
            let url = Self.uniqueURL(in: folder, base: base, extension: isFolder ? nil : "md")
            if let contents {
                try contents.write(to: url, options: .withoutOverwriting)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            }
            return url
        }
        withWriteAccess(to: folder, create) { [weak self] url in
            guard let self else { return }
            self.refreshTree()
            if let row = self.reveal(url) {
                self.beginRenaming(url, row: row)
            } else if !isFolder {
                self.onSelectFile?(url)
            }
        }
    }

    /// Copies files the reader picks into the target folder.
    @objc private func addFiles() {
        guard let folder = newFileFolder(), let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ProjectFileIndex.markdownExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = NSLocalizedString("Add", comment: "Project navigator add files panel button")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            // The retry after an access prompt skips the files already copied.
            var remaining = panel.urls
            self.withWriteAccess(to: folder, {
                while let source = remaining.first {
                    let name = source.deletingPathExtension().lastPathComponent
                    let target = Self.uniqueURL(in: folder, base: name, extension: source.pathExtension)
                    try FileManager.default.copyItem(at: source, to: target)
                    remaining.removeFirst()
                }
            }, then: { [weak self] in
                self?.handleFolderChange()
            })
        }
    }

    // MARK: - Write access

    /// Runs `body`. The sandbox lets the app write only inside folders the
    /// reader chose — a folder that was mounted by opening a file in it is
    /// read-only — so a failed write asks once for the project folder. The
    /// grant covers every folder under it and is kept as a bookmark, so
    /// later launches do not ask again.
    private func withWriteAccess<T>(to folder: URL,
                                    _ body: @escaping () throws -> T,
                                    then: @escaping (T) -> Void) {
        func attempt() throws { then(try body()) }
        do {
            try attempt()
            return
        } catch where Self.isPermissionError(error) && FolderWriteAccess.restore(for: folder) {
            // A folder allowed in an earlier launch only needed its bookmark.
            do { try attempt() } catch { showError(error) }
            return
        } catch where Self.isPermissionError(error) {
            // Ask for the folder below.
        } catch {
            showError(error)
            return
        }
        guard let window else { return }
        let grantFolder = rootNode.map { folder.isDescendantOrSame(of: $0.url) ? $0.url : folder } ?? folder
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = grantFolder
        panel.prompt = NSLocalizedString("Allow", comment: "Project navigator write access panel button")
        panel.message = String(
            format: NSLocalizedString("Allow Markdown Preview to make files in “%@”.",
                                      comment: "Project navigator write access panel message; folder name"),
            grantFolder.lastPathComponent)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let chosen = panel.url else { return }
            guard folder.isDescendantOrSame(of: chosen.standardizedFileURL) else {
                NSSound.beep()
                return
            }
            FolderWriteAccess.remember(chosen)
            do { try attempt() } catch { self.showError(error) }
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        return false
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: - Renaming in place

    /// The row whose name is being typed. Folder changes wait until it ends,
    /// because reloading the outline would throw the editing cell away.
    private var renamingURL: URL?
    private var folderChangedWhileRenaming = false

    private func beginRenaming(_ url: URL, row: Int) {
        guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarLabelCellView else { return }
        renamingURL = url
        let label = cell.label
        label.isEditable = true
        label.isSelectable = true
        label.delegate = self
        guard window?.makeFirstResponder(label) == true else {
            endRenaming(label, commit: false)
            return
        }
        // Select the name without its extension, as the Finder does.
        let baseLength = (url.deletingPathExtension().lastPathComponent as NSString).length
        label.currentEditor()?.selectedRange = NSRange(location: 0, length: baseLength)
    }

    private func endRenaming(_ label: NSTextField, commit: Bool) {
        guard let url = renamingURL else { return }
        renamingURL = nil
        label.isEditable = false
        label.isSelectable = false
        label.delegate = nil
        var finalURL = url
        if commit, let renamed = renamedURL(for: url, typed: label.stringValue) {
            do {
                try FileManager.default.moveItem(at: url, to: renamed)
                finalURL = renamed
            } catch {
                showError(error)
            }
        }
        label.stringValue = finalURL.lastPathComponent
        if folderChangedWhileRenaming {
            // Replay the change that waited: it also refreshes the file index.
            folderChangedWhileRenaming = false
            handleFolderChange()
        } else if finalURL != url {
            refreshTree()
        }
        if finalURL.hasDirectoryPath {
            reveal(finalURL)
        } else {
            onSelectFile?(finalURL)
        }
    }

    /// The new location for a typed name, or nil when the name is unchanged
    /// or cannot be used. A file named without an extension keeps `.md`.
    private func renamedURL(for url: URL, typed: String) -> URL? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"),
              name != url.lastPathComponent else { return nil }
        let isFolder = url.hasDirectoryPath
        if !isFolder, (name as NSString).pathExtension.isEmpty {
            name += ".md"
        }
        let target = url.deletingLastPathComponent().appending(path: name, directoryHint: isFolder ? .isDirectory : .notDirectory)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            NSSound.beep()
            return nil
        }
        return target
    }

    /// Expands the tree down to `url`, selects its row and returns it; nil
    /// when the item is not in the tree or the filter hides it.
    @discardableResult
    private func reveal(_ url: URL) -> Int? {
        guard let rootNode else { return nil }
        var path: [FileNode] = []
        guard collectPath(to: url.standardizedFileURL, from: rootNode, into: &path),
              let leaf = path.last else { return nil }
        for ancestor in path.dropLast() {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: leaf)
        guard row >= 0 else { return nil }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        refreshRowTextColors()
        return row
    }

    /// The selected folder, else the open file's folder, else the root.
    private func newFileFolder() -> URL? {
        let row = outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? FileNode, node.isDirectory {
            return node.url
        }
        if let rootNode, let currentFileURL, currentFileURL.isDescendantOrSame(of: rootNode.url) {
            return currentFileURL.deletingLastPathComponent()
        }
        return rootNode?.url
    }

    private static func uniqueURL(in folder: URL, base: String, extension ext: String?) -> URL {
        func url(_ name: String) -> URL {
            guard let ext, !ext.isEmpty else { return folder.appending(path: name, directoryHint: .isDirectory) }
            return folder.appending(path: "\(name).\(ext)")
        }
        var candidate = url(base)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base) \(number)")
            number += 1
        }
        return candidate
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
        if renamingURL != nil {
            folderChangedWhileRenaming = true
            return
        }
        let selectedURL = currentlySelectedURL()
        refreshTree()
        if let selectedURL { setCurrentFile(selectedURL) }
        // The file index is shared with Search for Document; drop its walk so
        // both see the change.
        if isFiltering {
            applyFilter(reloadingIndex: true)
        } else if let root = rootNode?.url {
            Task { await ProjectFileIndex.shared.invalidate(root: root) }
        }
    }

    /// Reloads the outline from disk while preserving expansion state.
    /// Selection is left to the caller.
    private func refreshTree() {
        let expandedURLs = collectExpandedURLs()
        if let rootNode { invalidateCaches(rootNode) }
        visibleChildren.removeAll()
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
        let opensOtherFile = url?.standardizedFileURL != currentFileURL
        currentFileURL = url?.standardizedFileURL
        // A newly opened file has just become recent; let it show.
        if opensOtherFile, filterBar.showsRecentOnly, let url,
           visiblePaths?.contains(url.standardizedFileURL.path) == false {
            applyFilter()
        }
        guard let url, rootNode != nil else {
            outlineView.deselectAll(nil)
            return
        }
        if reveal(url) != nil { return }
        // Cache might be stale (file was just renamed and our
        // DirectoryWatcher hasn't fired yet). Refresh from disk once and
        // retry before giving up. A file the filter hides needs no refresh.
        if visiblePaths == nil {
            refreshTree()
            if reveal(url) != nil { return }
        }
        outlineView.deselectAll(nil)
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
        if node.isDirectory {
            // Disclosure buttons handle their own clicks in AppKit; this
            // action covers the folder's name, icon, and remaining row area.
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
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

extension ProjectNavigatorView: NSTextFieldDelegate {

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let label = obj.object as? NSTextField else { return }
        endRenaming(label, commit: true)
    }

    /// Escape keeps the name the item was made with.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)),
              let label = control as? NSTextField else { return false }
        // abortEditing drops the typed text without the end-editing
        // notification, which would commit it.
        label.abortEditing()
        endRenaming(label, commit: false)
        return true
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

    /// Theme accent for the selected file row before macOS 27 — the link
    /// color, matching the TOC outline's treatment. Nil without a link
    /// override. macOS 27 keeps the plain label color.
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
            ) as? SidebarLabelCellView else { continue }
            cell.label.textColor = SidebarLabelCellView.textColor(
                selected: row == selected, accent: accent)
        }
    }
}

extension ProjectNavigatorView: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return shownChildren(of: node).count }
        return rootNode == nil ? 0 : 1
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return shownChildren(of: node)[index] }
        return rootNode!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory && !shownChildren(of: node).isEmpty
    }
}

extension ProjectNavigatorView: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell: SidebarLabelCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarLabelCellView {
            cell = recycled
        } else {
            cell = SidebarLabelCellView(identifier: identifier)

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = cell.label
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.usesSingleLineMode = true
            textField.maximumNumberOfLines = 1

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

        cell.label.stringValue = node.displayName
        let icon = NSWorkspace.shared.icon(forFile: node.url.path)
        icon.size = NSSize(width: 16, height: 16)
        cell.imageView?.image = icon
        let row = outlineView.row(forItem: node)
        cell.label.textColor = SidebarLabelCellView.textColor(
            selected: row >= 0 && row == outlineView.selectedRow,
            accent: themeAccent ?? .controlAccentColor)
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

/// Folders the reader allowed the navigator to write to, kept as
/// security-scoped bookmarks across launches.
@MainActor
private enum FolderWriteAccess {
    private static let defaultsKey = "ProjectNavigator.WriteAccessBookmarks"
    /// Folders whose access is already started in this process.
    private static var accessing: Set<URL> = []

    static func remember(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard let data = try? folder.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) else { return }
        var bookmarks = storedBookmarks
        bookmarks[folder.path] = data
        UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
    }

    /// Starts access through the bookmark of `folder` or of a folder above
    /// it. Returns false when no bookmark covers it.
    static func restore(for folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        var bookmarks = storedBookmarks
        // Resolve before matching: a folder renamed or moved since it was
        // allowed is found at its new location.
        for (path, data) in bookmarks {
            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else {
                // Keep it: the folder may be on a drive that is not mounted.
                continue
            }
            let resolved = url.standardizedFileURL
            guard folder.isDescendantOrSame(of: resolved),
                  accessing.contains(resolved) || url.startAccessingSecurityScopedResource() else { continue }
            accessing.insert(resolved)
            if isStale || resolved.path != path {
                bookmarks[path] = nil
                UserDefaults.standard.set(bookmarks, forKey: defaultsKey)
                remember(resolved)
            }
            return true
        }
        return false
    }

    private static var storedBookmarks: [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
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
