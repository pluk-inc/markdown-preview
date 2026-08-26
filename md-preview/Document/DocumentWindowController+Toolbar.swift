//
//  DocumentWindowController+Toolbar.swift
//  md-preview
//
//  Toolbar construction: the NSToolbarDelegate methods and the item factories.
//

import Cocoa

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
            .zoom,
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
        case .navigation: return makeNavigationItem()
        case .openActions: return makeOpenActionsItem()
        case .openWith: return makeOpenWithItem()
        case .openInLLM:
            guard hasLLMTargetsAvailable else { return nil }
            return makeOpenInLLMItem()
        case .editDocument: return makeEditItem()
        case .inspector: return makeInspectorItem()
        case .alwaysOnTop: return makeAlwaysOnTopItem()
        case .share: return makeShareItem()
        case .search: return makeSearchItem()
        case .printDocument: return makePrintItem()
        case .exportPDF: return makeExportPDFItem()
        case .exportDocument: return makeExportItem()
        case .copyMarkdown: return makeCopyItem()
        case .zoom: return makeZoomItem()
        default: return nil
        }
    }

    private func makeNavigationItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .navigation)
        let back = NSLocalizedString("Back", comment: "Navigation toolbar back button")
        let forward = NSLocalizedString("Forward", comment: "Navigation toolbar forward button")
        item.label = NSLocalizedString("Navigation", comment: "Navigation toolbar item label")
        item.paletteLabel = NSLocalizedString("Back and Forward", comment: "Navigation toolbar palette label")
        item.isNavigational = true
        item.autovalidates = false

        let control = NSSegmentedControl(labels: ["", ""],
                                         trackingMode: .momentary,
                                         target: self,
                                         action: #selector(navigateHistory(_:)))
        control.segmentStyle = .automatic
        control.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back),
                         forSegment: 0)
        control.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward),
                         forSegment: 1)
        control.setToolTip(back, forSegment: 0)
        control.setToolTip(forward, forSegment: 1)
        item.view = control
        navigationItem = item
        navigationControl = control
        updateNavigationControl()
        return item
    }

    @objc private func navigateHistory(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
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

    func updateNavigationControl() {
        let hasHistory = !backHistory.isEmpty || !forwardHistory.isEmpty
        navigationItem?.isHidden = !hasHistory
        navigationItem?.isEnabled = hasHistory
        navigationControl?.isEnabled = hasHistory
        navigationControl?.setEnabled(!backHistory.isEmpty, forSegment: 0)
        navigationControl?.setEnabled(!forwardHistory.isEmpty, forSegment: 1)
    }

    private func makeInspectorItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .inspector)
        item.label = NSLocalizedString("Inspector", comment: "Inspector toolbar item label")
        item.paletteLabel = NSLocalizedString("Get Info", comment: "Inspector toolbar palette label")
        item.toolTip = NSLocalizedString("Show the inspector", comment: "Inspector toolbar item tooltip")

        let button = NSButton(image: inspectorImage(),
                              target: self,
                              action: #selector(toggleInspectorAction(_:)))
        button.setButtonType(.pushOnPushOff)
        button.toolTip = item.toolTip
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 32),
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])

        item.view = container
        inspectorButton = button
        inspectorItem = item
        refreshInspectorToggleItem()
        return item
    }

    private func makeAlwaysOnTopItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .alwaysOnTop)
        let alwaysOnTop = NSLocalizedString("Always on Top", comment: "Always on Top toolbar item label")
        item.label = alwaysOnTop
        item.paletteLabel = alwaysOnTop
        item.toolTip = NSLocalizedString("Keep Markdown Preview windows in front of other apps",
                                         comment: "Always on Top toolbar item tooltip")

        let button = NSButton(image: alwaysOnTopImage(),
                              target: self,
                              action: #selector(toggleAlwaysOnTop(_:)))
        button.setButtonType(.pushOnPushOff)
        button.state = isAlwaysOnTop ? .on : .off
        button.toolTip = item.toolTip
        button.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 32),
            container.widthAnchor.constraint(equalToConstant: 36),
            container.heightAnchor.constraint(equalToConstant: 32)
        ])

        item.view = container
        alwaysOnTopButton = button
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

    private func inspectorImage() -> NSImage {
        let image = NSImage(systemSymbolName: "info.circle",
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
