//
//  DocumentWindowController+Sidebar.swift
//  md-preview
//
//  The sidebar toolbar item and its mode menu.
//

import Cocoa

extension DocumentWindowController {
    func makeSidebarMenuItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        // An AppKit-owned item rather than an NSPopUpButton in a custom view:
        // the toolbar keeps its own drag regions only for items it draws
        // itself, so a control view here costs the window its drag surface.
        //
        // The two objections to NSMenuToolbarItem both come from configuring
        // it as a split button. Leaving `target`/`action` unset makes a click
        // anywhere on the item open the menu, and setting `image` explicitly
        // means no menu entry is promoted out of the dropdown to act as the
        // face — so this behaves as the Preview-style pulldown it replaces.
        let item = NSMenuToolbarItem(itemIdentifier: .sidebarMenu)
        item.label = NSLocalizedString("Sidebar", comment: "Sidebar toolbar item label")
        item.paletteLabel = NSLocalizedString("Sidebar", comment: "Sidebar toolbar palette label")
        item.toolTip = NSLocalizedString("Sidebar options", comment: "Sidebar toolbar item tooltip")
        item.image = sidebarFaceImage()
        item.showsIndicator = true

        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier("SidebarMenu")
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildSidebarMenu(menu)
        item.menu = menu

        if willBeInsertedIntoToolbar {
            sidebarMenu = menu
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

        // NSMenuToolbarItem reserves the first menu item for its button face,
        // even when the toolbar item supplies its own image. Keep that slot
        // empty so every real command appears in the dropdown.
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))

        let hide = NSMenuItem(title: NSLocalizedString("Hide Sidebar", comment: "Sidebar dropdown item"),
                              action: #selector(hideSidebarFromMenu(_:)),
                              keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let outline = NSMenuItem(title: NSLocalizedString("Table of Contents", comment: "Sidebar dropdown item"),
                                 action: #selector(selectOutlineMode(_:)),
                                 keyEquivalent: "")
        outline.target = self
        menu.addItem(outline)

        let files = NSMenuItem(title: NSLocalizedString("Project Navigator", comment: "Sidebar dropdown item"),
                               action: #selector(selectFilesMode(_:)),
                               keyEquivalent: "")
        files.target = self
        menu.addItem(files)
        syncSidebarMenuState(for: menu)
    }

    func syncSidebarMenuState() {
        if let sidebarMenu {
            syncSidebarMenuState(for: sidebarMenu)
        }
    }

    func syncSidebarMenuState(for menu: NSMenu) {
        let state = currentSidebarMenuState()
        menu.items.first { $0.action == #selector(hideSidebarFromMenu(_:)) }?.state = state.sidebarVisible ? .off : .on
        menu.items.first { $0.action == #selector(selectOutlineMode(_:)) }?.state = (state.sidebarVisible && state.mode == .outline) ? .on : .off
        menu.items.first { $0.action == #selector(selectFilesMode(_:)) }?.state = (state.sidebarVisible && state.mode == .files) ? .on : .off
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
        syncSidebarMenuState()
    }

    private func sidebarFaceImage() -> NSImage {
        let image = NSImage(systemSymbolName: "sidebar.leading",
                            accessibilityDescription: NSLocalizedString("Sidebar", comment: "Sidebar toolbar image")) ?? NSImage()
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
}
