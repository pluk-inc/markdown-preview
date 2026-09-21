//
//  DocumentWindowController+Sidebar.swift
//  md-preview
//
//  The sidebar toolbar items: the mode picker and the show/hide toggle.
//

import Cocoa

extension DocumentWindowController {
    /// Table of Contents / Project Navigator as a tabbed picker: a click
    /// shows that pane, opening the sidebar if it was hidden. Hiding is the
    /// sidebar toggle's job, at the other end of the sidebar's titlebar area.
    ///
    /// Selection mode follows the sidebar. `.selectOne` draws the grey
    /// selected tint while a pane is on screen, but on macOS 26 it refuses to
    /// show no selection, and `.selectAny` clears but paints the accent color
    /// instead. So the group is `.selectOne` while the sidebar is visible and
    /// `.momentary` while it is hidden.
    /// An AppKit-owned `NSToolbarItemGroup` rather than an
    /// `NSSegmentedControl` in a custom view, for the same reason as the
    /// navigation group — the toolbar keeps window-drag regions only around
    /// items it draws itself.
    func makeSidebarModeItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let outlineLabel = NSLocalizedString("Table of Contents", comment: "Sidebar mode toolbar segment label")
        let filesLabel = NSLocalizedString("Project Navigator", comment: "Sidebar mode toolbar segment label")

        let item = NSToolbarItemGroup(itemIdentifier: .sidebarMode,
                                      images: [sidebarSymbolImage("list.bullet.indent", description: outlineLabel),
                                               sidebarSymbolImage("folder", description: filesLabel)],
                                      selectionMode: .selectOne,
                                      labels: [outlineLabel, filesLabel],
                                      target: self,
                                      action: #selector(sidebarModeGroupAction(_:)))
        item.label = NSLocalizedString("Sidebar Mode", comment: "Sidebar mode toolbar item label")
        item.paletteLabel = item.label
        // Not `isNavigational`: AppKit places navigational items after the
        // sidebar tracking separator, which would move this picker out of
        // the sidebar's titlebar area and into the content area.
        item.autovalidates = false
        // Keep both segments visible instead of collapsing into a single
        // button + overflow menu when the toolbar gets tight.
        item.controlRepresentation = .expanded
        item.subitems.first?.toolTip = outlineLabel
        item.subitems.last?.toolTip = filesLabel
        // Per-subitem actions: on macOS 26 the group has no backing
        // NSSegmentedControl and its selectedIndex does not report the
        // clicked segment, so the group action alone cannot tell them apart.
        // Pre-26 only the group action fires; both paths dedupe per event.
        item.subitems.first?.target = self
        item.subitems.first?.action = #selector(selectOutlineModeFromToolbar(_:))
        item.subitems.last?.target = self
        item.subitems.last?.action = #selector(selectFilesModeFromToolbar(_:))
        // Pre-26 the group is backed by an NSSegmentedControl; on 26 `view`
        // is nil and AppKit draws the subitems itself.
        if let segmented = item.view as? NSSegmentedControl {
            segmented.setToolTip(outlineLabel, forSegment: 0)
            segmented.setToolTip(filesLabel, forSegment: 1)
        }

        if willBeInsertedIntoToolbar {
            sidebarModeItem = item
        }
        applySidebarModeSelection(to: item)
        return item
    }

    /// Show/hide as a plain bordered item, so it can sit at the trailing edge
    /// of the sidebar's titlebar area, opposite the pane picker.
    func makeSidebarToggleItem() -> NSToolbarItem {
        let label = NSLocalizedString("Sidebar", comment: "Sidebar toolbar item label")
        let item = NSToolbarItem(itemIdentifier: .sidebarMenu)
        item.label = label
        item.paletteLabel = NSLocalizedString("Toggle Sidebar", comment: "Sidebar toolbar palette label")
        item.toolTip = NSLocalizedString("Show or hide the sidebar", comment: "Sidebar toolbar item tooltip")
        item.image = sidebarSymbolImage("sidebar.leading", description: label)
        item.isBordered = true
        item.autovalidates = false
        item.target = self
        item.action = #selector(toggleSidebarFromMenu(_:))
        return item
    }

    /// Pre-26 path, where the segmented control has already applied the
    /// click to its selection. Momentary (sidebar hidden) reports the clicked
    /// segment directly. In `.selectOne` the newly selected segment is the
    /// one that was clicked; with no change, the click landed on the
    /// selected one, which is already on screen.
    @objc private func sidebarModeGroupAction(_ sender: NSToolbarItemGroup) {
        guard claimSidebarToolbarEvent() else { return }
        let clicked: Int?
        if sender.selectionMode == .momentary {
            clicked = sender.selectedIndex
        } else {
            let expected = expectedSidebarModeSelection()
            let actual = expected.indices.map { sender.isSelected(at: $0) }
            clicked = actual.indices.first { actual[$0] && !expected[$0] }
                ?? expected.firstIndex(of: true)
        }
        guard let clicked, (0...1).contains(clicked) else { return }
        showSidebarPane(clicked == 0 ? .outline : .files)
    }

    @objc private func selectOutlineModeFromToolbar(_ sender: Any?) {
        guard claimSidebarToolbarEvent() else { return }
        showSidebarPane(.outline)
    }

    @objc private func selectFilesModeFromToolbar(_ sender: Any?) {
        guard claimSidebarToolbarEvent() else { return }
        showSidebarPane(.files)
    }

    private func showSidebarPane(_ mode: SidebarViewController.Mode) {
        switch mode {
        case .outline: selectOutlineMode(nil)
        case .files: selectFilesMode(nil)
        }
        // The group applies the clicked segment as its selection after the
        // action returns; re-apply the model's state once AppKit is done.
        DispatchQueue.main.async { [weak self] in
            self?.syncSidebarToolbarState()
        }
    }

    /// One click may reach both a subitem action and the group action. The
    /// first handler for a given event wins; the other is a no-op. Keyed on
    /// the timestamp: synthetic events can all share event number 0.
    private func claimSidebarToolbarEvent() -> Bool {
        guard let timestamp = NSApp.currentEvent?.timestamp else { return true }
        guard timestamp != sidebarToolbarHandledEventTimestamp else { return false }
        sidebarToolbarHandledEventTimestamp = timestamp
        return true
    }

    /// Mirrors the split view into the mode picker: the visible pane is
    /// selected, and nothing is selected while the sidebar is hidden.
    func syncSidebarToolbarState() {
        if let sidebarModeItem {
            applySidebarModeSelection(to: sidebarModeItem)
        }
    }

    private func applySidebarModeSelection(to item: NSToolbarItemGroup) {
        let expected = expectedSidebarModeSelection()
        item.selectionMode = expected.contains(true) ? .selectOne : .momentary
        for (index, selected) in expected.enumerated() {
            item.setSelected(selected, at: index)
        }
    }

    /// Segment selection the model calls for: [Table of Contents, Project
    /// Navigator]. Neither is selected while the sidebar is hidden.
    private func expectedSidebarModeSelection() -> [Bool] {
        let state = currentSidebarMenuState()
        guard state.sidebarVisible else { return [false, false] }
        return [state.mode == .outline, state.mode == .files]
    }

    var sidebarMenuState: (sidebarVisible: Bool, mode: SidebarViewController.Mode) {
        currentSidebarMenuState()
    }

    func applyReaderLayoutSetting() {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .applyReaderLayout()
    }

    func reloadPreviewForSettingChange() {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .reloadPreviewForSettingChange()
    }

    func applyTextSizeSetting() {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .applyTextSizeSetting()
    }

    private func currentSidebarMenuState() -> (sidebarVisible: Bool, mode: SidebarViewController.Mode) {
        let split = documentWindow.contentViewController as? MainSplitViewController
        let sidebarVisible = split?.isSidebarVisible ?? false
        let mode = split?.sidebarMode ?? .outline
        return (sidebarVisible, mode)
    }

    func prepareSidebarForUntitledDocument() {
        mainSplit?.hideSidebar()
        syncSidebarToolbarState()
    }

    private func sidebarSymbolImage(_ name: String, description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        image.isTemplate = true
        return image
    }

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        (documentWindow.contentViewController as? MainSplitViewController)?.toggleSidebar()
        syncSidebarToolbarState()
    }

    @objc func hideSidebarFromMenu(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController,
              split.isSidebarVisible else { return }
        split.toggleSidebar()
        syncSidebarToolbarState()
    }

    @objc func selectOutlineMode(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.outline)
        split.showSidebar()
        syncSidebarToolbarState()
    }

    @objc func selectFilesMode(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.files)
        split.showSidebar()
        syncSidebarToolbarState()
    }
}
