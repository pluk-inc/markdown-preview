//
//  DocumentWindowController+Sidebar.swift
//  md-preview
//
//  The sidebar toolbar item and its mode menu.
//

import Cocoa

extension DocumentWindowController {
    func makeSidebarMenuItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .sidebarMenu)
        item.label = NSLocalizedString("Sidebar", comment: "Sidebar toolbar item label")
        item.paletteLabel = NSLocalizedString("Sidebar", comment: "Sidebar toolbar palette label")
        item.toolTip = NSLocalizedString("Sidebar options", comment: "Sidebar toolbar item tooltip")

        // NSPopUpButton (pull-down) so a single click anywhere on the button
        // opens the menu and the chevron renders natively. NSMenuToolbarItem
        // either splits the click (icon vs chevron) or auto-promotes the first
        // item out of the dropdown — neither matches the Preview-style pulldown.
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.bezelStyle = .toolbar
        popup.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.identifier = NSUserInterfaceItemIdentifier("SidebarMenu")
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildSidebarMenu(menu)
        popup.menu = menu
        popup.sizeToFit()

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])

        item.view = container
        if willBeInsertedIntoToolbar {
            sidebarMenu = menu
            sidebarPopUpButton = popup
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

        // Pull-down NSPopUpButton uses the first item as the always-visible
        // button face (showing only the icon thanks to imagePosition). The
        // dropdown shows items 2+, so the button face is reserved here.
        let face = NSMenuItem()
        face.image = sidebarFaceImage()
        menu.addItem(face)

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
