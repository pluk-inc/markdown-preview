//
//  FileSearchPanelController.swift
//  md-preview
//
//  The Search for Document palette: type part of a file name, pick a result,
//  open it. Each document presents its own floating panel so the results
//  remain scoped to that document’s project root.
//

import Cocoa

@MainActor
final class FileSearchPanelController: NSViewController {

    enum OpenTarget {
        case currentTab
        case newTab
        case newWindow
    }

    /// Called with the chosen file once the panel has gone. The controller
    /// dismisses itself first — see `activateSelection`.
    var onOpen: ((URL, OpenTarget) -> Void)?
    /// Called when the reader asks for a folder from the empty state.
    var onRequestOpenFolder: (() -> Void)?

    var onDismiss: (() -> Void)?
    private var presentation: FileSearchPanelPresentation?

    func present(relativeTo parent: NSWindow) {
        let presentation = FileSearchPanelPresentation()
        self.presentation = presentation
        presentation.present(self, relativeTo: parent)
    }

    fileprivate func closePalette() {
        guard let presentation else { return }
        self.presentation = nil
        debounce?.cancel()
        debounce = nil
        rankTask?.cancel()
        rankTask = nil
        pendingActivation = nil
        presentation.close()
        onDismiss?()
    }

    private let projectRoot: URL?
    private let index: ProjectFileIndex

    private let queryField = PlainQueryField()
    private let fieldSeparator = HairlineSeparator()
    private let resultsContainer = NSView()
    private var resultsHeightConstraint: NSLayoutConstraint?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let openFolderButton = NSButton()

    private var hasSearchQuery: Bool {
        !queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var snapshot: ProjectFileIndex.Snapshot?
    /// Indices into `snapshot.candidates`, best first.
    private var results: [Int] = []
    /// The field text `results` were ranked for. Nil until the first ranking
    /// lands. When it differs from the field, what is on screen belongs to
    /// an earlier query.
    private var rankedQuery: String?
    private var debounce: DispatchWorkItem?
    private var rankTask: Task<Void, Never>?
    /// A Return pressed while the list was still catching up with the field.
    /// Honoured once the ranking for the current text lands, so the file
    /// opened is the one the reader was about to see at the top.
    private var pendingActivation: OpenTarget?

    init(projectRoot: URL?, index: ProjectFileIndex = .shared) {
        self.projectRoot = projectRoot
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override func loadView() {
        // Sized by frame rather than by self-constraints: AppKit owns a view
        // controller's root view frame, and the panel takes its size from it.
        let root = KeyEquivalentView(frame: NSRect(x: 0, y: 0, width: 480,
                                                   height: projectRoot == nil ? 160 : 52))
        // Clip the backing surface as well as the glass so no rectangular
        // backdrop is visible outside the rounded panel corners.
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.layer?.cornerRadius = 20
        root.layer?.masksToBounds = true
        root.onKey = { [weak self] event in self?.handleNavigationKey(event) ?? false }
        let container = DraggablePaletteContent(frame: root.bounds)
        container.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: root.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = container
            root.addSubview(glass)
        } else {
            let effect = NSVisualEffectView(frame: root.bounds)
            effect.autoresizingMask = [.width, .height]
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 20
            effect.layer?.masksToBounds = true
            effect.addSubview(container)
            root.addSubview(effect)
        }
        view = root

        let searchIcon = NSImageView()
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = .init(pointSize: 19, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor

        // A large, unbezelled field with a hairline under it, the way Xcode's
        // Open Quickly presents it: in a palette the field is the whole point,
        // so it reads as the subject rather than as one control among several.
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.placeholderString = NSLocalizedString("Search files by name",
                                                         comment: "Search for Document field placeholder")
        queryField.delegate = self
        queryField.font = .systemFont(ofSize: 20)
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.lineBreakMode = .byTruncatingTail

        fieldSeparator.translatesAutoresizingMaskIntoConstraints = false

        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.style = .fullWidth
        tableView.rowHeight = 40
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        // Focus belongs in the field; the arrow keys drive this from there,
        // the way both existing outline views do it.
        tableView.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true

        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        openFolderButton.bezelStyle = .rounded
        openFolderButton.title = NSLocalizedString("Open Folder…", comment: "Search for Document empty state button")
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderTapped)
        openFolderButton.isHidden = true

        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        resultsContainer.isHidden = projectRoot != nil
        fieldSeparator.isHidden = projectRoot != nil
        for subview in [searchIcon, queryField, fieldSeparator, resultsContainer] {
            container.addSubview(subview)
        }
        for subview in [scrollView, statusLabel, openFolderButton] {
            resultsContainer.addSubview(subview)
        }

        let resultsHeight = resultsContainer.heightAnchor.constraint(equalToConstant: 108)
        resultsHeightConstraint = resultsHeight
        NSLayoutConstraint.activate([
            resultsHeight,
            queryField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            searchIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: queryField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),
            searchIcon.heightAnchor.constraint(equalToConstant: 22),
            queryField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            queryField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            fieldSeparator.topAnchor.constraint(equalTo: container.topAnchor, constant: 51),
            fieldSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            fieldSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            fieldSeparator.heightAnchor.constraint(equalToConstant: 1),

            resultsContainer.topAnchor.constraint(equalTo: fieldSeparator.bottomAnchor),
            resultsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultsContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: resultsContainer.topAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: resultsContainer.bottomAnchor, constant: -8),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            openFolderButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            openFolderButton.centerXAnchor.constraint(equalTo: statusLabel.centerXAnchor)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        (view.window as? FileSearchPanel)?.queryField = queryField
        view.window?.makeFirstResponder(queryField)
        updatePanelSize()
        loadIndex()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        debounce?.cancel()
        debounce = nil
        rankTask?.cancel()
        rankTask = nil
        pendingActivation = nil
    }

    /// Keep the empty query as a single search bar, expanding downwards once
    /// there is something to find. The field stays in the same screen position.
    private func updatePanelSize() {
        let expanded = projectRoot == nil || (hasSearchQuery && rankedQuery == queryField.stringValue)
        resultsContainer.isHidden = !expanded
        fieldSeparator.isHidden = !expanded
        guard let panel = view.window else { return }
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        let resultsHeight = results.isEmpty ? 108 : CGFloat(min(results.count, 6)) * rowHeight + 12
        resultsHeightConstraint?.constant = resultsHeight
        let height: CGFloat = 52 + (expanded ? resultsHeight : 0)
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        if let screen = panel.screen {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY + 16)
        }
        guard frame != panel.frame else { return }
        let animate = panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let searchPanel = panel as? FileSearchPanel
        searchPanel?.isResizingForResults = true
        defer { searchPanel?.isResizingForResults = false }
        panel.setFrame(frame, display: true, animate: animate)
        panel.invalidateShadow()
    }

    // MARK: - Index

    private func loadIndex() {
        guard let projectRoot else {
            showEmptyState()
            return
        }
        Task { [weak self, index] in
            let snapshot = await index.snapshot(for: projectRoot)
            guard let self, self.presentation != nil else { return }
            self.snapshot = snapshot
            self.refreshResults()
        }
    }

    private func showEmptyState() {
        results = []
        tableView.reloadData()
        statusLabel.stringValue = NSLocalizedString("Open a folder to search its files",
                                                    comment: "Search for Document empty state")
        statusLabel.isHidden = false
        openFolderButton.isHidden = false
    }

    /// Re-ranks on a short delay. The constant is the toolbar find field's, so
    /// the two search surfaces feel the same under the fingers.
    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshResults() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + DocumentWindowController.findDebounceDelay,
                                      execute: work)
    }

    /// Ranks the current field text off the main actor. A full pass over a
    /// large project costs tens of milliseconds, which would stall typing if
    /// it ran here; a newer query cancels the pass in flight instead of
    /// queueing behind it.
    private func refreshResults() {
        debounce?.cancel()
        debounce = nil
        guard hasSearchQuery, let snapshot else { return }
        let query = queryField.stringValue
        let candidates = snapshot.candidates
        rankTask?.cancel()
        rankTask = Task { [weak self] in
            guard let ranked = try? await Self.rank(query: query, candidates: candidates),
                  let self, !Task.isCancelled else { return }
            self.apply(ranked, for: query)
        }
    }

    @concurrent
    private nonisolated static func rank(query: String,
                                         candidates: [FileSearchMatcher.Candidate]) async throws -> [Int] {
        try FileSearchMatcher.rankCancellably(query: query, candidates: candidates)
    }

    private func apply(_ ranked: [Int], for query: String) {
        // Superseded while the pass was finishing: the field has moved on and
        // a newer ranking is already on its way.
        guard presentation != nil, hasSearchQuery, query == queryField.stringValue else { return }
        results = ranked
        rankedQuery = query
        rankTask = nil
        tableView.reloadData()
        scrollView.isHidden = results.isEmpty
        if !results.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        updateStatus()
        updatePanelSize()
        if let target = pendingActivation {
            pendingActivation = nil
            activateSelection(target: target)
        }
    }

    /// True when the rows on screen were ranked for exactly what is in the
    /// field, with nothing newer scheduled or in flight.
    private var resultsAreCurrent: Bool {
        rankedQuery == queryField.stringValue && debounce == nil && rankTask == nil
    }

    private func updateStatus() {
        openFolderButton.isHidden = true
        if results.isEmpty {
            statusLabel.stringValue = NSLocalizedString("No matching files",
                                                        comment: "Search for Document no results")
            statusLabel.isHidden = false
            return
        }
        if snapshot?.isTruncated == true {
            statusLabel.stringValue = String(
                format: NSLocalizedString("Showing the first %d files in this project",
                                          comment: "Search for Document truncated index"),
                snapshot?.candidates.count ?? 0
            )
            statusLabel.isHidden = false
            return
        }
        statusLabel.isHidden = true
    }

    // MARK: - Selection

    /// How far a page key moves. Read from the table rather than assumed, so
    /// it stays right when the panel is resized or the row height changes.
    private var visibleRowCount: Int {
        max(1, tableView.rows(in: tableView.visibleRect).length - 1)
    }

    private func selectRow(_ row: Int) {
        guard !results.isEmpty else { return }
        let clamped = min(max(row, 0), results.count - 1)
        tableView.selectRowIndexes([clamped], byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    /// Drives the list from the raw key event.
    ///
    /// This runs from `performKeyEquivalent`, which the window offers every
    /// key-down before the first responder sees it. The delegate route below
    /// does the same job, but only while the field editor is active and
    /// forwarding; going through the window as well means navigation does not
    /// depend on that being true. Whichever runs first consumes the key, so
    /// the two cannot both act on one press.
    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.control) else { return false }

        switch event.keyCode {
        case Key.upArrow: moveSelection(by: -1)
        case Key.downArrow: moveSelection(by: 1)
        case Key.home: selectRow(0)
        case Key.end: selectRow(results.count - 1)
        case Key.pageUp: moveSelection(by: -visibleRowCount)
        case Key.pageDown: moveSelection(by: visibleRowCount)
        case Key.escape: closePalette()
        case Key.return, Key.keypadEnter:
            if modifiers.contains(.command) { return activateSelection(target: .newTab) }
            if modifiers.contains(.option) { return activateSelection(target: .newWindow) }
            return activateSelection(target: .currentTab)
        default: return false
        }
        return true
    }

    private enum Key {
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let escape: UInt16 = 53
        static let pageUp: UInt16 = 116
        static let pageDown: UInt16 = 121
        static let home: UInt16 = 115
        static let end: UInt16 = 119
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let next = min(max(tableView.selectedRow + offset, 0), results.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private var selectedURL: URL? {
        let row = tableView.selectedRow
        guard results.indices.contains(row) else { return nil }
        return snapshot?.url(at: results[row])
    }

    /// The keyboard path. Return is often pressed straight after the last
    /// keystroke, before the debounced ranking for it has run; opening the
    /// highlighted row then would open the previous query's top hit. So when
    /// the list is behind the field, flush the ranking now and act on its
    /// result instead. Returns true whenever the key is consumed.
    @discardableResult
    private func activateSelection(target: OpenTarget) -> Bool {
        guard hasSearchQuery else { return true }
        guard resultsAreCurrent else {
            // Before the index has loaded there is nothing to rank yet;
            // `loadIndex` ranks once it arrives and honours this then.
            pendingActivation = target
            if debounce != nil || rankTask == nil {
                refreshResults()
            }
            return true
        }
        return openSelectedRow(target: target)
    }

    /// Dismisses before handing the URL back so a Save/Don't Save sheet can
    /// receive focus if the current document has unsaved edits.
    @discardableResult
    private func openSelectedRow(target: OpenTarget) -> Bool {
        guard resultsAreCurrent, let url = selectedURL else { return false }
        openFile(at: url, target: target)
        return true
    }

    private func openFile(at url: URL, target: OpenTarget) {
        let onOpen = onOpen
        let parent = view.window?.parent
        closePalette()
        parent?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { onOpen?(url, target) }
    }

    /// A mouse activation targets the displayed file, even while a newer query
    /// is pending. Capture its URL before closing cancels the pending ranking.
    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard results.indices.contains(row),
              let url = snapshot?.url(at: results[row]) else { return }
        openFile(at: url, target: .currentTab)
    }

    @objc private func openFolderTapped() {
        let onRequestOpenFolder = onRequestOpenFolder
        closePalette()
        DispatchQueue.main.async { onRequestOpenFolder?() }
    }
}

// MARK: - Key handling

extension FileSearchPanelController: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        // A Return waiting on the old text must not fire on the new one.
        pendingActivation = nil
        debounce?.cancel()
        debounce = nil
        rankTask?.cancel()
        rankTask = nil
        if hasSearchQuery {
            // Keep the published rows and their matching emphasis visible
            // until the new query finishes. apply replaces them together;
            // Keyboard activation waits for the current query; double-clicks
            // open the file explicitly targeted in the displayed results.
            scheduleRefresh()
        } else {
            rankedQuery = nil
            results = []
            tableView.reloadData()
            scrollView.isHidden = true
            statusLabel.isHidden = true
            updatePanelSize()
        }
    }

    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        // A one-line field sends `scroll…`, not `move…`, for Home and End —
        // verified against a live field editor rather than assumed. Both
        // spellings are accepted so neither keyboard layout loses the key.
        case #selector(NSResponder.moveToBeginningOfDocument(_:)),
             #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            selectRow(0)
            return true
        case #selector(NSResponder.moveToEndOfDocument(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)):
            selectRow(results.count - 1)
            return true
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
            moveSelection(by: -visibleRowCount)
            return true
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
            moveSelection(by: visibleRowCount)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            // Option-Return arrives as a line break rather than a newline, so
            // both spellings funnel through the same modifier check.
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.command) { return activateSelection(target: .newTab) }
            if modifiers.contains(.option) { return activateSelection(target: .newWindow) }
            return activateSelection(target: .currentTab)
        case #selector(NSResponder.cancelOperation(_:)):
            // The field would otherwise just clear itself, which is not what
            // Escape means when a palette is up.
            closePalette()
            return true
        default:
            return false
        }
    }
}

// MARK: - Results table

extension FileSearchPanelController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let snapshot, results.indices.contains(row) else { return nil }
        let candidate = snapshot.candidates[results[row]]

        let identifier = NSUserInterfaceItemIdentifier("FileSearchRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileSearchRowView
            ?? FileSearchRowView(identifier: identifier)

        // Ranges for the query these rows were actually ranked for, so the
        // emphasis can never describe an older query than the list does.
        let match = FileSearchMatcher.match(query: rankedQuery ?? "", against: candidate)
        cell.configure(fileName: candidate.fileName,
                       relativePath: candidate.relativePath,
                       projectRoot: projectRoot,
                       nameRanges: match?.nameRanges ?? [],
                       pathRanges: match?.pathRanges ?? [],
                       icon: snapshot.url(at: results[row]).map {
                           NSWorkspace.shared.icon(forFile: $0.path)
                       })
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }
}

/// Draws the selection in the accent colour even though the table is not the
/// first responder.
///
/// The field keeps focus so typing carries on, and an unfocused `NSTableView`
/// normally renders its selection in a muted grey. The arrow keys were moving
/// the selection all along; it just did not look like anything was happening.
private final class EmphasizedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1),
                     xRadius: 13, yRadius: 13).fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set { }
    }
}

/// One result: the file's icon, its name, and where it sits in the project.
private final class FileSearchRowView: NSTableCellView {

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        path.translatesAutoresizingMaskIntoConstraints = false

        name.lineBreakMode = .byTruncatingTail
        path.lineBreakMode = .byTruncatingHead

        addSubview(icon)
        addSubview(name)
        addSubview(path)
        textField = name

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            path.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            path.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(fileName: String,
                   relativePath: String,
                   projectRoot: URL?,
                   nameRanges: [Range<Int>],
                   pathRanges: [Range<Int>],
                   icon iconImage: NSImage?) {
        name.attributedStringValue = Self.emphasising(nameRanges,
                                                      in: fileName,
                                                      base: Self.nameFont,
                                                      emphasis: Self.nameMatchFont,
                                                      color: .labelColor)

        // A slash in the query matches the path, so show the whole path for
        // the emphasis to sit on. Otherwise the name above already is the last
        // component, and repeating it would be noise.
        let subtitle = pathRanges.isEmpty
            ? (relativePath as NSString).deletingLastPathComponent
            : relativePath
        let breadcrumb = NSMutableAttributedString(attributedString: Self.emphasising(
            pathRanges, in: subtitle, base: Self.pathFont,
            emphasis: Self.pathMatchFont, color: .secondaryLabelColor
        ))
        // Replace separators after applying match ranges, preserving Unicode
        // offsets and emphasis while making the hierarchy easier to scan.
        for index in subtitle.indices.reversed() where subtitle[index] == "/" {
            let range = NSRange(index..<subtitle.index(after: index), in: subtitle)
            breadcrumb.replaceCharacters(in: range, with: " › ")
        }
        if let projectRoot {
            let prefix = projectRoot.lastPathComponent + (subtitle.isEmpty ? "" : " › ")
            breadcrumb.insert(NSAttributedString(string: prefix, attributes: [
                .font: Self.pathFont, .foregroundColor: NSColor.secondaryLabelColor
            ]), at: 0)
            path.toolTip = projectRoot.appendingPathComponent(relativePath).path
        } else {
            path.toolTip = relativePath
        }
        path.attributedStringValue = breadcrumb

        iconImage?.size = NSSize(width: 22, height: 22)
        icon.image = iconImage
    }

    /// Bolds the characters the query matched — the thing that makes a fuzzy
    /// result legible, because it shows *why* this file matched what was typed.
    private static func emphasising(_ ranges: [Range<Int>],
                                    in string: String,
                                    base: NSFont,
                                    emphasis: NSFont,
                                    color: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: [.font: base, .foregroundColor: color]
        )
        for range in FileSearchMatcher.nsRanges(ranges, in: string) {
            attributed.addAttribute(.font, value: emphasis, range: range)
        }
        return attributed
    }

    private static let nameFont = NSFont.systemFont(ofSize: 13)
    private static let nameMatchFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    private static let pathFont = NSFont.systemFont(ofSize: 11)
    private static let pathMatchFont = NSFont.systemFont(ofSize: 11, weight: .bold)
}

/// A text field that never draws a focus ring.
///
/// Setting `focusRingType` on the field alone is not enough: that is the
/// `NSView` property, while the ring is drawn by the field's *cell*, which
/// carries a separate `focusRingType` of its own. Both are cleared here, and
/// `drawFocusRingMask()` is overridden as well so nothing can put it back.
///
/// The palette is a panel whose field is focused the moment it opens and never
/// gives focus up, so a ring saying "this is focused" tells the reader nothing
/// and just boxes in the one element that should read as plain text.
private final class PlainQueryField: NSTextField {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        suppressFocusRing()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        suppressFocusRing()
    }

    private func suppressFocusRing() {
        focusRingType = .none
        cell?.focusRingType = .none
    }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    override func drawFocusRingMask() {}

    override var focusRingMaskBounds: NSRect { .zero }

    /// While the field is being edited it is not really the field on screen
    /// but the window's shared field editor, which carries its own ring
    /// setting that nothing above reaches. It is handed over on focus, so
    /// this is where to clear it.
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.focusRingType = .none
            editor.drawsBackground = false
        }
        return accepted
    }
}

/// Offers the palette every key-down before the first responder gets it.
///
/// The window walks this method down the view tree for each key press, which
/// is how a default button answers Return. Handling the palette's keys here
/// covers the ones the field editor would never forward anyway — ⌘Return is
/// resolved as a key equivalent long before the field sees it — and does not
/// rely on the field being mid-edit for the rest.
private final class KeyEquivalentView: NSView {

    override var mouseDownCanMoveWindow: Bool { true }

    var onKey: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}


/// Owns the floating window independently of NSViewController presentation.
/// Every close clears the document's palette reference before another search.
@MainActor
private final class FileSearchPanelPresentation: NSObject, NSWindowDelegate {
    private var panel: FileSearchPanel?
    private weak var presentedController: FileSearchPanelController?
    private var parentCloseObserver: NSObjectProtocol?

    func present(_ viewController: FileSearchPanelController, relativeTo parent: NSWindow) {
        let content = viewController.view
        let panel = FileSearchPanel(contentRect: content.bounds,
                                    styleMask: [.borderless],
                                    backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentViewController = viewController
        panel.delegate = self
        self.panel = panel
        presentedController = viewController

        let savedPosition = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double]
        let savedTopLeft: NSPoint? = savedPosition.flatMap { values in
            guard values.count == 2, values.allSatisfy({ $0.isFinite }) else { return nil }
            return NSPoint(x: values[0], y: values[1])
        }
        let screen = savedTopLeft.flatMap { point in
            NSScreen.screens.first { $0.frame.contains(point) }
        } ?? parent.screen
        let screenFrame = screen?.visibleFrame ?? parent.frame
        let width = min(content.frame.width, screenFrame.width - 32)
        let height = min(content.frame.height, screenFrame.height - 32)
        let desiredX = savedTopLeft?.x ?? (parent.frame.midX - width / 2)
        // Start about a quarter of the way down the document window.
        let desiredTop = savedTopLeft?.y ?? (parent.frame.maxY - parent.frame.height * 0.26)
        let x = min(max(desiredX, screenFrame.minX + 16), screenFrame.maxX - width - 16)
        let y = min(max(desiredTop - height, screenFrame.minY + 16), screenFrame.maxY - height - 16)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        parent.addChildWindow(panel, ordered: .above)
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentedController?.closePalette() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
        }
        parentCloseObserver = nil
        presentedController = nil
        panel?.delegate = nil
        if let panel {
            let parent = panel.parent
            let restoreFocus = panel.isKeyWindow || NSApp.keyWindow == nil
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
            panel.close()
            // Return keyboard focus to the document for its menu shortcuts.
            if restoreFocus { parent?.makeKeyAndOrderFront(nil) }
        }
        panel = nil
    }

    private static let positionKey = "FileSearchPanel.topLeft"

    func windowDidMove(_ notification: Notification) {
        guard let panel, panel.isVisible, !panel.isResizingForResults,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        // Store the search bar's top edge, independent of the result height.
        UserDefaults.standard.set([panel.frame.minX, panel.frame.maxY], forKey: Self.positionKey)
    }

    func windowDidResignKey(_ notification: Notification) {
        presentedController?.closePalette()
    }
}

private final class FileSearchPanel: NSPanel {
    weak var queryField: NSTextField?
    var isResizingForResults = false

    // The shared field editor fills the search field, including its empty
    // trailing space. Intercept that space before it consumes the mouse event.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 1,
           !event.modifierFlags.contains(.shift),
           let field = queryField,
           field.bounds.contains(field.convert(event.locationInWindow, from: nil)),
           let editor = field.currentEditor() as? NSTextView,
           let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            let point = editor.convert(event.locationInWindow, from: nil)
            let textEnd = editor.textContainerOrigin.x + layout.usedRect(for: container).maxX
            if field.stringValue.isEmpty || point.x > textEnd + 6 {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                performDrag(with: event)
                return
            }
        }
        super.sendEvent(event)
    }

    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.16 }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Unoccupied space in the palette moves its window; text and result controls
/// retain their own mouse handling.
private final class DraggablePaletteContent: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
