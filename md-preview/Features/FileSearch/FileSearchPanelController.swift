//
//  FileSearchPanelController.swift
//  md-preview
//
//  The Search for Document palette: type part of a file name, pick a result,
//  open it. Presented as a sheet rather than a floating panel because each
//  document window has its own project root, so one app-wide palette would be
//  wrong.
//

import Cocoa

@MainActor
final class FileSearchPanelController: NSViewController {

    enum OpenTarget {
        case currentTab
        case newTab
        case newWindow
    }

    /// Called with the chosen file once the sheet has gone. The controller
    /// dismisses itself first — see `activateSelection`.
    var onOpen: ((URL, OpenTarget) -> Void)?
    /// Called when the reader asks for a folder from the empty state.
    var onRequestOpenFolder: (() -> Void)?

    private let projectRoot: URL?
    private let index: ProjectFileIndex

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let openFolderButton = NSButton()

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
        // controller's root view frame, and a sheet takes its size from it.
        let container = KeyEquivalentView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        container.onCommandReturn = { [weak self] in self?.activateSelection(target: .newTab) ?? false }
        container.onOptionReturn = { [weak self] in self?.activateSelection(target: .newWindow) ?? false }
        view = container

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = NSLocalizedString("Search files by name",
                                                          comment: "Search for Document field placeholder")
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = 38
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

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.textColor = .tertiaryLabelColor
        // A keyboard-only affordance nobody mentions is undiscoverable.
        hintLabel.stringValue = NSLocalizedString("↩ open · ⌘↩ new tab · ⌥↩ new window",
                                                  comment: "Search for Document keyboard hint")

        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        openFolderButton.bezelStyle = .rounded
        openFolderButton.title = NSLocalizedString("Open Folder…", comment: "Search for Document empty state button")
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderTapped)
        openFolderButton.isHidden = true

        for subview in [searchField, scrollView, statusLabel, hintLabel, openFolderButton] {
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            statusLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            openFolderButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            openFolderButton.centerXAnchor.constraint(equalTo: statusLabel.centerXAnchor),

            hintLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
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

    // MARK: - Index

    private func loadIndex() {
        guard let projectRoot else {
            showEmptyState()
            return
        }
        Task { [weak self, index] in
            let snapshot = await index.snapshot(for: projectRoot)
            guard let self else { return }
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
        guard let snapshot else { return }
        let query = searchField.stringValue
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
        guard query == searchField.stringValue else { return }
        results = ranked
        rankedQuery = query
        rankTask = nil
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        updateStatus()
        if let target = pendingActivation {
            pendingActivation = nil
            activateSelection(target: target)
        }
    }

    /// True when the rows on screen were ranked for exactly what is in the
    /// field, with nothing newer scheduled or in flight.
    private var resultsAreCurrent: Bool {
        rankedQuery == searchField.stringValue && debounce == nil && rankTask == nil
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

    /// Dismisses *before* handing the URL back. `present(url:)` can raise a
    /// Save/Don't Save sheet, and AppKit will not stack a second sheet on a
    /// window that already has one — opening from edit mode is a silent no-op
    /// if the palette is still up.
    @discardableResult
    private func openSelectedRow(target: OpenTarget) -> Bool {
        guard let url = selectedURL else { return false }
        let onOpen = onOpen
        dismiss(self)
        DispatchQueue.main.async { onOpen?(url, target) }
        return true
    }

    /// A double-click names a row the reader can see, so it opens that row
    /// even if a newer ranking is on its way.
    @objc private func rowDoubleClicked() {
        openSelectedRow(target: .currentTab)
    }

    @objc private func openFolderTapped() {
        let onRequestOpenFolder = onRequestOpenFolder
        dismiss(self)
        DispatchQueue.main.async { onRequestOpenFolder?() }
    }
}

// MARK: - Key handling

extension FileSearchPanelController: NSSearchFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        // A Return waiting on the old text must not fire on the new one.
        pendingActivation = nil
        scheduleRefresh()
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
            dismiss(self)
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

        cell.configure(fileName: candidate.fileName,
                       relativePath: candidate.relativePath,
                       icon: snapshot.url(at: results[row]).map {
                           NSWorkspace.shared.icon(forFile: $0.path)
                       })
        return cell
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

        name.font = .preferredFont(forTextStyle: .body)
        name.lineBreakMode = .byTruncatingTail
        path.font = .preferredFont(forTextStyle: .caption1)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingHead

        addSubview(icon)
        addSubview(name)
        addSubview(path)
        textField = name

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

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

    func configure(fileName: String, relativePath: String, icon iconImage: NSImage?) {
        name.stringValue = fileName
        // The name is already the last component; showing it twice is noise.
        let parent = (relativePath as NSString).deletingLastPathComponent
        path.stringValue = parent.isEmpty ? "" : parent
        iconImage?.size = NSSize(width: 20, height: 20)
        icon.image = iconImage
    }
}

/// Catches the Command-modified Return that never reaches the search field:
/// AppKit routes ⌘-combinations through `performKeyEquivalent(_:)` first.
private final class KeyEquivalentView: NSView {

    var onCommandReturn: (() -> Bool)?
    var onOptionReturn: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) { return onCommandReturn?() ?? false }
        if modifiers.contains(.option) { return onOptionReturn?() ?? false }
        return super.performKeyEquivalent(with: event)
    }
}
