//
//  MainSplitViewController.swift
//  md-preview
//

import Cocoa

final class MainSplitViewController: NSSplitViewController {

    private static let didSeedKey = "MainSplitView.didSeedInitialState"

    /// How far the chrome overlays (formatting bar, find bar) tuck up into
    /// the native tab bar's empty bottom margin, closing the visual gap
    /// between tabs and bar. Applied only while a tab bar is visible; the
    /// editor's page padding subtracts the same amount
    /// (EditorViewController.fullChromeTopInset).
    static let formattingBarTabBarOverlap: CGFloat = 6

    var onSelectFile: ((URL) -> Void)?
    var onOpenMarkdownLink: ((URL) -> Void)?
    var onToggleTaskCheckbox: ((Int, Bool) -> Void)?
    var onEditTable: ((MarkdownTableEditRequest) -> Void)?

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
        let sidebar = Self.makeSidebarItem(for: sidebarVC, themed: false)

        let content = NSSplitViewItem(viewController: LayeredContentViewController())
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
        DispatchQueue.main.async { [weak self] in
            self?.normalizeSidebarWidthIfNeeded()
        }

        // Wired after addSplitViewItem so the accessors are non-nil.
        contentViewController?.activeHeadingDidChange = { [weak self] headingID in
            self?.sidebarViewController?.setActiveHeading(headingID)
        }
        contentViewController?.taskCheckboxToggled = { [weak self] line, checked in
            self?.onToggleTaskCheckbox?(line, checked)
        }
        contentViewController?.tableEditRequested = { [weak self] request in
            self?.onEditTable?(request)
        }
        contentViewController?.localMarkdownLinkActivated = { [weak self] url in
            self?.onOpenMarkdownLink?(url)
        }
    }

    func display(markdown: String, fileName: String, url: URL?, assetBaseURL: URL?) {
        contentViewController?.display(
            markdown: markdown,
            sourceURL: url,
            assetBaseURL: assetBaseURL
        )
        sidebarViewController?.display(markdown: markdown, fileName: fileName, fileURL: url)
        inspectorViewController?.display(metadata: DocumentMetadata.make(url: url, markdown: markdown))
    }

    /// URL-only refresh after a rename. Skips the content re-render so
    /// the preview, scroll position, and active-heading highlight stay
    /// put.
    func openFileURLDidChange(_ newURL: URL, markdown: String) {
        contentViewController?.sourceFileURLDidChange(newURL)
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

    func prepareToScrollAfterNavigation(to target: NavigationScrollTarget?) {
        contentViewController?.prepareToScrollAfterNavigation(to: target)
    }

    func scrollToAnchor(_ fragment: String) {
        contentViewController?.scrollToAnchor(fragment)
    }

    var previewScrollPosition: CGFloat {
        contentViewController?.currentScrollPosition ?? 0
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

    @IBAction func exportMarkdownDocument(_ sender: Any?) {
        contentViewController?.exportDocument()
    }

    /// Custom selector for the same reason as `printMarkdown(_:)`: keep the
    /// action distinct from AppKit's built-in document/window responders.
    @IBAction func exportMarkdownAsPDF(_ sender: Any?) {
        contentViewController?.exportPDF()
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
        let documentActions = [
            #selector(exportMarkdownDocument(_:)),
            #selector(exportMarkdownAsPDF(_:)),
            #selector(printMarkdown(_:)),
        ]
        if let action = menuItem.action, documentActions.contains(action) {
            return contentViewController?.hasExportableDocument == true
        }
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

    func hideSidebar() {
        guard let sidebar = splitViewItems.first, !sidebar.isCollapsed else { return }
        sidebar.isCollapsed = true
    }

    var sidebarMode: SidebarViewController.Mode {
        sidebarViewController?.currentMode ?? .outline
    }

    func setSidebarMode(_ mode: SidebarViewController.Mode) {
        sidebarViewController?.setMode(mode)
    }

    func reloadPreviewForSettingChange() {
        contentViewController?.reloadPreviewForSettingChange()
    }

    /// Pushes a theme color change into the preview and, when one exists,
    /// the cached editor page — visible or kept warm for reuse.

    func applyThemeColors() {
        contentViewController?.applyThemeColors()
        cachedEditorViewController?.applyThemeColors()
        sidebarViewController?.refreshRowTextColors()
    }

    private static func makeSidebarItem(for viewController: SidebarViewController,
                                        themed: Bool) -> NSSplitViewItem {
        let item = themed
            ? NSSplitViewItem(viewController: viewController)
            : NSSplitViewItem(sidebarWithViewController: viewController)
        item.minimumThickness = 180
        item.maximumThickness = 400
        item.canCollapse = true
        item.canCollapseFromWindowResize = false
        item.allowsFullHeightLayout = true
        // Plain items default to a lower holding priority than sidebars;
        // match the sidebar's so window resizes stretch the content pane,
        // not the sidebar.
        item.holdingPriority = NSLayoutConstraint.Priority(260)
        return item
    }

    /// Recovers a sane sidebar width when the autosaved divider position is
    /// degenerate — collapsed-to-zero or ballooned — which the sidebar item
    /// swap can leave behind.
    private func normalizeSidebarWidthIfNeeded() {
        guard let sidebar = splitViewItems.first, !sidebar.isCollapsed else { return }
        let width = sidebar.viewController.view.frame.width
        if width < sidebar.minimumThickness || width > sidebar.maximumThickness {
            splitView.setPosition(240, ofDividerAt: 0)
        }
    }

    func applyTextSizeSetting() {
        contentViewController?.applyTextSizeSetting()
    }

    // MARK: - Edit mode

    /// Preview and editor stay attached to the same content surface. Keeping
    /// both WebKit views warm avoids the blank compositing frame produced by
    /// removing one split item and inserting another.
    private var cachedEditorViewController: EditorViewController?
    private var isEditorPreparing = false
    private var isEditorVisible = false
    private var pendingSourceScrollAnchor: SourceScrollAnchor?
    private var isSourceScrollAnchorResolved = false
    private var isEditorDOMReady = false
    private var pendingPreviewScrollProgress: CGFloat = 0
    private var shouldAutofocusEditor = false

    var isEditingDocument: Bool {
        isEditorPreparing || isEditorVisible
    }

    var editorViewController: EditorViewController? {
        isEditingDocument ? cachedEditorViewController : nil
    }

    @discardableResult
    func enterEditMode(markdown: String,
                       assetBaseURL: URL? = nil,
                       autofocus: Bool = false) -> EditorViewController {
        if let editor = editorViewController {
            editor.load(markdown: markdown, assetBaseURL: assetBaseURL)
            if autofocus {
                editor.focusEditor()
            }
            return editor
        }
        guard let contentHost = layeredContentViewController else {
            fatalError("Edit mode requested before the content view was installed")
        }
        let editorVC: EditorViewController
        if let cachedEditorViewController {
            editorVC = cachedEditorViewController
        } else {
            editorVC = EditorViewController()
            editorVC.loadViewIfNeeded()
            editorVC.view.translatesAutoresizingMaskIntoConstraints = false
            editorVC.view.alphaValue = 0
            contentHost.installEditorOverlay(editorVC)
            editorVC.findOverlay = findOverlayView
            cachedEditorViewController = editorVC
        }

        // Captured before the swap so the editor renders at the same
        // zoom (and therefore the same column width) as the preview.
        let previewZoom = contentViewController?.pageZoom ?? 1
        let previewScrollProgress = contentViewController?.scrollProgress ?? 0

        isEditorPreparing = true
        pendingSourceScrollAnchor = nil
        isSourceScrollAnchorResolved = false
        isEditorDOMReady = false
        pendingPreviewScrollProgress = previewScrollProgress
        shouldAutofocusEditor = autofocus
        // A rapid re-entry can interrupt a previous exit whose anchor
        // restore is still pending; drop that machinery so it can't fire
        // into the new editing session.
        contentViewController?.prepareToRestoreSourceScrollAnchor(nil)
        contentViewController?.pendingAnchorRestored = nil
        // Ensure preview is visible during the prepare phase — a rapid mode
        // toggle could leave it hidden from a previous edit session.
        contentViewController?.view.isHidden = false
        editorVC.view.isHidden = false
        editorVC.editorDidBecomeReady = { [weak self, weak editorVC] in
            guard let self, let editorVC, self.isEditorPreparing else { return }
            editorVC.editorDidBecomeReady = nil
            self.isEditorDOMReady = true
            self.revealEditorIfPrepared(editorVC)
        }
        editorVC.applyPageZoom(previewZoom)
        editorVC.load(markdown: markdown, assetBaseURL: assetBaseURL)
        contentViewController?.sourceScrollAnchor { [weak self, weak editorVC] anchor in
            guard let self, let editorVC, self.isEditorPreparing else { return }
            self.pendingSourceScrollAnchor = anchor
            self.isSourceScrollAnchorResolved = true
            self.revealEditorIfPrepared(editorVC)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak editorVC] in
            guard let self, let editorVC, self.isEditorPreparing,
                  !self.isSourceScrollAnchorResolved else { return }
            self.isSourceScrollAnchorResolved = true
            self.revealEditorIfPrepared(editorVC)
        }
        return editorVC
    }

    /// Mounts the formatting bar as a content overlay directly below the
    /// titlebar chrome. See DocumentWindowController.editBar for why it is
    /// not a titlebar accessory (the native tab bar always renders below
    /// accessories, and would jump on every edit-mode toggle).
    func installFormattingBar(_ bar: NSView) {
        layeredContentViewController?.installFormattingBar(bar)
        // The editor pads its page below the chrome; the bar is part of
        // that chrome now, so it must be measured alongside the titlebar.
        cachedEditorViewController?.formattingBar = bar
    }

    func removeFormattingBar() {
        layeredContentViewController?.removeFormattingBar()
        cachedEditorViewController?.formattingBar = nil
    }

    private weak var findOverlayView: NSView?

    /// Mounts the find bar the same way — see installFormattingBar. Stays
    /// mounted for the window's lifetime; visibility toggles via isHidden.
    func installFindOverlay(_ bar: NSView) {
        layeredContentViewController?.installFindOverlay(bar)
        findOverlayView = bar
        cachedEditorViewController?.findOverlay = bar
    }

    /// The find bar sits above the formatting bar, so toggling it moves
    /// the bar below and changes the editor's page padding.
    func findOverlayVisibilityChanged() {
        layeredContentViewController?.updateChromeOverlayLayout()
        cachedEditorViewController?.chromeOverlaysDidChange()
    }

    private func revealEditorIfPrepared(_ editorVC: EditorViewController) {
        guard isEditorPreparing, isEditorDOMReady, isSourceScrollAnchorResolved else { return }
        // CodeMirror and the preview source lookup complete independently.
        // Apply the exact line only after both are ready, then reveal after a
        // display cycle so no empty editor frame is exposed.
        editorVC.applyScrollProgress(pendingPreviewScrollProgress,
                                     sourceAnchor: pendingSourceScrollAnchor) { [weak self, weak editorVC] in
            DispatchQueue.main.async {
                guard let self, let editorVC, self.isEditorPreparing else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.10
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    editorVC.view.animator().alphaValue = 1
                } completionHandler: { [weak self, weak editorVC] in
                    Task { @MainActor [weak self, weak editorVC] in
                        guard let self, let editorVC, self.isEditorPreparing else { return }
                        self.isEditorPreparing = false
                        self.isEditorVisible = true
                        // Hide the preview WebView so it no longer contributes to
                        // titlebar material sampling. The editor overlay is now
                        // fully opaque and covering it.
                        self.contentViewController?.view.isHidden = true
                        if self.shouldAutofocusEditor {
                            self.shouldAutofocusEditor = false
                            editorVC.focusEditor()
                        }
                    }
                }
            }
        }
    }

    /// `overlayHidden` fires once the editor overlay has fully faded out and
    /// been hidden — the moment chrome tied to editing (the formatting
    /// accessory) can be dismissed without reflowing the crossfade.
    func exitEditMode(waitForPreviewRender: Bool,
                      overlayHidden: (@MainActor () -> Void)? = nil,
                      completion: @escaping () -> Void) {
        guard let editorVC = cachedEditorViewController,
              isEditorPreparing || isEditorVisible else {
            overlayHidden?()
            completion()
            return
        }
        editorVC.fetchScrollAnchor { [weak self, weak editorVC] anchor in
            guard let self, let editorVC else {
                overlayHidden?()
                completion()
                return
            }
            editorVC.editorDidBecomeReady = nil
            self.pendingSourceScrollAnchor = nil
            self.isSourceScrollAnchorResolved = false
            self.isEditorDOMReady = false
            self.isEditorPreparing = false
            self.isEditorVisible = false
            self.shouldAutofocusEditor = false

            let fadeOutEditor = { [weak self, weak editorVC] in
                guard let self, let editorVC,
                      !self.isEditorPreparing, !self.isEditorVisible,
                      editorVC.view.alphaValue > 0 else { return }
                self.contentViewController?.pendingAnchorRestored = nil
                // Reveal the preview before fading out the editor so the preview
                // is ready beneath it during the crossfade.
                self.contentViewController?.view.isHidden = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.10
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    editorVC.view.animator().alphaValue = 0
                } completionHandler: { [weak self, weak editorVC] in
                    Task { @MainActor [weak self, weak editorVC] in
                        guard let self, let editorVC,
                              !self.isEditorPreparing, !self.isEditorVisible else { return }
                        editorVC.view.isHidden = true
                        overlayHidden?()
                    }
                }
            }

            if waitForPreviewRender, anchor != nil {
                // Keep the editor overlay covering the preview until the
                // fresh render has restored the source anchor beneath it —
                // fading immediately exposed the old article re-rendering
                // and scrolling into place, which read as jitter. A deadline
                // caps the hold in case the render outruns it.
                self.contentViewController?.prepareToRestoreSourceScrollAnchor(anchor)
                self.contentViewController?.pendingAnchorRestored = fadeOutEditor
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    fadeOutEditor()
                }
            } else {
                if let anchor {
                    self.contentViewController?.restoreSourceScrollAnchor(anchor)
                }
                fadeOutEditor()
            }
            completion()
        }
    }

    private var sidebarViewController: SidebarViewController? {
        splitViewItems.first?.viewController as? SidebarViewController
    }

    private var contentViewController: ContentViewController? {
        layeredContentViewController?.previewViewController
    }

    private var layeredContentViewController: LayeredContentViewController? {
        splitViewItems.dropFirst().first?.viewController as? LayeredContentViewController
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

/// Stable sibling layers for preview and edit mode. NSScrollView manages the
/// ordering of its own clip/scroller subviews, so an editor cannot reliably be
/// overlaid by adding it directly to ContentViewController.view.
private final class LayeredContentViewController: NSViewController {
    let previewViewController = ContentViewController()

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        addChild(previewViewController)
        previewViewController.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewViewController.view)
        NSLayoutConstraint.activate([
            previewViewController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewViewController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewViewController.view.topAnchor.constraint(equalTo: container.topAnchor),
            previewViewController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func installEditorOverlay(_ editorViewController: EditorViewController) {
        addChild(editorViewController)
        let editorView = editorViewController.view
        editorView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(editorView, positioned: .above, relativeTo: previewViewController.view)
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: view.topAnchor),
            editorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private weak var formattingBar: NSView?
    private weak var findOverlay: NSView?
    private var formattingBarTopConstraint: NSLayoutConstraint?
    private var findOverlayTopConstraint: NSLayoutConstraint?
    private var chromeObservation: NSKeyValueObservation?

    /// The overlays top out at the window's contentLayoutGuide — the bottom
    /// of all titlebar chrome, native tab bar included — so tabs appearing
    /// or disappearing reposition them automatically. In full screen the
    /// guide reaches the top of the screen and the revealed toolbar floats
    /// over them, like it floats over the rest of the content.
    func installFormattingBar(_ bar: NSView) {
        guard bar.superview !== view else { return }
        formattingBar = bar
        formattingBarTopConstraint = installChromeOverlay(bar)
        updateChromeOverlayLayout()
    }

    func removeFormattingBar() {
        formattingBar?.removeFromSuperview()
        formattingBar = nil
        formattingBarTopConstraint = nil
        updateChromeOverlayLayout()
    }

    /// The find bar stays mounted for the window's lifetime and toggles
    /// via isHidden — an overlay never reflows the layout, so showing it
    /// cannot move the tab bar the way a titlebar accessory did.
    func installFindOverlay(_ bar: NSView) {
        guard bar.superview !== view else { return }
        findOverlay = bar
        findOverlayTopConstraint = installChromeOverlay(bar)
        updateChromeOverlayLayout()
    }

    private func installChromeOverlay(_ bar: NSView) -> NSLayoutConstraint? {
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        var constraints = [
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        var top: NSLayoutConstraint?
        if let window = view.window,
           let guide = window.contentLayoutGuide as? NSLayoutGuide {
            top = bar.topAnchor.constraint(equalTo: guide.topAnchor)
            observeChromeIfNeeded(window)
        } else {
            top = bar.topAnchor.constraint(equalTo: view.topAnchor)
        }
        constraints.append(top!)
        NSLayoutConstraint.activate(constraints)
        return top
    }

    /// The tab bar can appear or leave while an overlay is mounted;
    /// contentLayoutRect moves with it. Only state is read here — forcing
    /// layout from this observation re-enters the pass that changed the
    /// rect and breaks the edit-mode reveal machinery.
    private func observeChromeIfNeeded(_ window: NSWindow) {
        guard chromeObservation == nil else { return }
        chromeObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateChromeOverlayLayout()
            }
        }
    }

    /// Positions the overlay stack. The find bar sits at the chrome
    /// boundary (directly below the tab bar, tucked into its empty margin
    /// when tabs show) and the formatting bar below it — formatting acts on
    /// the text, so it stays adjacent to the document; find is a transient
    /// chrome utility and inserts at the boundary, the way Apple's own
    /// find bars do.
    func updateChromeOverlayLayout() {
        let overlap: CGFloat = (view.window?.tabGroup?.isTabBarVisible ?? false)
            ? -MainSplitViewController.formattingBarTabBarOverlap : 0
        if let top = findOverlayTopConstraint, top.constant != overlap {
            top.constant = overlap
        }
        var editTop = overlap
        if let find = findOverlay, find.superview === view, !find.isHidden {
            editTop += find.fittingSize.height
        }
        if let top = formattingBarTopConstraint, top.constant != editTop {
            top.constant = editTop
        }
    }
}
