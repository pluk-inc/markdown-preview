//
//  DocumentWindowController+Toolbar.swift
//  md-preview
//
//  Toolbar construction: the NSToolbarDelegate methods and the item factories.
//

import Cocoa
import SwiftUI

extension NSToolbarItem.Identifier {
    static let openActions = NSToolbarItem.Identifier("OpenActions")
    static let openWith = NSToolbarItem.Identifier("OpenWith")
    static let openInLLM = NSToolbarItem.Identifier("OpenInLLM")
    static let inspector = NSToolbarItem.Identifier("Inspector")
    static let share = NSToolbarItem.Identifier("Share")
    static let search = NSToolbarItem.Identifier("Search")
    static let sidebarMenu = NSToolbarItem.Identifier("SidebarMenu")
    static let printDocument = NSToolbarItem.Identifier("PrintDocument")
    static let exportDocument = NSToolbarItem.Identifier("ExportDocument")
    static let exportPDF = NSToolbarItem.Identifier("ExportPDF")
    static let copyMarkdown = NSToolbarItem.Identifier("CopyMarkdown")
    static let zoom = NSToolbarItem.Identifier("Zoom")
    static let themesAndSettings = NSToolbarItem.Identifier("ThemesAndSettings")
    static let editDocument = NSToolbarItem.Identifier("EditDocument")
    static let navigation = NSToolbarItem.Identifier("Navigation")
    static let alwaysOnTop = NSToolbarItem.Identifier("AlwaysOnTop")
}

private extension Array where Element == NSToolbarItem.Identifier {
    mutating func insertAfterOpenActions(_ identifier: NSToolbarItem.Identifier) {
        guard let index = firstIndex(of: .openActions) else {
            append(identifier)
            return
        }
        insert(identifier, at: index + 1)
    }
}

extension DocumentWindowController {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .sidebarMenu,
            .sidebarTrackingSeparator,
            .navigation,
            .flexibleSpace,
            .openActions,
            .space,
            .themesAndSettings,
            .space,
            .inspector,
            .share,
            .editDocument,
            .search
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .sidebarMenu,
            .sidebarTrackingSeparator,
            .navigation,
            .flexibleSpace,
            .space,
            .openActions,
            .openWith,
            .editDocument,
            .inspector,
            .share,
            .search,
            .printDocument,
            .exportPDF,
            .exportDocument,
            .copyMarkdown,
            .themesAndSettings,
            .zoom,
            .alwaysOnTop
        ]
        if hasLLMTargetsAvailable {
            identifiers.insertAfterOpenActions(.openInLLM)
        }
        return identifiers
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarMenu: return makeSidebarMenuItem(willBeInsertedIntoToolbar: flag)
        case .navigation: return makeNavigationItem(willBeInsertedIntoToolbar: flag)
        case .openActions: return makeOpenActionsItem()
        case .openWith: return makeOpenWithItem()
        case .openInLLM:
            guard hasLLMTargetsAvailable else { return nil }
            return makeOpenInLLMItem()
        case .editDocument: return makeEditItem(willBeInsertedIntoToolbar: flag)
        case .inspector: return makeInspectorItem(willBeInsertedIntoToolbar: flag)
        case .alwaysOnTop: return makeAlwaysOnTopItem(willBeInsertedIntoToolbar: flag)
        case .share: return makeShareItem()
        case .search: return makeSearchItem()
        case .printDocument: return makePrintItem()
        case .exportPDF: return makeExportPDFItem()
        case .exportDocument: return makeExportItem()
        case .copyMarkdown: return makeCopyItem()
        case .zoom: return makeZoomItem()
        case .themesAndSettings: return makeThemesAndSettingsItem()
        default: return nil
        }
    }

    /// Back and forward as an AppKit-owned group rather than an
    /// `NSSegmentedControl` in a custom view. A toolbar only keeps window-drag
    /// regions around items it draws itself, so hosting a control here is what
    /// cost the toolbar its drag surface in the first place.
    private func makeNavigationItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let back = NSLocalizedString("Back", comment: "Navigation toolbar back button")
        let forward = NSLocalizedString("Forward", comment: "Navigation toolbar forward button")
        let backImage = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back) ?? NSImage()
        let forwardImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward) ?? NSImage()

        let item = NSToolbarItemGroup(itemIdentifier: .navigation,
                                      images: [backImage, forwardImage],
                                      selectionMode: .momentary,
                                      labels: [back, forward],
                                      target: self,
                                      action: #selector(navigateHistory(_:)))
        item.label = NSLocalizedString("Navigation", comment: "Navigation toolbar item label")
        item.paletteLabel = NSLocalizedString("Back and Forward", comment: "Navigation toolbar palette label")
        item.isNavigational = true
        item.autovalidates = false
        item.subitems.first?.toolTip = back
        item.subitems.last?.toolTip = forward

        if willBeInsertedIntoToolbar {
            navigationItem = item
        }
        applyNavigationState(to: item)
        return item
    }

    @objc private func navigateHistory(_ sender: NSToolbarItemGroup) {
        switch sender.selectedIndex {
        case 0:
            guard let entry = backHistory.last else { return }
            present(url: entry.url, intent: .back)
        case 1:
            guard let entry = forwardHistory.last else { return }
            present(url: entry.url, intent: .forward)
        default:
            break
        }
    }

    func updateNavigationItem() {
        guard let navigationItem else { return }
        applyNavigationState(to: navigationItem)
    }

    private func applyNavigationState(to item: NSToolbarItemGroup) {
        let hasHistory = !backHistory.isEmpty || !forwardHistory.isEmpty
        item.isHidden = !hasHistory
        item.isEnabled = hasHistory
        item.subitems.first?.isEnabled = !backHistory.isEmpty
        item.subitems.last?.isEnabled = !forwardHistory.isEmpty
    }

    /// A toggle as a plain NSButton hosted in a regular NSToolbarItem. On
    /// macOS 26 AppKit merges adjacent button-type controls onto one piece
    /// of glass but always gives an NSToolbarItemGroup its own, so a toggle
    /// built as a single-item group can never share glass with its
    /// neighbors. Built this way the toggles merge natively and stay
    /// individually movable in the customize palette.
    func makeToggleButtonItem(identifier: NSToolbarItem.Identifier,
                              image: NSImage,
                              label: String,
                              action: Selector) -> (item: NSToolbarItem, button: NSButton) {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let button = NSButton(image: image, target: self, action: action)
        button.setButtonType(.pushOnPushOff)
        button.isBordered = true
        item.view = button
        item.label = label
        item.paletteLabel = label
        return (item, button)
    }

    private func makeInspectorItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let (item, button) = makeToggleButtonItem(
            identifier: .inspector,
            image: inspectorImage(),
            label: NSLocalizedString("Inspector", comment: "Inspector toolbar item label"),
            action: #selector(toggleInspectorAction(_:))
        )
        item.paletteLabel = NSLocalizedString("Get Info", comment: "Inspector toolbar palette label")
        item.toolTip = NSLocalizedString("Show the inspector", comment: "Inspector toolbar item tooltip")
        button.toolTip = item.toolTip

        if willBeInsertedIntoToolbar {
            inspectorButton = button
            refreshInspectorToggleItem()
        } else {
            button.state = isInspectorToggleSelected ? .on : .off
        }
        return item
    }

    private func makeAlwaysOnTopItem(willBeInsertedIntoToolbar: Bool) -> NSToolbarItem {
        let (item, button) = makeToggleButtonItem(
            identifier: .alwaysOnTop,
            image: alwaysOnTopImage(),
            label: NSLocalizedString("Always on Top", comment: "Always on Top toolbar item label"),
            action: #selector(toggleAlwaysOnTop(_:))
        )
        item.toolTip = NSLocalizedString("Keep Markdown Preview windows in front of other apps",
                                         comment: "Always on Top toolbar item tooltip")
        button.toolTip = item.toolTip
        button.state = isAlwaysOnTop ? .on : .off

        if willBeInsertedIntoToolbar {
            alwaysOnTopButton = button
        }
        return item
    }

    private func alwaysOnTopImage() -> NSImage {
        let image = NSImage(systemSymbolName: "pin",
                            accessibilityDescription: NSLocalizedString("Always on Top", comment: "Always on Top toolbar image")) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private func makeShareItem() -> NSToolbarItem {
        let item = NSSharingServicePickerToolbarItem(itemIdentifier: .share)
        item.label = NSLocalizedString("Share", comment: "Share toolbar item label")
        item.paletteLabel = NSLocalizedString("Share", comment: "Share toolbar palette label")
        item.toolTip = NSLocalizedString("Share document", comment: "Share toolbar item tooltip")
        item.delegate = self
        return item
    }

    private func makePrintItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .printDocument)
        let print = NSLocalizedString("Print", comment: "Print toolbar item label")
        item.label = print
        item.paletteLabel = print
        item.toolTip = NSLocalizedString("Print document", comment: "Print toolbar item tooltip")
        item.image = NSImage(systemSymbolName: "printer",
                             accessibilityDescription: print)
        item.isBordered = true
        item.action = #selector(MainSplitViewController.printMarkdown(_:))
        return item
    }

    private func makeExportPDFItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .exportPDF)
        let label = NSLocalizedString(
            "Export PDF", comment: "Export as PDF toolbar item label")
        item.label = label
        item.paletteLabel = label
        item.toolTip = NSLocalizedString(
            "Export document as PDF", comment: "Export as PDF toolbar item tooltip")
        item.image = NSImage(systemSymbolName: "arrow.up.document",
                             accessibilityDescription: label)
        item.isBordered = true
        item.action = #selector(MainSplitViewController.exportMarkdownAsPDF(_:))
        return item
    }

    private func makeExportItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .exportDocument)
        let label = NSLocalizedString(
            "Export", comment: "Export toolbar item label")
        item.label = label
        item.paletteLabel = label
        item.toolTip = NSLocalizedString(
            "Export document", comment: "Export toolbar item tooltip")
        item.image = NSImage(systemSymbolName: "document.badge.arrow.up",
                             accessibilityDescription: label)
        item.isBordered = true
        item.action = #selector(MainSplitViewController.exportMarkdownDocument(_:))
        return item
    }

    private func makeCopyItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .copyMarkdown)
        let copy = NSLocalizedString("Copy", comment: "Copy toolbar item label")
        item.label = copy
        item.paletteLabel = copy
        item.toolTip = NSLocalizedString("Copy Markdown source to clipboard", comment: "Copy toolbar item tooltip")
        item.image = copyIdleImage()
        item.isBordered = true
        item.target = self
        item.action = #selector(copyMarkdownAction(_:))
        copyItem = item
        return item
    }

    @objc private func copyMarkdownAction(_ sender: Any?) {
        guard let markdown = currentMarkdown, !markdown.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        flashCopyFeedback()
    }

    private static let copyFeedbackDuration: TimeInterval = 1.2

    private func flashCopyFeedback() {
        guard let item = copyItem else { return }
        copyFeedbackWork?.cancel()
        item.image = copyConfirmedImage()
        let work = DispatchWorkItem { [weak self] in
            self?.copyItem?.image = self?.copyIdleImage()
        }
        copyFeedbackWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.copyFeedbackDuration, execute: work
        )
    }

    private func copyIdleImage() -> NSImage? {
        NSImage(systemSymbolName: "document.on.document",
                accessibilityDescription: NSLocalizedString("Copy", comment: "Copy toolbar image"))
    }

    private func copyConfirmedImage() -> NSImage? {
        NSImage(systemSymbolName: "checkmark",
                accessibilityDescription: NSLocalizedString("Copied", comment: "Copy confirmation image"))
    }

    private func makeZoomItem() -> NSToolbarItemGroup {
        let zoomOut = NSLocalizedString("Zoom Out", comment: "Zoom toolbar button")
        let zoomIn = NSLocalizedString("Zoom In", comment: "Zoom toolbar button")
        let zoom = NSLocalizedString("Zoom", comment: "Zoom toolbar item label")
        let smaller = NSImage(systemSymbolName: "textformat.size.smaller",
                              accessibilityDescription: zoomOut) ?? NSImage()
        let larger = NSImage(systemSymbolName: "textformat.size.larger",
                             accessibilityDescription: zoomIn) ?? NSImage()
        let group = NSToolbarItemGroup(
            itemIdentifier: .zoom,
            images: [smaller, larger],
            selectionMode: .momentary,
            labels: [zoomOut, zoomIn],
            target: self,
            action: #selector(zoomSegmentAction(_:))
        )
        group.label = zoom
        group.paletteLabel = zoom
        group.toolTip = zoom
        for (subitem, tooltip) in zip(group.subitems, [zoomOut, zoomIn]) {
            subitem.toolTip = tooltip
        }
        // .expanded keeps the two-segment "A A" pair visible like Books / Reader,
        // instead of collapsing into a single button + menu when space is tight.
        group.controlRepresentation = .expanded
        if let segmented = group.view as? NSSegmentedControl {
            segmented.setToolTip(zoomOut, forSegment: 0)
            segmented.setToolTip(zoomIn, forSegment: 1)
        }
        return group
    }

    @objc private func zoomSegmentAction(_ sender: NSToolbarItemGroup) {
        guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
        switch sender.selectedIndex {
        case 0: split.zoomOutDocument(sender)
        case 1: split.zoomInDocument(sender)
        default: break
        }
    }

    /// The "aA" button that replaced the zoom pair in the default set. It
    /// opens a popover with text size, appearance, and the theme preset
    /// gallery; Customize inside it leads to the Appearance settings pane.
    /// A plain NSButton for the same reason as makeToggleButtonItem: on
    /// macOS 26 it shares glass with its neighbors.
    private func makeThemesAndSettingsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .themesAndSettings)
        let label = NSLocalizedString("Themes & Settings",
                                      comment: "Themes & Settings toolbar item label")
        let image = NSImage(systemSymbolName: "textformat.size",
                            accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self,
                              action: #selector(showThemesPopover(_:)))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = true
        button.toolTip = NSLocalizedString("Text size, appearance, and themes",
                                           comment: "Themes & Settings toolbar item tooltip")
        item.view = button
        item.label = label
        item.paletteLabel = label
        item.toolTip = button.toolTip
        return item
    }

    @objc private func showThemesPopover(_ sender: NSButton) {
        if let popover = themesPopover, popover.isShown {
            popover.close()
            return
        }
        let host = NSHostingController(rootView: ThemesPopoverView(
            decreaseTextSize: { [weak self] in
                (self?.documentWindow.contentViewController as? MainSplitViewController)?
                    .zoomOutDocument(nil)
            },
            increaseTextSize: { [weak self] in
                (self?.documentWindow.contentViewController as? MainSplitViewController)?
                    .zoomInDocument(nil)
            },
            currentZoom: { [weak self] in
                (self?.documentWindow.contentViewController as? MainSplitViewController)?
                    .documentPageZoom ?? 1.0
            },
            openCustomize: { [weak self] in
                self?.themesPopover?.close()
                guard let window = self?.documentWindow else { return }
                // Presented after the popover has actually gone: closing it is
                // not synchronous, and a sheet raised while the popover's
                // window still holds key arrives inactive.
                DispatchQueue.main.async { CustomizeThemeSheet.present(on: window) }
            }
        ))
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        popover.delegate = self
        themesPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        themesPopoverEscapeMonitor.start { [weak self] in
            guard let popover = self?.themesPopover, popover.isShown else { return false }
            popover.close()
            return true
        }
    }

    /// However the popover went away — Escape, an outside click, the toolbar
    /// button again, or Customize — the key monitor goes with it.
    func popoverDidClose(_ notification: Notification) {
        themesPopoverEscapeMonitor.stop()
        // Dropped rather than kept for reuse: holding it retains the hosting
        // controller and the whole card gallery for the window's lifetime,
        // and the next press builds a fresh one anyway.
        themesPopover = nil
    }


    /// One-time swap for toolbars restored from an autosaved configuration
    /// that predates the Themes & Settings item: the zoom pair gives its
    /// place to the popover button. Guarded by a defaults flag so a user
    /// who rearranges things in Customize Toolbar afterwards keeps their
    /// layout on the next launch.
    private static let didReplaceZoomItemKey = "Toolbar.DidReplaceZoomWithThemesAndSettings"

    func replaceZoomToolbarItemIfNeeded(in toolbar: NSToolbar) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didReplaceZoomItemKey) else { return }
        defaults.set(true, forKey: Self.didReplaceZoomItemKey)
        guard !toolbar.items.contains(where: { $0.itemIdentifier == .themesAndSettings }),
              let zoomIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .zoom })
        else { return }
        toolbar.removeItem(at: zoomIndex)
        toolbar.insertItem(withItemIdentifier: .themesAndSettings, at: zoomIndex)
    }

    private func inspectorImage() -> NSImage {
        let image = NSImage(systemSymbolName: "info",
                            accessibilityDescription: NSLocalizedString("Inspector", comment: "Inspector toolbar image")) ?? NSImage()
        image.isTemplate = true
        return image
    }

    @objc private func toggleInspectorAction(_ sender: Any) {
        let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
            .toggleInspector() ?? false
        setInspectorToggleSelected(isVisible)
    }

    private func refreshInspectorToggleItem() {
        let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
            .isInspectorVisible ?? false
        setInspectorToggleSelected(isVisible)
    }

    private func setInspectorToggleSelected(_ isSelected: Bool) {
        isInspectorToggleSelected = isSelected
        inspectorButton?.state = isSelected ? .on : .off
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let currentMarkdown else { return [] }
        return [currentMarkdown]
    }
}
