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

    private let queryField = PlainQueryField()
    private let fieldSeparator = HairlineSeparator()
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

        // A large, unbezelled field with a hairline under it, the way Xcode's
        // Open Quickly presents it: in a palette the field is the whole point,
        // so it reads as the subject rather than as one control among several.
        queryField.translatesAutoresizingMaskIntoConstraints = false
        queryField.placeholderString = NSLocalizedString("Search files by name",
                                                         comment: "Search for Document field placeholder")
        queryField.delegate = self
        queryField.font = .systemFont(ofSize: 19)
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.lineBreakMode = .byTruncatingTail

        fieldSeparator.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.style = .inset
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

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.textColor = .tertiaryLabelColor
        // A keyboard-only affordance nobody mentions is undiscoverable.
        hintLabel.stringValue = NSLocalizedString("↑↓ browse · ↩ open · ⌘↩ new tab · ⌥↩ new window",
                                                  comment: "Search for Document keyboard hint")

        openFolderButton.translatesAutoresizingMaskIntoConstraints = false
        openFolderButton.bezelStyle = .rounded
        openFolderButton.title = NSLocalizedString("Open Folder…", comment: "Search for Document empty state button")
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderTapped)
        openFolderButton.isHidden = true

        for subview in [queryField, fieldSeparator, scrollView, statusLabel, hintLabel, openFolderButton] {
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            queryField.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            queryField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            queryField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),

            fieldSeparator.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 14),
            fieldSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fieldSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldSeparator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: fieldSeparator.bottomAnchor, constant: 4),
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
        view.window?.makeFirstResponder(queryField)
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
        guard query == queryField.stringValue else { return }
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
    /// it stays right when the sheet is resized or the row height changes.
    private var visibleRowCount: Int {
        max(1, tableView.rows(in: tableView.visibleRect).length - 1)
    }

    private func selectRow(_ row: Int) {
        guard !results.isEmpty else { return }
        let clamped = min(max(row, 0), results.count - 1)
        tableView.selectRowIndexes([clamped], byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
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

extension FileSearchPanelController: NSTextFieldDelegate {

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
        // In a one-line field these would only shunt the caret to either end
        // of the text, which is never what someone driving a result list
        // means by Home and End.
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            selectRow(0)
            return true
        case #selector(NSResponder.moveToEndOfDocument(_:)):
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

        // Ranges for the query these rows were actually ranked for, so the
        // emphasis can never describe an older query than the list does.
        let match = FileSearchMatcher.match(query: rankedQuery ?? "", against: candidate)
        cell.configure(fileName: candidate.fileName,
                       relativePath: candidate.relativePath,
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
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
        path.attributedStringValue = Self.emphasising(pathRanges.isEmpty ? [] : pathRanges,
                                                      in: subtitle,
                                                      base: Self.pathFont,
                                                      emphasis: Self.pathMatchFont,
                                                      color: .secondaryLabelColor)

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
/// The palette is a sheet whose field is focused the moment it opens and never
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
