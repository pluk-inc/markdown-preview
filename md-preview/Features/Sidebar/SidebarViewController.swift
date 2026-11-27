//
//  SidebarViewController.swift
//  md-preview
//

import Cocoa

final class SidebarViewController: NSViewController {

    enum Mode: Int {
        case outline = 0
        case files = 1
    }

    var onSelectHeading: ((Int, Int) -> Void)?
    var onSelectFile: ((URL) -> Void)?
    var onModeChanged: ((Mode) -> Void)?

    private var contentContainer: NSView!
    private var scrollView: NSScrollView!
    private var outlineView: NSOutlineView!
    private var projectNavigator: ProjectNavigatorView!
    private var roots: [TOCNode] = []
    private var titleItem: TitleItem?
    private var lastRenderedMarkdown: String?
    private var lastRenderedFileName: String?
    private var lastRenderedOutline: [TOCItem] = []
    private var resetOutlineState = false
    private var loadedFolderURL: URL?
    private var pendingFolderURL: URL?
    private var pendingFileURL: URL?

    private static let modeDefaultsKey = "Sidebar.Mode"

    private(set) var currentMode: Mode = {
        Mode(rawValue: UserDefaults.standard.integer(forKey: SidebarViewController.modeDefaultsKey)) ?? .outline
    }()

    private var titleOffset: Int { titleItem == nil ? 0 : 1 }

    override func loadView() {
        let container = NSView()

        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentContainer)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        contentContainer.addSubview(scrollView)

        outlineView = NSOutlineView()
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        // Don't grab keyboard focus — leave first responder on the document so
        // arrow / Page keys scroll the preview instead of moving the sidebar
        // selection. Click selects rows via target/action, not via focus.
        outlineView.refusesFirstResponder = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView

        projectNavigator = ProjectNavigatorView()
        projectNavigator.translatesAutoresizingMaskIntoConstraints = false
        projectNavigator.onSelectFile = { [weak self] url in
            self?.onSelectFile?(url)
        }
        projectNavigator.onRequestRoot = { [weak self] folder in
            guard let self else { return }
            self.openFolder(folder, selectedFileURL: self.pendingFileURL)
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(favoriteFoldersDidChange),
                                               name: FavoriteFolders.didChangeNotification,
                                               object: nil)
        contentContainer.addSubview(projectNavigator)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: container.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            projectNavigator.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            projectNavigator.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            projectNavigator.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            projectNavigator.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])

        view = container
        applyMode()
    }

    /// Gives the file tree's bars to the sidebar's split view item, so the
    /// tree scrolls under them with the system's soft edge.
    @available(macOS 26.1, *)
    func installNavigatorAccessories(on item: NSSplitViewItem) {
        loadViewIfNeeded()
        projectNavigator.installAccessories(on: item)
    }

    /// `remember: false` switches this window only, without changing the
    /// mode new windows start in.
    func setMode(_ newMode: Mode, remember: Bool = true) {
        guard newMode != currentMode else { return }
        currentMode = newMode
        if remember {
            UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
        }
        if isViewLoaded {
            applyMode()
            if newMode == .files {
                refreshNavigatorIfNeeded()
            }
        }
        onModeChanged?(newMode)
    }

    /// Expands the file tree down to the open file and scrolls to its row.
    /// A mode change does this itself; this is for a tree that already
    /// shows, where the user collapsed the folder or scrolled away.
    func revealOpenFile() {
        guard isViewLoaded, currentMode == .files else { return }
        refreshNavigatorIfNeeded()
    }

    private func refreshNavigatorIfNeeded() {
        if pendingFolderURL != loadedFolderURL {
            loadedFolderURL = pendingFolderURL
            projectNavigator.setRoot(pendingFolderURL)
        }
        projectNavigator.setCurrentFile(pendingFileURL)
    }

    private func applyMode() {
        switch currentMode {
        case .outline:
            scrollView.isHidden = false
            projectNavigator.isHidden = true
        case .files:
            scrollView.isHidden = true
            projectNavigator.isHidden = false
        }
        projectNavigator.accessoriesActive = currentMode == .files
    }

    func display(markdown: String, fileName: String, fileURL: URL?) {
        prepare(for: fileURL)
        refreshOutline(markdown: markdown, fileName: fileName)
        // Also when the text and the name are the ones shown already, and
        // the outline was not set again.
        awaitsFirstOutline = false
    }

    /// The part of a new document's display that needs no outline. A caller
    /// that parses the outline off the main thread calls this at once, and
    /// `refreshOutline(outline:fileName:)` when the outline is ready.
    func prepare(for fileURL: URL?) {
        loadViewIfNeeded()
        let isOtherFile = pendingFileURL != fileURL?.standardizedFileURL
        setOpenFileURL(fileURL)
        activeHeadingID = nil
        awaitsFirstOutline = true
        guard isOtherFile else { return }
        // A newly opened document must not inherit another file's outline
        // choices, or its rows: until the new outline is here, a click on a
        // row of the document before would scroll this page to a heading
        // number of the other one.
        resetOutlineState = true
        titleItem = nil
        roots = []
        outlineView.reloadData()
    }

    /// Full document display may parse synchronously; live edits supply a
    /// precomputed outline so parsing stays off the main thread.
    func refreshOutline(markdown: String, fileName: String) {
        guard resetOutlineState || markdown != lastRenderedMarkdown || fileName != lastRenderedFileName else { return }
        let outline = MarkdownTOC.parse(markdown)
        lastRenderedMarkdown = markdown
        displayOutline(outline, fileName: fileName)
    }

    /// An outline from a live edit replaces the first outline of the
    /// document, also one that is not here yet. The heading that the page
    /// reported for the text before the edit is not replayed on it: an
    /// edit can move the headings, and their numbers are positions.
    func liveOutlineReplacesFirstOutline() {
        awaitsFirstOutline = false
    }

    func refreshOutline(outline: [TOCItem], fileName: String) {
        // Invalidate the full-source cache: its value predates this live outline.
        lastRenderedMarkdown = nil
        displayOutline(outline, fileName: fileName)
    }

    private func displayOutline(_ outline: [TOCItem], fileName: String) {
        loadViewIfNeeded()
        let isFirstOutline = awaitsFirstOutline
        awaitsFirstOutline = false
        guard resetOutlineState || outline != lastRenderedOutline || fileName != lastRenderedFileName else { return }

        // Source lines can change without altering the visible heading tree.
        // Update click destinations in place rather than resetting outline UI.
        if !resetOutlineState, fileName == lastRenderedFileName,
           updateSourceLines(outline, in: roots) {
            lastRenderedOutline = outline
            return
        }

        // The heading structure changed; use the original default expansion behavior.
        resetOutlineState = false
        lastRenderedOutline = outline
        lastRenderedFileName = fileName
        titleItem = fileName.isEmpty ? nil : TitleItem(title: fileName)
        roots = outline.map(TOCNode.init)
        outlineView.reloadData()
        for root in roots {
            outlineView.expandItem(root, expandChildren: true)
        }
        outlineView.deselectAll(nil)
        // The page can report its heading before a late first outline is
        // here. Not for a later outline: an edit can move the headings,
        // and their numbers are positions.
        if isFirstOutline, let activeHeadingID { setActiveHeading(activeHeadingID) }
    }

    /// Reuse the existing outline rows when only source locations changed.
    private func updateSourceLines(_ items: [TOCItem], in nodes: [TOCNode]) -> Bool {
        guard items.count == nodes.count else { return false }
        for (item, node) in zip(items, nodes) {
            guard item.id == node.headingID, item.level == node.level, item.title == node.title,
                  updateSourceLines(item.children, in: node.children) else { return false }
            node.sourceLine = item.sourceLine
        }
        return true
    }

    /// Update the tracked file URL after a rename — keeps the navigator
    /// selection on the open file without rebuilding the TOC.
    func openFileURLDidChange(_ newURL: URL) {
        loadViewIfNeeded()
        setOpenFileURL(newURL)
    }

    /// The name at the top of an outline that is there, after a rename of
    /// its file. The rows of the headings stay as they are, with the one
    /// that is selected and the ones that are open.
    func renameOutlineTitle(_ fileName: String) {
        guard let titleItem, lastRenderedFileName != nil, fileName != lastRenderedFileName,
              !fileName.isEmpty else { return }
        lastRenderedFileName = fileName
        titleItem.title = fileName
        outlineView.reloadItem(titleItem)
    }

    /// Spinner on the navigator row of a file that is still loading; nil
    /// clears it.
    func setLoadingFile(_ fileURL: URL?) {
        loadViewIfNeeded()
        projectNavigator.setLoadingFile(fileURL)
    }

    /// The folder the Project Navigator is rooted at — the closest thing the
    /// app has to "the current project". Read from `pendingFolderURL` rather
    /// than `loadedFolderURL` so it is right even in TOC mode, where the tree
    /// has not been enumerated yet.
    var projectRootURL: URL? { pendingFolderURL }

    /// Mounts an explicitly chosen folder as the Project Navigator root.
    /// If the current document is inside that folder, keep it selected.
    func openFolder(_ folderURL: URL, selectedFileURL: URL?) {
        loadViewIfNeeded()
        let root = folderURL.standardizedFileURL
        pendingFolderURL = root
        // Kept also when it is outside `root`: the tree then selects
        // nothing, and a switch back to its folder selects it again.
        pendingFileURL = selectedFileURL?.standardizedFileURL
        if currentMode == .files {
            refreshNavigatorIfNeeded()
        }
    }

    /// Defers folder enumeration until the user is actually in the
    /// navigator (saves disk walks on every TOC-mode open). Keeps the
    /// existing root if the new file is a descendant; otherwise resets
    /// so an unrelated File → Open updates the tree.
    ///
    /// A favorite folder above the file wins over both, unless the reader
    /// already moved the root above that favorite.
    private func setOpenFileURL(_ fileURL: URL?) {
        let parent = fileURL?.deletingLastPathComponent().standardizedFileURL
        if let fileURL, let root = FavoriteFolders.root(for: fileURL, keeping: pendingFolderURL) {
            // Compared with the pending root, not the loaded one: while the
            // sidebar shows the headings, the tree has loaded no root yet.
            pendingFolderURL = root
        } else if let parent, let current = loadedFolderURL, parent.isDescendantOrSame(of: current) {
            pendingFolderURL = current
        } else {
            pendingFolderURL = parent
        }
        pendingFileURL = fileURL?.standardizedFileURL
        if currentMode == .files {
            refreshNavigatorIfNeeded()
        }
    }

    /// A favorite added in any window moves this window's root out to it
    /// when it contains the open file. A removal leaves the root as it is.
    @objc private func favoriteFoldersDidChange() {
        // A reader who switched to a folder without the open file keeps it.
        guard let file = pendingFileURL,
              pendingFolderURL.map(file.isDescendantOrSame(of:)) ?? true,
              let root = FavoriteFolders.root(for: file, keeping: pendingFolderURL),
              root != pendingFolderURL else { return }
        openFolder(root, selectedFileURL: file)
    }

    /// The heading that the page reported last, for an outline that comes
    /// after it.
    private var activeHeadingID: Int?
    /// True from a new document's `prepare` until its first outline is set.
    private var awaitsFirstOutline = false

    /// Highlights the matching TOC row. Selecting via the API doesn't
    /// dispatch the outline's action, so this won't loop back into
    /// `onSelectHeading`. We don't `scrollRowToVisible` — yanking the
    /// sidebar while the user scrolls the doc feels jumpy.
    func setActiveHeading(_ headingID: Int?) {
        loadViewIfNeeded()
        activeHeadingID = headingID
        guard let headingID,
              let node = findNode(withID: headingID, in: roots) else {
            outlineView.deselectAll(nil)
            return
        }
        for ancestor in ancestors(of: node, in: roots) {
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0, outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row),
                                     byExtendingSelection: false)
        refreshRowTextColors()
    }

    /// Rows keep concrete colors for the scheme they were styled under;
    /// re-style them when the effective appearance flips (explicit switch
    /// or an Automatic system transition).
    override func viewDidLayout() {
        super.viewDidLayout()
        let appearanceName = view.effectiveAppearance.name
        if appearanceName != lastRowColorAppearance {
            lastRowColorAppearance = appearanceName
            refreshRowTextColors()
        }
    }

    private var lastRowColorAppearance: NSAppearance.Name?

    /// Theme accent for the active TOC row before macOS 27 — the link
    /// color, so the sidebar's highlight matches the page's primary color.
    /// Nil without a link override; the system accent then applies.
    private var themeAccent: NSColor? {
        let isDark = view.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return ThemeColorsSetting.current.color(.linkColor, isDark ? .dark : .light)
    }

    /// Re-applies text colors to visible rows: before macOS 27 the
    /// selected heading gets the theme accent (or the system accent); on
    /// macOS 27, and for every other row, the plain label color.
    func refreshRowTextColors() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
        projectNavigator?.refreshRowTextColors()
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

    private func findNode(withID id: Int, in nodes: [TOCNode]) -> TOCNode? {
        for node in nodes {
            if node.headingID == id { return node }
            if let hit = findNode(withID: id, in: node.children) { return hit }
        }
        return nil
    }

    private func ancestors(of target: TOCNode, in nodes: [TOCNode]) -> [TOCNode] {
        var path: [TOCNode] = []
        func walk(_ node: TOCNode) -> Bool {
            if node === target { return true }
            for child in node.children {
                path.append(node)
                if walk(child) { return true }
                path.removeLast()
            }
            return false
        }
        for root in nodes {
            path = []
            if walk(root) { return path }
        }
        return []
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? TOCNode else { return }
        onSelectHeading?(node.headingID, node.sourceLine)
    }
}

/// Row view whose selection never draws emphasized. While the mouse is
/// down, AppKit emphasizes the pressed row and fills the selection pill
/// with the system accent color — which fights the theme. Suppressing the
/// emphasized state keeps the quiet source-list fill in every state;
/// before macOS 27 the theme accent lives in the row's text color
/// instead. Stateless, so it is created directly rather than recycled. Shared with ProjectNavigatorView.
final class QuietSelectionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// Sidebar row cell whose label keeps its own weight and color when the
/// row is selected. macOS 27 sets the selected source-list row's
/// `textField` in semibold, so there the label stays out of that outlet
/// and the selected row keeps the plain label color. Earlier releases
/// keep the outlet and the theme accent. Shared with ProjectNavigatorView.
class SidebarLabelCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        if #unavailable(macOS 27.0) {
            textField = label
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func textColor(selected: Bool, accent: @autoclosure () -> NSColor) -> NSColor {
        if #available(macOS 27.0, *) { return .labelColor }
        return selected ? accent() : .labelColor
    }
}

private final class TitleItem {
    var title: String
    init(title: String) { self.title = title }
}

final class TOCNode {
    let headingID: Int
    let level: Int
    let title: String
    var sourceLine: Int
    let children: [TOCNode]

    init(_ item: TOCItem) {
        self.headingID = item.id
        self.level = item.level
        self.title = item.title
        self.sourceLine = item.sourceLine
        self.children = item.children.map(TOCNode.init)
    }
}

extension SidebarViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? TOCNode { return node.children.count }
        return roots.count + titleOffset
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? TOCNode { return node.children[index] }
        if let titleItem, index == 0 { return titleItem }
        return roots[index - titleOffset]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TOCNode else { return false }
        return !node.children.isEmpty
    }
}

extension SidebarViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        if let titleItem = item as? TitleItem {
            return titleCell(for: titleItem, in: outlineView)
        }
        guard let node = item as? TOCNode else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("TOCCell")
        let cell: SidebarLabelCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarLabelCellView {
            cell = recycled
        } else {
            cell = SidebarLabelCellView(identifier: identifier)

            let textField = cell.label
            textField.lineBreakMode = .byTruncatingTail
            textField.cell?.usesSingleLineMode = true
            textField.cell?.truncatesLastVisibleLine = true
            textField.maximumNumberOfLines = 1
            textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textField.setContentHuggingPriority(.defaultLow, for: .horizontal)

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.label.stringValue = node.title
        let row = outlineView.row(forItem: node)
        cell.label.textColor = SidebarLabelCellView.textColor(
            selected: row >= 0 && row == outlineView.selectedRow,
            accent: themeAccent ?? .controlAccentColor)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        QuietSelectionRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return item is TOCNode
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        refreshRowTextColors()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        return 30
    }

    private func titleCell(for titleItem: TitleItem, in outlineView: NSOutlineView) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("TitleCell")
        let cell: NSTableCellView
        if let recycled = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            textField.textColor = .secondaryLabelColor
            textField.lineBreakMode = .byTruncatingMiddle
            textField.cell?.usesSingleLineMode = true
            textField.maximumNumberOfLines = 1
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                textField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
                textField.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4)
            ])
        }
        cell.textField?.stringValue = titleItem.title
        return cell
    }
}
