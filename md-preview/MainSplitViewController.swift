//
//  MainSplitViewController.swift
//  md-preview
//

import Cocoa

final class MainSplitViewController: NSSplitViewController {

    private static let didSeedKey = "MainSplitView.didSeedInitialState"

    private var editorSplitItem: NSSplitViewItem?
    private var editorCollapseObservation: NSKeyValueObservation?

    var onSelectFile: ((URL) -> Void)?
    var onEditorTextChange: ((String) -> Void)?
    /// Fired whenever the editor pane's visibility changes, regardless of
    /// what caused it (toolbar button, menu item, divider drag). The split
    /// item's `isCollapsed` is the single source of truth.
    var onEditorVisibilityChange: ((Bool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarVC = SidebarViewController()
        sidebarVC.onSelectHeading = { [weak self] index in
            // Pin before scrolling so a no-op scroll still confirms the click.
            self?.previewViewController?.markHeadingActiveFromClick(index)
            self?.previewViewController?.scrollToHeading(index: index)
        }
        sidebarVC.onSelectFile = { [weak self] url in
            self?.onSelectFile?(url)
        }
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 400
        sidebar.canCollapse = true
        sidebar.canCollapseFromWindowResize = false

        let editorVC = EditorViewController()
        editorVC.onTextChange = { [weak self] newText in
            self?.onEditorTextChange?(newText)
        }
        let editor = NSSplitViewItem(viewController: editorVC)
        editor.minimumThickness = 300
        editor.maximumThickness = 800
        editor.canCollapse = true
        editor.canCollapseFromWindowResize = false
        // Collapsed unconditionally at creation (same pattern as the
        // inspector below) — not in the one-time seed block, which never
        // runs for installs that predate the editor pane.
        editor.isCollapsed = true
        self.editorSplitItem = editor
        editorCollapseObservation = editor.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onEditorVisibilityChange?(self.isEditorVisible)
            }
        }

        let content = NSSplitViewItem(viewController: ContentViewController())
        content.minimumThickness = 420

        let inspector = NSSplitViewItem(inspectorWithViewController: InspectorViewController())
        inspector.minimumThickness = 270
        inspector.maximumThickness = 500
        inspector.isCollapsed = true
        inspector.canCollapseFromWindowResize = false

        addSplitViewItem(sidebar)
        addSplitViewItem(editor)
        addSplitViewItem(content)
        addSplitViewItem(inspector)

        splitView.autosaveName = "MainSplitView"

        // Wired after addSplitViewItem so the accessors are non-nil.
        previewViewController?.activeHeadingDidChange = { [weak self] headingID in
            self?.sidebarViewController?.setActiveHeading(headingID)
        }
    }

    func display(markdown: String, fileName: String, url: URL?, assetBaseURL: URL?) {
        displayPreviewOnly(markdown: markdown, fileName: fileName, url: url, assetBaseURL: assetBaseURL)
        editorViewController?.setMarkdown(markdown)
    }

    /// Updates preview, sidebar, and inspector without touching the editor.
    /// Used by the editor-triggered render path to avoid feeding text back.
    func displayPreviewOnly(markdown: String, fileName: String, url: URL?, assetBaseURL: URL?) {
        previewViewController?.display(markdown: markdown, assetBaseURL: assetBaseURL)
        sidebarViewController?.display(markdown: markdown, fileName: fileName, fileURL: url)
        inspectorViewController?.display(metadata: DocumentMetadata.make(url: url, markdown: markdown))
    }

    /// Delivers any pending (debounced) editor edit immediately.
    /// Call before switching files or closing so the document holds the
    /// full editor text.
    func flushPendingEditorChanges() {
        editorViewController?.flushPendingChanges()
    }

    /// Enables or disables editing in the source pane (e.g. for files the
    /// sandbox grants read-only access to).
    func setEditorEditable(_ isEditable: Bool) {
        editorViewController?.isEditable = isEditable
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
        previewViewController?.clearContent()
    }

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        previewViewController?.find(query, backwards: backwards, mode: mode, completion: completion)
    }

    // Custom selector (instead of `print:`) so AppKit's inherited
    // NSView/NSWindow `print:` doesn't intercept higher in the responder chain
    // and print the sidebar / whole window contents.
    @IBAction func printMarkdown(_ sender: Any?) {
        previewViewController?.printDocument()
    }

    @IBAction func zoomInDocument(_ sender: Any?) {
        previewViewController?.zoomIn()
    }

    @IBAction func zoomOutDocument(_ sender: Any?) {
        previewViewController?.zoomOut()
    }

    @IBAction func resetDocumentZoom(_ sender: Any?) {
        previewViewController?.resetZoom()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(resetDocumentZoom(_:)) {
            return abs((previewViewController?.pageZoom ?? 1.0) - 1.0) > 0.001
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

    /// Whether the editor pane is currently visible (not collapsed).
    var isEditorVisible: Bool {
        !(editorSplitItem?.isCollapsed ?? true)
    }

    /// Toggles the editor pane visibility. Returns `true` if the editor is now visible.
    @discardableResult
    func toggleEditor() -> Bool {
        guard let editorItem = editorSplitItem else { return false }
        let shouldShow = editorItem.isCollapsed
        editorItem.animator().isCollapsed = !shouldShow
        return shouldShow
    }

    var sidebarMode: SidebarViewController.Mode {
        sidebarViewController?.currentMode ?? .outline
    }

    func setSidebarMode(_ mode: SidebarViewController.Mode) {
        sidebarViewController?.setMode(mode)
    }

    func reloadPreviewForAppearanceChange() {
        previewViewController?.reloadPreviewForAppearanceChange()
    }

    private var sidebarViewController: SidebarViewController? {
        splitViewItems.first?.viewController as? SidebarViewController
    }

    private var editorViewController: EditorViewController? {
        splitViewItems.dropFirst().first?.viewController as? EditorViewController
    }

    private var previewViewController: ContentViewController? {
        guard splitViewItems.count > 2 else { return nil }
        return splitViewItems[2].viewController as? ContentViewController
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
