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
        guard let accessory = findBarAccessory, accessory.isHidden == visible else { return }
        accessory.isHidden = !visible
        if #available(macOS 26.1, *) {
            // Visible bar always gets the hard backdrop; hidden, the
            // preference must not leak a backdrop over a themed titlebar.
            accessory.preferredScrollEdgeEffectStyle =
                visible || !activeSchemeThemed ? .hard : .automatic
        }
    }

    func installFindBar() {
        let bar = FindBar(
            frame: NSRect(x: 0, y: 0, width: 600, height: FindBar.preferredHeight)
        )
        bar.autoresizingMask = [.width]
        bar.onPrevious = { [weak self] in self?.findFromToolbar(backwards: true) }
        bar.onNext = { [weak self] in self?.findFromToolbar(backwards: false) }
        bar.onDone = { [weak self] in self?.dismissFindBar() }
        bar.onModeChanged = { [weak self] mode in self?.searchModeDidChange(mode) }
        self.findBar = bar
        // No .hard here: a hidden accessory's scroll-edge preference still
        // applies, painting an opaque backdrop over a themed window background.
        // setFindBarVisible flips it while the bar is actually shown.
        self.findBarAccessory = addBottomTitlebarAccessory(bar)
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
}
