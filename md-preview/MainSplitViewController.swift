//
//  MainSplitViewController.swift
//  md-preview
//

import Cocoa

final class MainSplitViewController: NSSplitViewController {

    private static let didSeedKey = "MainSplitView.didSeedInitialState"

    var onSelectFile: ((URL) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarVC = SidebarViewController()
        sidebarVC.onSelectHeading = { [weak self] index in
            // Pin before scrolling so a no-op scroll still confirms the click.
            self?.contentViewController?.markHeadingActiveFromClick(index)
            self?.contentViewController?.scrollToHeading(index: index)
        }
        sidebarVC.onSelectFile = { [weak self] url in
            self?.onSelectFile?(url)
        }
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 400
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = false

        let content = NSSplitViewItem(viewController: ContentViewController())
        content.minimumThickness = 420

        let inspector = NSSplitViewItem(inspectorWithViewController: InspectorViewController())
        inspector.minimumThickness = 270
        inspector.maximumThickness = 500
        inspector.isCollapsed = true
        inspector.canCollapseFromWindowResize = false

        addSplitViewItem(sidebar)
        addSplitViewItem(content)
        addSplitViewItem(inspector)

        splitView.autosaveName = "MainSplitView"

        // Wired after addSplitViewItem so the accessors are non-nil.
        contentViewController?.activeHeadingDidChange = { [weak self] headingID in
            self?.sidebarViewController?.setActiveHeading(headingID)
        }
    }

    func display(markdown: String, fileName: String, url: URL?, assetBaseURL: URL?) {
        contentViewController?.display(markdown: markdown, assetBaseURL: assetBaseURL)
        sidebarViewController?.display(markdown: markdown, fileName: fileName, fileURL: url)
        inspectorViewController?.display(metadata: DocumentMetadata.make(url: url, markdown: markdown))
    }

    /// URL-only refresh after a rename. Skips the content re-render so
    /// the preview, scroll position, and active-heading highlight stay
    /// put.
    func openFileURLDidChange(_ newURL: URL, markdown: String) {
        sidebarViewController?.openFileURLDidChange(newURL)
        inspectorViewController?.display(metadata: DocumentMetadata.make(url: newURL, markdown: markdown))
    }

    func openFolder(_ folderURL: URL, selectedFileURL: URL?) {
        sidebarViewController?.openFolder(folderURL, selectedFileURL: selectedFileURL)
        setSidebarMode(.files)
        showSidebar()
    }

    func clearContent() {
        contentViewController?.clearContent()
    }

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        contentViewController?.find(query, backwards: backwards, mode: mode, completion: completion)
    }

    // Custom selector (instead of `print:`) so AppKit's inherited
    // NSView/NSWindow `print:` doesn't intercept higher in the responder chain
    // and print the sidebar / whole window contents.
    @IBAction func printMarkdown(_ sender: Any?) {
        contentViewController?.printDocument()
    }

    @IBAction func zoomInDocument(_ sender: Any?) {
        contentViewController?.zoomIn()
    }

    @IBAction func zoomOutDocument(_ sender: Any?) {
        contentViewController?.zoomOut()
    }

    @IBAction func resetDocumentZoom(_ sender: Any?) {
        contentViewController?.resetZoom()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(resetDocumentZoom(_:)) {
            return abs((contentViewController?.pageZoom ?? 1.0) - 1.0) > 0.001
        }
        return true
    }

    var isInspectorVisible: Bool {
        !(splitViewItems.last?.isCollapsed ?? true)
    }

    @discardableResult
    func toggleInspector() -> Bool {
        guard let inspector = splitViewItems.last else { return false }
        let shouldShow = inspector.isCollapsed
        inspector.animator().isCollapsed = !shouldShow
        return shouldShow
    }

    var isSidebarVisible: Bool {
        !(splitViewItems.first?.isCollapsed ?? true)
    }

    @discardableResult
    func toggleSidebar() -> Bool {
        guard let sidebar = splitViewItems.first else { return false }
        let shouldShow = sidebar.isCollapsed
        sidebar.animator().isCollapsed = !shouldShow
        return shouldShow
    }

    func showSidebar() {
        guard let sidebar = splitViewItems.first, sidebar.isCollapsed else { return }
        sidebar.animator().isCollapsed = false
    }

    var sidebarMode: SidebarViewController.Mode {
        sidebarViewController?.currentMode ?? .outline
    }

    func setSidebarMode(_ mode: SidebarViewController.Mode) {
        sidebarViewController?.setMode(mode)
    }

    private var sidebarViewController: SidebarViewController? {
        splitViewItems.first?.viewController as? SidebarViewController
    }

    private var contentViewController: ContentViewController? {
        splitViewItems.dropFirst().first?.viewController as? ContentViewController
    }

    private var inspectorViewController: InspectorViewController? {
        splitViewItems.last?.viewController as? InspectorViewController
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didSeedKey) else { return }

        // Seed the expanded width so the toolbar toggle opens to a sensible size,
        // then start collapsed (Preview-style for single-item docs).
        splitView.setPosition(240, ofDividerAt: 0)
        splitViewItems.first?.isCollapsed = true
        defaults.set(true, forKey: Self.didSeedKey)
    }
}
