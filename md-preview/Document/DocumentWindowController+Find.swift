//
//  DocumentWindowController+Find.swift
//  md-preview
//
//  The search toolbar item and the find bar.
//

import Cocoa

extension DocumentWindowController {
    func makeSearchItem() -> NSToolbarItem {
        let item = NSSearchToolbarItem(itemIdentifier: .search)
        let searchInDocument = NSLocalizedString(
            "Search in Document",
            comment: "Toolbar search field tooltip and placeholder"
        )
        item.label = NSLocalizedString("Search", comment: "Toolbar search item label")
        item.toolTip = searchInDocument
        item.preferredWidthForSearchField = 320
        item.searchField.placeholderString = searchInDocument
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
        guard let overlay = findBarOverlay, overlay.isHidden == visible else { return }
        overlay.isHidden = !visible
        // The editor pads its page below every visible overlay.
        mainSplit?.findOverlayVisibilityChanged()
    }

    /// A content overlay like the formatting bar, not a titlebar accessory:
    /// AppKit pins the native tab bar below every accessory, so an
    /// accessory find bar sat above the tabs and shoved them down on every
    /// appearance. The overlay never reflows the layout — see
    /// DocumentWindowController.editBar.
    func installFindBar() {
        let bar = FindBar(
            frame: NSRect(x: 0, y: 0, width: 600, height: FindBar.preferredHeight)
        )
        bar.onPrevious = { [weak self] in self?.findFromToolbar(backwards: true) }
        bar.onNext = { [weak self] in self?.findFromToolbar(backwards: false) }
        bar.onDone = { [weak self] in self?.dismissFindBar() }
        bar.onModeChanged = { [weak self] mode in self?.searchModeDidChange(mode) }
        self.findBar = bar

        let container = EditAccessoryContainerView()
        // The find bar shows over the preview, whose backdrop follows the
        // window background, not the editor color.
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: FindBar.preferredHeight),
        ])
        let hairline: NSView
        if #available(macOS 27.0, *) {
            hairline = SearchHairlineSeparator()
        } else {
            let separator = NSBox()
            separator.boxType = .separator
            hairline = separator
        }
        hairline.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 27.0, *) {
            // The native edge covers the outer chrome boundary. A custom
            // divider separates search from the formatting row in edit mode.
            hairline.isHidden = true
        }
        container.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        findBarHairline = hairline
        container.isHidden = true
        mainSplit?.installFindOverlay(container)
        findBarOverlay = container
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
        guard findBarOverlay?.isHidden == false,
              let query = searchField?.stringValue, !query.isEmpty else { return }
        runFind(query: query)
    }

    private func focusToolbarSearch() {
        guard let searchField else { return }
        documentWindow.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }
}

/// A single device pixel filled with the unmodified system separator color.
private final class SearchHairlineSeparator: NSView {
    private var pixelHeight: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        pixelHeight = heightAnchor.constraint(equalToConstant: 1)
        pixelHeight.isActive = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updatePixelHeight() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        pixelHeight.constant = 1 / scale
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePixelHeight()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePixelHeight()
    }
}
