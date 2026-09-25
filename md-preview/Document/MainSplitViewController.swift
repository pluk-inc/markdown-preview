//
//  MainSplitViewController.swift
//  md-preview
//

import Cocoa

final class MainSplitViewController: NSSplitViewController {

    private static let didSeedKey = "MainSplitView.didSeedInitialState"
    /// Keeps the pane picker and sidebar toggle visible beside the window controls.
    private static let minimumSidebarWidth: CGFloat = 230

    /// How far the chrome overlays (formatting bar, find bar) tuck up into
    /// the native tab bar's empty bottom margin, closing the visual gap
    /// between tabs and bar. Applied only while a tab bar is visible; the
    /// editor's page padding subtracts the same amount
    /// (EditorViewController.fullChromeTopInset).
    static let formattingBarTabBarOverlap: CGFloat = 6

    /// Full screen draws the tab bar with a thinner bottom margin, so the
    /// standard tuck overshoots and the bars crowd the tabs — back off.
    static let formattingBarTabBarOverlapFullScreen: CGFloat = 2

    /// The overlap currently in effect for `window`: zero without a
    /// visible tab bar, reduced in full screen. The overlay constraints
    /// and the editor's page padding must use the same value.
    static func tabBarOverlap(for window: NSWindow?) -> CGFloat {
        // Sequoia's tabs end at the content layout guide without Tahoe's
        // extra margin. Tucking the rows upward clips the first row.
        guard #available(macOS 26.0, *) else { return 0 }
        guard let window, window.tabGroup?.isTabBarVisible == true else { return 0 }
        return window.styleMask.contains(.fullScreen)
            ? formattingBarTabBarOverlapFullScreen : formattingBarTabBarOverlap
    }

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

    func display(markdown: String,
                 fileName: String,
                 url: URL?,
                 assetBaseURL: URL?,
                 containmentRoot: URL? = nil) {
        contentViewController?.display(
            markdown: markdown,
            sourceURL: url,
            assetBaseURL: assetBaseURL,
            containmentRoot: containmentRoot
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

    func scrollToAnchorWhenReady(_ fragment: String) {
        contentViewController?.scrollToAnchorWhenReady(fragment)
    }

    func scrollToAnchor(_ fragment: String) {
        contentViewController?.scrollToAnchor(fragment)
    }

    var previewScrollPosition: CGFloat {
        contentViewController?.currentScrollPosition ?? 0
    }

    private var activeFindQuery = ""
    private var activeFindMode: SearchMode = .contains
    private var activeFindCompletion: ((FindResult) -> Void)?

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        activeFindQuery = query
        activeFindMode = mode
        activeFindCompletion = completion
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(query, forType: .string)
        if isEditorPreparing { return } // Replay once the editor and scroll position are ready.
        if let editor = editorViewController {
            editor.find(query, backwards: backwards, mode: mode, completion: completion)
        } else {
            contentViewController?.find(query, backwards: backwards, mode: mode, completion: completion)
        }
    }

    private func refreshFindAfterModeChange() {
        guard !activeFindQuery.isEmpty else { return }
        if let editor = editorViewController {
            editor.find(activeFindQuery, mode: activeFindMode, completion: activeFindCompletion)
        } else {
            contentViewController?.find("") { [weak self] _ in
                guard let self, !self.isEditingDocument else { return }
                self.contentViewController?.find(self.activeFindQuery, mode: self.activeFindMode,
                                                 completion: self.activeFindCompletion)
            }
        }
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

    /// The document's current page zoom, for the toolbar popover's text-size
    /// scale. 1.0 when there is no content view yet — the default stop.
    var documentPageZoom: CGFloat {
        contentViewController?.pageZoom ?? 1.0
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

    /// Target of the system `.toggleSidebar` toolbar item. The themed layout
    /// uses a plain split view item, which the stock implementation ignores,
    /// so both layouts go through the app's own toggle and the toolbar's
    /// pane picker is kept in step.
    override func toggleSidebar(_ sender: Any?) {
        toggleSidebar()
        (view.window?.windowController as? DocumentWindowController)?.syncSidebarToolbarState()
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

    func applyReaderLayout() {
        contentViewController?.applyReaderLayout()
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
        item.minimumThickness = minimumSidebarWidth
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

    /// Brings restored widths into the supported range, including narrow
    /// widths saved before the sidebar gained its pane picker.
    private func normalizeSidebarWidthIfNeeded() {
        guard let sidebar = splitViewItems.first, !sidebar.isCollapsed else { return }
        let width = sidebar.viewController.view.frame.width
        if width < sidebar.minimumThickness || width > sidebar.maximumThickness {
            splitView.setPosition(Self.minimumSidebarWidth, ofDividerAt: 0)
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
    private var isEditorExiting = false
    private var pendingExitCompletions: [() -> Void] = []
    private var editModeGeneration = UUID()
    private var pendingSourceScrollAnchor: SourceScrollAnchor?
    private var isSourceScrollAnchorResolved = false
    private var isEditorDOMReady = false
    private var pendingPreviewScrollProgress: CGFloat = 0
    private var shouldAutofocusEditor = false

    var isEditingDocument: Bool {
        isEditorPreparing || isEditorVisible || isEditorExiting
    }

    var editorViewController: EditorViewController? {
        isEditingDocument ? cachedEditorViewController : nil
    }

    @discardableResult
    func enterEditMode(markdown: String,
                       assetBaseURL: URL? = nil,
                       containmentRoot: URL? = nil,
                       autofocus: Bool = false) -> EditorViewController {
        // Do not invalidate an exit that still owes its caller a completion.
        if isEditorExiting, let editor = cachedEditorViewController { return editor }
        if let editor = editorViewController {
            editor.load(markdown: markdown,
                        assetBaseURL: assetBaseURL,
                        containmentRoot: containmentRoot)
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

        let generation = UUID()
        editModeGeneration = generation
        isEditorPreparing = true
        pendingSourceScrollAnchor = nil
        isSourceScrollAnchorResolved = false
        isEditorDOMReady = false
        pendingPreviewScrollProgress = previewScrollProgress
        shouldAutofocusEditor = autofocus
        // A completed exit may still have a fallback deadline scheduled.
        // Clear its restoration machinery before the next editing session.
        contentViewController?.prepareToRestoreSourceScrollAnchor(nil)
        contentViewController?.pendingAnchorRestored = nil
        // Ensure preview is visible during the prepare phase — a rapid mode
        // toggle could leave it hidden from a previous edit session.
        contentViewController?.view.isHidden = false
        editorVC.view.alphaValue = 0
        editorVC.view.isHidden = false
        editorVC.editorDidBecomeReady = { [weak self, weak editorVC] in
            guard let self, let editorVC, self.editModeGeneration == generation,
                  self.isEditorPreparing else { return }
            editorVC.editorDidBecomeReady = nil
            self.isEditorDOMReady = true
            self.revealEditorIfPrepared(editorVC)
        }
        editorVC.applyPageZoom(previewZoom)
        editorVC.load(markdown: markdown, assetBaseURL: assetBaseURL, containmentRoot: containmentRoot)
        contentViewController?.sourceScrollAnchor { [weak self, weak editorVC] anchor in
            guard let self, let editorVC, self.editModeGeneration == generation,
                  self.isEditorPreparing else { return }
            self.pendingSourceScrollAnchor = anchor
            self.isSourceScrollAnchorResolved = true
            self.revealEditorIfPrepared(editorVC)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak editorVC] in
            guard let self, let editorVC, self.editModeGeneration == generation,
                  self.isEditorPreparing,
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
        if Self.usesFloatingFormattingBar {
            if Self.usesNativeChromeAccessories {
                layeredContentViewController?.nativeFindOverlay = findOverlayView
            }
            layeredContentViewController?.installFormattingBar(bar)
        } else if Self.usesNativeChromeAccessories {
            formattingAccessory = installNativeChromeAccessory(bar)
        } else {
            layeredContentViewController?.installFormattingBar(bar)
        }
        // The editor pads its page below the chrome; the bar is part of
        // that chrome now, so it must be measured alongside the titlebar.
        cachedEditorViewController?.formattingBar = bar
        if Self.usesNativeChromeAccessories {
            contentViewController?.formattingBar = bar
            contentViewController?.chromeOverlaysDidChange()
        }
    }

    func removeFormattingBar() {
        if Self.usesFloatingFormattingBar {
            layeredContentViewController?.removeFormattingBar()
        } else if #available(macOS 26.1, *), Self.usesNativeChromeAccessories,
           let item = splitViewItems.dropFirst().first,
           let index = item.topAlignedAccessoryViewControllers.firstIndex(where: { $0 === formattingAccessory }) {
            item.removeTopAlignedAccessoryViewController(at: index)
            formattingAccessory = nil
        } else {
            layeredContentViewController?.removeFormattingBar()
        }
        cachedEditorViewController?.formattingBar = nil
        if Self.usesNativeChromeAccessories {
            contentViewController?.formattingBar = nil
            contentViewController?.chromeOverlaysDidChange()
        }
    }

    private weak var findOverlayView: NSView?
    private var formattingAccessory: NSViewController?
    private var findAccessory: NSViewController?

    static var usesFloatingFormattingBar: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    static var usesNativeChromeAccessories: Bool {
        if #available(macOS 27.0, *) { return false }
        if #available(macOS 26.1, *) { return true }
        return false
    }

    /// Height a visible chrome row (native find accessory or floating
    /// formatting overlay) adds above the page, or 0 when absent or hidden.
    /// fittingSize rather than the frame: the frame is unresolved between
    /// install and the next layout pass, exactly when callers ask.
    static func nativeAccessoryHeight(_ bar: NSView?, in window: NSWindow) -> CGFloat {
        guard let bar, bar.window === window, !bar.isHidden else { return 0 }
        return bar.fittingSize.height
    }

    private func installNativeChromeAccessory(_ bar: NSView) -> NSViewController? {
        guard #available(macOS 26.1, *),
              let item = splitViewItems.dropFirst().first else { return nil }
        let accessory = NSSplitViewItemAccessoryViewController()
        accessory.automaticallyAppliesContentInsets = false
        accessory.preferredScrollEdgeEffectStyle = .soft
        accessory.view = bar
        bar.setFrameSize(bar.fittingSize)
        accessory.isHidden = bar.isHidden
        item.addTopAlignedAccessoryViewController(accessory)
        return accessory
    }

    /// Mounts the find bar the same way — see installFormattingBar. Stays
    /// mounted for the window's lifetime; visibility toggles via isHidden.
    func installFindOverlay(_ bar: NSView) {
        if Self.usesNativeChromeAccessories {
            findAccessory = installNativeChromeAccessory(bar)
        } else {
            layeredContentViewController?.installFindOverlay(bar)
        }
        findOverlayView = bar
        if Self.usesNativeChromeAccessories {
            layeredContentViewController?.nativeFindOverlay = bar
        }
        cachedEditorViewController?.findOverlay = bar
        contentViewController?.findOverlay = bar
    }

    /// The find bar sits above the formatting bar, so toggling it moves
    /// the bar below and changes the editor's page padding.
    func findOverlayVisibilityChanged() {
        if #available(macOS 26.1, *), Self.usesNativeChromeAccessories {
            (findAccessory as? NSSplitViewItemAccessoryViewController)?.isHidden = findOverlayView?.isHidden ?? true
        }
        layeredContentViewController?.updateChromeOverlayLayout()
        cachedEditorViewController?.chromeOverlaysDidChange()
        contentViewController?.chromeOverlaysDidChange()
    }

    private func revealEditorIfPrepared(_ editorVC: EditorViewController) {
        guard isEditorPreparing, isEditorDOMReady, isSourceScrollAnchorResolved else { return }
        let generation = editModeGeneration
        // CodeMirror and the preview source lookup complete independently.
        // Apply the exact line only after both are ready, then reveal after a
        // display cycle so no empty editor frame is exposed.
        editorVC.applyScrollProgress(pendingPreviewScrollProgress,
                                     sourceAnchor: pendingSourceScrollAnchor) { [weak self, weak editorVC] in
            DispatchQueue.main.async {
                guard let self, let editorVC, self.editModeGeneration == generation,
                      self.isEditorPreparing else { return }
                // Original uses transparent WebViews. Crossfading would draw
                // both text layers together, even with the editor at alpha 1.
                // Swap in one main-thread turn after scroll restoration.
                self.contentViewController?.view.isHidden = true
                editorVC.view.alphaValue = 1
                self.isEditorPreparing = false
                self.isEditorVisible = true
                self.refreshFindAfterModeChange()
                if self.shouldAutofocusEditor {
                    self.shouldAutofocusEditor = false
                    editorVC.focusEditor()
                }
            }
        }
    }

    /// `overlayHidden` fires after the visibility swap, so editing chrome can
    /// be dismissed without reflowing the outgoing editor. Completion also waits
    /// for that swap; callers may navigate or enter another editing session.
    func exitEditMode(waitForPreviewRender: Bool,
                      renderPreview: (() -> Void)? = nil,
                      overlayHidden: (@MainActor () -> Void)? = nil,
                      completion: @escaping () -> Void) {
        if isEditorExiting {
            pendingExitCompletions.append {
                renderPreview?()
                overlayHidden?()
                completion()
            }
            return
        }
        guard let editorVC = cachedEditorViewController,
              isEditorPreparing || isEditorVisible else {
            renderPreview?()
            overlayHidden?()
            completion()
            return
        }
        // Cancel pending entry work before asking WebKit for the exit anchor.
        // That asynchronous request must not leave the reveal path enabled.
        let generation = UUID()
        editModeGeneration = generation
        isEditorExiting = true
        isEditorPreparing = false
        editorVC.editorDidBecomeReady = nil
        editorVC.fetchScrollAnchor { [weak self, weak editorVC] anchor in
            guard let self, let editorVC else {
                overlayHidden?()
                completion()
                return
            }
            guard self.editModeGeneration == generation else { return }
            editorVC.editorDidBecomeReady = nil
            self.pendingSourceScrollAnchor = nil
            self.isSourceScrollAnchorResolved = false
            self.isEditorDOMReady = false
            self.isEditorPreparing = false
            self.isEditorVisible = false
            self.shouldAutofocusEditor = false

            var didRevealPreview = false
            let revealPreview = { [weak self, weak editorVC] in
                guard let self, let editorVC,
                      self.editModeGeneration == generation,
                      !self.isEditorPreparing, !self.isEditorVisible,
                      !didRevealPreview else { return }
                didRevealPreview = true
                self.isEditorExiting = false
                let pendingCompletions = self.pendingExitCompletions
                self.pendingExitCompletions.removeAll()
                self.contentViewController?.pendingAnchorRestored = nil
                // Hide the transparent editor before exposing the reader.
                // Also finish correctly when exiting during preparation,
                // while the editor still has alpha zero.
                editorVC.view.isHidden = true
                editorVC.view.alphaValue = 0
                self.contentViewController?.view.isHidden = false
                self.refreshFindAfterModeChange()
                overlayHidden?()
                completion()
                pendingCompletions.forEach { $0() }
            }

            if waitForPreviewRender, anchor != nil {
                // Keep the preview hidden until the fresh render has restored
                // the source anchor — swapping immediately exposed re-rendering
                // and scrolling into place, which read as jitter. A deadline
                // caps the hold in case the render outruns it.
                self.contentViewController?.prepareToRestoreSourceScrollAnchor(anchor)
                self.contentViewController?.pendingAnchorRestored = revealPreview
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    revealPreview()
                }
                renderPreview?()
            } else {
                renderPreview?()
                if let anchor, let preview = self.contentViewController {
                    preview.restoreSourceScrollAnchor(anchor, completion: revealPreview)
                } else {
                    revealPreview()
                }
            }
        }
    }

    /// The project the sidebar has mounted, which the document search
    /// palette searches.
    var projectRootURL: URL? { sidebarViewController?.projectRootURL }

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
        splitView.setPosition(Self.minimumSidebarWidth, ofDividerAt: 0)
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
        let editorTop: NSLayoutConstraint
        if #unavailable(macOS 26.0),
           let guide = view.window?.contentLayoutGuide as? NSLayoutGuide {
            editorTop = editorView.topAnchor.constraint(equalTo: guide.topAnchor)
            legacyEditorTopConstraint = editorTop
        } else {
            editorTop = editorView.topAnchor.constraint(equalTo: view.topAnchor)
        }
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorTop,
            editorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateChromeOverlayLayout()
    }

    private var legacyEditorTopConstraint: NSLayoutConstraint?
    private weak var formattingBar: NSView?
    private weak var findOverlay: NSView?
    weak var nativeFindOverlay: NSView?
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
        let overlap = -MainSplitViewController.tabBarOverlap(for: view.window)
        if let top = findOverlayTopConstraint, top.constant != overlap {
            top.constant = overlap
        }
        var editTop = overlap
        if let find = nativeFindOverlay, !find.isHidden {
            editTop += find.fittingSize.height
        }
        if let find = findOverlay, find.superview === view, !find.isHidden {
            editTop += find.fittingSize.height
        }
        if let top = formattingBarTopConstraint, top.constant != editTop {
            top.constant = editTop
        }
        if #unavailable(macOS 26.0), let top = legacyEditorTopConstraint {
            var contentTop: CGFloat = 0
            if let find = findOverlay, !find.isHidden { contentTop += find.fittingSize.height }
            if let bar = formattingBar, !bar.isHidden { contentTop += bar.fittingSize.height }
            if contentTop > 0 { contentTop += overlap }
            top.constant = max(0, contentTop)
        }
    }
}
