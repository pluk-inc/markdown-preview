//
//  DocumentWindowController+Sidebar.swift
//  md-preview
//
//  Sidebar commands and the show/hide toolbar item.
//

import Cocoa

extension DocumentWindowController {
    /// Show/hide as a plain bordered toolbar item.
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
    }

    private func sidebarSymbolImage(_ name: String, description: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        image.isTemplate = true
        return image
    }

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        (documentWindow.contentViewController as? MainSplitViewController)?.toggleSidebar()
    }

    @objc func hideSidebarFromMenu(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController,
              split.isSidebarVisible else { return }
        split.toggleSidebar()
    }

    @objc func selectOutlineMode(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.outline)
        split.showSidebar()
    }

    @objc func selectFilesMode(_ sender: Any?) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        split.setSidebarMode(.files)
        split.showSidebar()
    }
}
