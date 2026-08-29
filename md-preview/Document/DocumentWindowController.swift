//
//  DocumentWindowController.swift
//  md-preview
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import UniformTypeIdentifiers


// `NSMenuItemValidation` is load-bearing, not tidiness. `validateMenuItem` is only
// reachable from AppKit through an @objc entry point, and `NSWindowController` has
// no such method to override, so without this conformance the implementation below
// is never called: no menu item ever gets its state, and the failure is silent.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation, NSPopoverDelegate {

    enum NavigationIntent {
        case normal
        case back
        case forward
    }

    enum DiskFileState {
        case unchanged
        case modified(String)
        case missing
        case unreadable
    }

    enum EditedMarkdownSaveResult {
        case saved
        case reloaded(String)
        case cancelled
    }

    enum UnsavedEditResolution {
        case save
        case discard
        case cancel
    }

    enum AutoSaveFeedback: Equatable {
        case none
        case failed
    }

    struct HistoryEntry {
        let url: URL
        /// Scroll offset when the user navigated away; restored on back/forward.
        let scrollPosition: CGFloat
    }

    var currentFileURL: URL?
    var currentMarkdown: String?
    var backHistory: [HistoryEntry] = []
    var forwardHistory: [HistoryEntry] = []
    weak var navigationItem: NSToolbarItemGroup?
    private var fileWatcher: FileWatcher?
    var isInspectorToggleSelected = false
    weak var openActionsItem: NSMenuToolbarItem?
    weak var openWithItem: NSMenuToolbarItem?
    weak var openInLLMItem: NSMenuToolbarItem?
    weak var inspectorButton: NSButton?
    weak var alwaysOnTopButton: NSButton?
    weak var editButton: NSButton?
    var editorChangeRevision = 0
    /// In-memory source shown by preview before the user saves it.
    var editorDraftMarkdown: String?
    /// Last known on-disk source, retained while preview displays a draft.
    var editorBaselineMarkdown: String?
    var isEditorCommitInFlight = false
    var pendingEditorCommitRequested = false
    var pendingCommitShouldExit = false
    var pendingCommitCompletions: [(Bool) -> Void] = []
    /// When sidebar navigation starts from edit mode, the newly loaded file
    /// should return to edit mode instead of dropping the user into preview.
    var pendingEditModeURL: URL?
    var autoSaveTimer: Timer?
    var autoSaveTimerID: UUID?
    var isPerformingAutomaticSave = false
    var autoSaveFeedbackResetWork: DispatchWorkItem?
    var autoSaveFeedback = AutoSaveFeedback.none {
        didSet { updateWindowSubtitle() }
    }
    /// Drives the native titlebar subtitle while the editor contains changes
    /// that have not yet been written successfully.
    var hasUnsavedEditorChanges = false {
        didSet {
            guard oldValue != hasUnsavedEditorChanges else { return }
            if hasUnsavedEditorChanges {
                startAutoSaveTimerIfNeeded()
            } else if !isEditorCommitInFlight {
                stopAutoSaveTimer()
            }
            updateWindowSubtitle()
        }
    }
    /// The formatting bar shown while editing. Not a titlebar accessory:
    /// AppKit pins the native tab bar to the bottom of the titlebar, below
    /// every accessory, so a bar mounted there sits above the tabs and its
    /// mount/unmount shoves the tab bar up and down. Instead the bar is an
    /// overlay in the content host, pinned to the window's
    /// contentLayoutGuide — always directly below the tab bar (or the
    /// toolbar when no tabs are shown), and the tab bar never moves.
    weak var editBar: NSView?
    weak var copyItem: NSToolbarItem?
    var copyFeedbackWork: DispatchWorkItem?
    /// The Themes & Settings popover while it is on screen.
    var themesPopover: NSPopover?
    /// Armed only while the themes popover is open.
    let themesPopoverEscapeMonitor = EscapeKeyMonitor()
    weak var searchField: NSSearchField?
    weak var sidebarMenu: NSMenu?
    var findBar: FindBar?
    /// Container for the find bar. A content overlay like editBar — not a
    /// titlebar accessory — so showing it never pushes the tab bar down.
    /// Mounted once at setup and toggled via isHidden.
    weak var findBarOverlay: NSView?
    var searchMode: SearchMode = .contains
    var pendingFindWork: DispatchWorkItem?
    static let findDebounceDelay: TimeInterval = 0.10
    let tableUndoManager = UndoManager()
    var isTableUndoSaveInFlight = false

    var documentWindow: NSWindow {
        guard let window else {
            fatalError("DocumentWindowController accessed before its window was loaded")
        }
        return window
    }

    var markdownDocument: MarkdownDocument? {
        document as? MarkdownDocument
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markdown Preview"
        window.animationBehavior = .default
        window.allowsToolTipsWhenApplicationIsInactive = false
        super.init(window: window)
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One-shot override consumed by the next window's setup: "Open in
    /// New Window" needs that window to skip the native tab group during
    /// its first order-front (when AppKit decides tab placement).
    static var nextWindowDeclinesTabbing = false
    /// One-shot for explicit tab requests (Open in New Tab, ⌘T, the tab
    /// bar's "+"): the next window joins the frontmost window's tab group
    /// even when the system tabbing preference wouldn't put it there.
    static var nextWindowRequestsTab = false

    static func markNextWindowAsSeparate() {
        nextWindowDeclinesTabbing = true
    }

    static func markNextWindowAsTab() {
        nextWindowRequestsTab = true
    }

    /// Whether this window was created by an explicit tab request; consumed
    /// by attachToExistingTabGroupIfNeeded on first show.
    private var joinsTabGroupOnFirstShow = false

    private func setupWindow() {
        documentWindow.styleMask.insert(.fullSizeContentView)
        // Declared explicitly rather than left to AppKit's implicit default,
        // because Always on Top raises the window above the normal level and a
        // window that has not stated its full-screen capability is the first
        // thing AppKit stops offering Enter Full Screen to.
        documentWindow.collectionBehavior.insert(.fullScreenPrimary)
        applyAlwaysOnTopLevel(isFullScreen: false)
        documentWindow.delegate = self
        documentWindow.tabbingIdentifier = "MarkdownDocumentWindow"
        documentWindow.tabbingMode = Self.nextWindowDeclinesTabbing ? .disallowed : .automatic
        joinsTabGroupOnFirstShow = Self.nextWindowRequestsTab && !Self.nextWindowDeclinesTabbing
        Self.nextWindowDeclinesTabbing = false
        Self.nextWindowRequestsTab = false
        let split = MainSplitViewController()
        split.onSelectFile = { [weak self] url in
            self?.present(url: url)
        }
        split.onOpenMarkdownLink = { [weak self] url in
            self?.present(url: url)
        }
        split.onToggleTaskCheckbox = { [weak self] line, checked in
            self?.toggleTaskCheckbox(onLine: line, checked: checked)
        }
        split.onEditTable = { [weak self] request in
            self?.applyTableEdit(request)
        }
        documentWindow.contentViewController = split
        documentWindow.setContentSize(NSSize(width: 1100, height: 720))
        documentWindow.center()
        documentWindow.setFrameAutosaveName("MainWindow")

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        documentWindow.toolbar = toolbar
        documentWindow.toolbarStyle = .automatic
        replaceZoomToolbarItemIfNeeded(in: toolbar)

        installFindBar()
        applyWindowBackgroundTheme()
    }

    /// Applies the user's theme colors to this window: the native window
    /// background plus the preview and editor pages. Also run at setup so
    /// new windows start themed.

    func applyThemeColorsSetting() {
        applyWindowBackgroundTheme()
        mainSplit?.applyThemeColors()
        // The bars paint the page backgrounds; a theme edit changes those
        // colors without an appearance flip, so force a redraw.
        editBar?.needsDisplay = true
        findBarOverlay?.needsDisplay = true
    }

    /// Whether this window wears the themed chrome: a window background
    /// override on the ACTIVE appearance scheme, and an OS that can
    /// complete the recipe. Chrome suppression without a matching tint
    /// exposes the stock fills, so every chrome treatment gates on this —
    /// not on "either scheme customized", and not on theme state alone.
    ///
    /// The macOS 26 floor is not a preference. The transparent titlebar
    /// only reads correctly because WebKit is told which strip the toolbar
    /// obscures, and `WKWebView.obscuredContentInsets` is macOS 26.0+ — so
    /// pre-Tahoe the page would run under an unlined toolbar with no inset
    /// and no frost. The chrome stays native there, the same retreat full
    /// screen makes below. Keep this version in step with the gate in
    /// `ContentViewController.updateObscuredContentInsets()`.
    var usesThemedChrome: Bool {
        guard #available(macOS 26.0, *) else { return false }
        let isDark = documentWindow.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return ThemeColorsSetting.current
            .hasWindowBackgroundOverride(for: isDark ? .dark : .light)
    }

    /// The full-window background. `DocumentBackgroundView` paints the
    /// content area; this covers what remains — the title-bar region and
    /// resize flashes — with a dynamic color so Automatic appearance keeps
    /// flipping it without another pass.
    ///
    /// Full screen deliberately keeps the STANDARD system chrome even when
    /// themed: the full-screen glass surfaces (sidebar card, reveal bar)
    /// sample the space wallpaper and render white over a transparent
    /// themed titlebar (macOS 26, FB20291636 family), and neutralizing
    /// that required patrolling private view classes and layer trees. Not
    /// worth the fragility — the content and sidebar body stay themed in
    /// full screen; only the chrome is native there.
    private func applyWindowBackgroundTheme() {
        // The dynamic background color is public API and applies in every
        // window state — full screen included, where it tints whatever
        // native surfaces sample the window. Only the CHROME treatment
        // below is gated off in full screen.
        documentWindow.backgroundColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return ThemeColorsSetting.current.color(
                .windowBackground, isDark ? .dark : .light
            ) ?? .windowBackgroundColor
        }
        let themed = usesThemedChrome
            && !documentWindow.styleMask.contains(.fullScreen)
        // Automatic resolves to a shadow under the toolbar; over the flat
        // theme color it renders as a clipped gray band between the toolbar
        // and the formatting bar. The themed chrome draws its own hairlines.
        documentWindow.titlebarSeparatorStyle = themed ? .none : .automatic
        guard themed else {
            documentWindow.titlebarAppearsTransparent = false
            return
        }
        // Safari's recipe: the titlebar goes transparent so the window
        // background color runs to the top edge, and the web view is told
        // (via obscuredContentInsets, in ContentViewController) which strip
        // the toolbar obscures so WebKit lays out below it and frosts
        // content that scrolls under.
        //
        // A transparent titlebar on macOS 26 re-dispatches clicks it did not
        // handle (the padding between toolbar buttons) to the content view
        // underneath instead of letting NSThemeFrame start the window drag.
        // The web views give those clicks back — see
        // NSView.declinesChromeStripClick(at:) in Helpers.
        documentWindow.titlebarAppearsTransparent = true
    }

    /// AppKit's automatic tab placement runs when NSDocument shows its
    /// windows — but this controller orders the window front itself (from
    /// makeWindowControllers, before showWindows), so the window is already
    /// visible and placement never happens on its own. Join the frontmost
    /// document window's tab group explicitly on first show instead — but
    /// only when the open was an explicit tab request, when this app's own
    /// "Open documents in tabs" preference is on, or when the system
    /// "Prefer tabs when opening documents" setting asks for it. Plain
    /// opens (Finder, ⌘O, recents) otherwise get their own window.
    func attachToExistingTabGroupIfNeeded() {
        guard !documentWindow.isVisible,
              documentWindow.tabbingMode != .disallowed,
              let host = ([NSApp.mainWindow] + NSApp.orderedWindows)
                  .compactMap({ $0 })
                  .first(where: {
                      $0 !== documentWindow
                          && $0.isVisible
                          && $0.tabbingIdentifier == documentWindow.tabbingIdentifier
                  }) else { return }

        let systemPreference: TabOpeningPolicy.SystemPreference
        switch NSWindow.userTabbingPreference {
        case .always: systemPreference = .always
        case .inFullScreen: systemPreference = .inFullScreen
        case .manual: systemPreference = .manual
        @unknown default: systemPreference = .manual
        }

        guard TabOpeningPolicy.joinsExistingTabGroup(
            isExplicitTabRequest: joinsTabGroupOnFirstShow,
            opensDocumentsInTabs: TabOpeningPolicy.isEnabled,
            systemPreference: systemPreference,
            hostIsFullScreen: host.styleMask.contains(.fullScreen)
        ) else { return }
        host.addTabbedWindow(documentWindow, ordered: .above)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasPendingEditorChanges else { return true }
        requestEndEditing { [weak self] success in
            guard success else { return }
            // close() skips windowShouldClose, so no re-entry loop.
            self?.documentWindow.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        fileWatcher?.cancel()
        fileWatcher = nil
        themesPopoverEscapeMonitor.stop()
        stopAutoSaveTimer()
        autoSaveFeedbackResetWork?.cancel()
        autoSaveFeedbackResetWork = nil
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        applyAlwaysOnTopLevel(isFullScreen: true)
        // Note: dropping .fullSizeContentView here would also avoid the
        // known macOS 26 white-gap bug (FB20291636) with public API, but
        // it makes the reveal bar push the content down. Safari's
        // float-over behavior needs the flag, so the gap is neutralized by
        // the layer treatments in the patrol instead.
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // Full screen switches to the standard chrome (see
        // applyWindowBackgroundTheme).
        applyWindowBackgroundTheme()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyAlwaysOnTopLevel(isFullScreen: false)
        // Back to the themed chrome.
        applyWindowBackgroundTheme()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        isEditing ? nil : tableUndoManager
    }

    func display(markdown: String, fileURL: URL?) {
        tableUndoManager.removeAllActions()
        currentFileURL = fileURL
        currentMarkdown = markdown
        resetAutoSaveFeedback()
        if fileURL == nil {
            stopAutoSaveTimer()
        }
        documentWindow.title = fileURL?.lastPathComponent
            ?? NSLocalizedString("Untitled", comment: "Window title when no document is open")
        updateWindowSubtitle()
        attachToExistingTabGroupIfNeeded()
        documentWindow.makeKeyAndOrderFront(nil)
        // Tab placement is settled once the window is shown; a window opened
        // via "Open in New Window" goes back to normal tabbing afterwards
        // (it can host or join tabs on explicit request, but plain opens no
        // longer recapture it).
        documentWindow.tabbingMode = .automatic
        NSApp.activate()
        refreshOpenWithItem()
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
        updateEditToolbarItem()
        if let fileURL {
            NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
            renderCurrentDocument(text: markdown, fileURL: fileURL)
            startWatching(fileURL)
            offerToBecomeDefaultHandlerIfNeeded()
        }
    }

    func present(url: URL) {
        present(url: url, intent: .normal)
    }

    func present(url: URL, intent: NavigationIntent) {
        let fragment = url.fragment?.removingPercentEncoding
        let url = Self.fileURLWithoutFragment(url)
        let preserveEditMode = isEditing || pendingEditModeURL != nil
        if isEditing || hasPendingEditorChanges {
            requestEndEditing(keepAccessoryMounted: true) { [weak self] success in
                guard success else { return }
                self?.present(url: url, preservingEditMode: preserveEditMode,
                              intent: intent, fragment: fragment)
            }
            return
        }
        present(url: url, preservingEditMode: preserveEditMode, intent: intent, fragment: fragment)
    }

    func present(url: URL, preservingEditMode: Bool,
                         intent: NavigationIntent, fragment: String?) {
        if url.isExistingDirectory {
            pendingEditModeURL = nil
            openFolder(url)
            return
        }

        let split = documentWindow.contentViewController as? MainSplitViewController
        guard currentFileURL?.standardizedFileURL != url.standardizedFileURL else {
            // Link into the already-open document — just scroll.
            if let fragment { split?.scrollToAnchor(fragment) }
            return
        }
        let restoredScrollPosition = commitNavigation(to: url, intent: intent)
        tableUndoManager.removeAllActions()

        // Switching to a different file blanks the preview so the previous
        // doc doesn't linger on screen during sheet dismissal + load.
        let isFileSwitch = currentFileURL != nil && currentFileURL != url
        currentFileURL = url
        currentMarkdown = nil
        pendingEditModeURL = preservingEditMode ? url.standardizedFileURL : nil
        markdownDocument?.replaceFileURL(url)
        documentWindow.title = url.lastPathComponent
        resetAutoSaveFeedback()
        updateWindowSubtitle()
        if isFileSwitch {
            split?.clearContent()
        }
        documentWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        refreshOpenWithItem()
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
        updateEditToolbarItem()
        // History restore wins over the link fragment — back/forward returns
        // to where the user actually was.
        if let restoredScrollPosition {
            split?.prepareToScrollAfterNavigation(to: .position(restoredScrollPosition))
        } else if let fragment {
            split?.prepareToScrollAfterNavigation(to: .anchor(fragment))
        } else {
            split?.prepareToScrollAfterNavigation(to: nil)
        }
        loadFile(at: url)
        startWatching(url)
        offerToBecomeDefaultHandlerIfNeeded()
    }

    /// Records the navigation in history, capturing the departing scroll
    /// offset. Returns the position to restore for back/forward, nil otherwise.
    private func commitNavigation(to url: URL, intent: NavigationIntent) -> CGFloat? {
        guard let currentFileURL else { return nil }
        let departed = HistoryEntry(
            url: currentFileURL.standardizedFileURL,
            scrollPosition: (documentWindow.contentViewController as? MainSplitViewController)?
                .previewScrollPosition ?? 0
        )
        defer { updateNavigationItem() }
        switch intent {
        case .normal:
            Self.appendHistory(departed, to: &backHistory)
            forwardHistory.removeAll()
            return nil
        case .back:
            guard let target = backHistory.last,
                  target.url == url.standardizedFileURL else { return nil }
            backHistory.removeLast()
            Self.appendHistory(departed, to: &forwardHistory)
            return target.scrollPosition
        case .forward:
            guard let target = forwardHistory.last,
                  target.url == url.standardizedFileURL else { return nil }
            forwardHistory.removeLast()
            Self.appendHistory(departed, to: &backHistory)
            return target.scrollPosition
        }
    }

    private static func appendHistory(_ entry: HistoryEntry, to history: inout [HistoryEntry]) {
        if history.last?.url == entry.url {
            // Same document again — keep one entry with the latest scroll.
            history[history.count - 1] = entry
        } else {
            history.append(entry)
        }
    }

    private static func fileURLWithoutFragment(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.fragment != nil else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    func startWatching(_ url: URL) {
        fileWatcher?.cancel()
        let watcher = FileWatcher(url: url) { [weak self] in
            // While editing, disk changes (including our own ⌘S writes)
            // must not re-render or clobber the in-progress session. Every
            // commit revalidates the disk contents before writing, so an
            // external edit is either reloaded or resolved explicitly.
            guard let self, self.currentFileURL == url,
                  !self.isEditing, !self.hasPendingEditorChanges else { return }
            self.loadFile(at: url, silentOnFailure: true)
        }
        watcher.onRename = { [weak self] newURL in
            self?.handleRename(to: newURL)
        }
        fileWatcher = watcher
    }

    /// The currently-open file moved (Finder rename, editor save-as, etc).
    /// Update the open URL and propagate it to the title, recent docs,
    /// Open With list, sidebar selection, and inspector — without
    /// re-rendering the WebView, since the markdown content didn't change.
    func handleRename(to newURL: URL) {
        guard currentFileURL != nil else { return }
        currentFileURL = newURL
        markdownDocument?.replaceFileURL(newURL)
        documentWindow.title = newURL.lastPathComponent
        updateWindowSubtitle()
        NSDocumentController.shared.noteNewRecentDocumentURL(newURL)
        refreshOpenWithItem()
        refreshOpenActionsItem()
        startWatching(newURL)
        if let markdown = currentMarkdown {
            (documentWindow.contentViewController as? MainSplitViewController)?
                .openFileURLDidChange(newURL, markdown: markdown)
        } else {
            loadFile(at: newURL, silentOnFailure: true)
        }
    }

    private static let didOfferDefaultHandlerKey = "MarkdownPreview.didOfferAsDefaultHandler"

    private func offerToBecomeDefaultHandlerIfNeeded() {
        let key = Self.didOfferDefaultHandlerKey
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        guard let markdownType = UTType("net.daringfireball.markdown")
                ?? UTType(filenameExtension: "md") else { return }

        let currentDefaultID = NSWorkspace.shared.urlForApplication(toOpen: markdownType)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        if currentDefaultID == Bundle.main.bundleIdentifier {
            UserDefaults.standard.set(true, forKey: key)
            return
        }

        UserDefaults.standard.set(true, forKey: key)
        Task { @concurrent in
            try? await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL,
                toOpen: markdownType
            )
        }
    }

    /// The chrome-overlay container (formatting bar, find bar) floats over
    /// the web views, whose cursor tracking (I-beam over text, hand over
    /// links) otherwise fights the bar's buttons. The bar region always
    /// shows the plain arrow.
    ///
    /// Opaque: the pages scroll their content under the bars, so a bar must
    /// paint the page's own background to hide it — the titlebar accessory
    /// it replaced got that backdrop from the system chrome for free.
    final class EditAccessoryContainerView: NSView {
        /// The editor page's background, resolved per appearance and read
        /// from the live theme on every draw. Mirrors
        /// EditorViewController.updateUnderPageBackgroundColor.
        private static let editorPageBackground = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let scheme: ThemeColorScheme = isDark ? .dark : .light
            let colors = ThemeColorsSetting.current
            return colors.color(.editorBackground, scheme)
                ?? colors.color(.windowBackground, scheme)
                ?? ThemeColorsSetting.defaultColor(.editorBackground, scheme)
        }

        /// The preview's backdrop — the same chain the window background
        /// and the preview's under-page color use. The find bar shows over
        /// the preview, so it paints this instead of the editor color.
        private static let windowPageBackground = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let scheme: ThemeColorScheme = isDark ? .dark : .light
            return ThemeColorsSetting.current.color(.windowBackground, scheme)
                ?? .windowBackgroundColor
        }

        /// True for bars that overlay the preview (find bar); false for
        /// bars that overlay the editor (formatting bar).
        var prefersWindowBackground = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // Layer-backed instead of draw(_:): custom drawing above the
        // WKWebView interfered with its compositing and blanked the page.
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let color = prefersWindowBackground
                    ? Self.windowPageBackground : Self.editorPageBackground
                layer?.backgroundColor = color.cgColor
            }
        }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }

        // First install: the cursor rect is computed while the accessory
        // has no frame yet and nothing re-invalidates it, so the web view's
        // cursor wins between the buttons until the bar is reinstalled.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.invalidateCursorRects(for: self)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }
    }

}
