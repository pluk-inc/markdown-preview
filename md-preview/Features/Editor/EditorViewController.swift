//
//  EditorViewController.swift
//  md-preview
//

import Cocoa
import WebKit

/// Inline Typora-style editor for the current document: a CodeMirror 6
/// page (Vendor/CodeMirror/mdedit.min.js) with live-preview decorations —
/// headings, emphasis, quotes and code style themselves as you type, and
/// syntax marks hide unless the cursor is inside them. The buffer is the
/// markdown source itself, so saving is byte-faithful: nothing is
/// reformatted or normalized. The page is fully self-contained (no
/// network), so edit mode works offline and inside the sandbox.
final class EditorViewController: NSViewController, WKNavigationDelegate {

    /// Fired on every document change — the host debounces for autosave.
    var contentDidChange: (() -> Void)?
    var formattingDidChange: ((Int, Set<String>, String?) -> Void)?
    /// Fired after CodeMirror has constructed and painted its initial document.
    /// The split view uses this to avoid replacing the preview with a blank WKWebView.
    var editorDidBecomeReady: (() -> Void)?
    /// Esc pressed in the editor — the host decides whether to confirm
    /// and discard.
    var cancelRequested: (() -> Void)?
    /// A native image was pasted at the editor selection.
    var pasteImageRequested: ((Int, Int) -> Void)?
    /// A rendered local image was clicked in the live editor preview.
    var imageClicked: ((URL) -> Void)?

    private(set) var hasChanges = false

    private var webView: WKWebView!
    private let bridge = EditorBridge()
    private let assetScheme = MarkdownAssetScheme()
    private var hasLoadedEditorPage = false
    private var pageSupportsMermaid = false
    private var currentAssetBaseURL: URL?
    private var findCompletion: ((FindResult) -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assetScheme, forURLScheme: MarkdownAssetScheme.scheme)
        config.userContentController.add(bridge, name: EditorBridge.name)
        let webView = EditorWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        bridge.owner = self
        self.webView = webView
        if #available(macOS 26.0, *) {
            view = webView
        } else {
            // The preview's white backing disappears when edit mode hides it.
            // Give the transparent editor its own document background.
            let background = LegacyEditorBackgroundView()
            webView.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                webView.topAnchor.constraint(equalTo: background.topAnchor),
                webView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            ])
            view = background
        }
        webView.blockStyleRequested = { [weak self] style, language in
            self?.setBlockStyle(style, language: language)
        }
        webView.appearanceDidChange = { [weak self] in
            self?.updateUnderPageBackgroundColor()
        }
        updateUnderPageBackgroundColor()
    }

    func load(markdown: String, assetBaseURL: URL? = nil) {
        hasChanges = false
        currentAssetBaseURL = assetBaseURL?.standardizedFileURL
        assetScheme.setBaseURL(currentAssetBaseURL)
        let needsMermaid = Self.containsMermaidFence(in: markdown)
        if hasLoadedEditorPage, pageSupportsMermaid || !needsMermaid {
            let baseHref = currentAssetBaseURL.map(MarkdownAssetResolution.baseHref(forFolder:)) ?? ""
            let script = "window.__mdLoadEditor && window.__mdLoadEditor(\(EditorHTML.jsStringLiteral(markdown)), \(EditorHTML.jsStringLiteral(baseHref)), \(EditorSourceModeSetting.current))"
            webView.evaluateJavaScript(script) { [weak self] _, error in
                guard let self, error != nil else { return }
                self.loadEditorPage(markdown: markdown,
                                    includesMermaid: needsMermaid,
                                    assetBaseURL: self.currentAssetBaseURL)
            }
            return
        }
        loadEditorPage(markdown: markdown,
                       includesMermaid: needsMermaid,
                       assetBaseURL: currentAssetBaseURL)
    }

    private func loadEditorPage(markdown: String,
                                includesMermaid: Bool,
                                assetBaseURL: URL?) {
        hasLoadedEditorPage = false
        pageSupportsMermaid = includesMermaid
        webView.loadHTMLString(
            Self.editorHTML(markdown: markdown,
                            includesMermaid: includesMermaid,
                            assetBaseURL: assetBaseURL),
            baseURL: nil
        )
    }

    /// Switch between the formatted live preview and the plain Markdown
    /// source. The buffer, selection, and undo history carry over. A page
    /// that is still loading reads the stored setting when it renders.
    func applySourceMode() {
        let on = EditorSourceModeSetting.current
        webView.evaluateJavaScript("window.__mdSetSourceMode && window.__mdSetSourceMode(\(on))",
                                   completionHandler: nil)
    }

    /// Mirror the preview's page zoom so the type size and measure don't
    /// jump when toggling edit mode. CSS pixels scale with pageZoom, so
    /// the 900px column and the body gutters track the preview exactly.
    func applyPageZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
        updateChromeZoom()
    }

    private func updateChromeZoom() {
        guard #available(macOS 26.0, *) else { return }
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--mdp-chrome-zoom', '\(max(webView.pageZoom, 0.001))')", completionHandler: nil)
    }

    /// Rewrites the theme override `<style>` so a color edited in Settings
    /// restyles an open editor live. Fresh loads embed the same CSS in
    /// `editorHTML`.
    func applyThemeColors() {
        updateUnderPageBackgroundColor()
        updateObscuredContentInsets()
        let script = ThemeColorsSetting.styleUpdateScript(
            css: ThemeColorsSetting.current.editorOverrideCSS
        )
        webView.evaluateJavaScript(script) { _, _ in }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateObscuredContentInsets()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The chrome (toolbar, accessories) is final here; layout passes
        // before it attaches see a smaller contentLayoutRect.
        updateObscuredContentInsets()
        observeWindowChrome()
    }

    /// The formatting bar overlaying this editor (a content-view sibling,
    /// not a titlebar accessory — see DocumentWindowController.editBar).
    /// The page padding must clear it like any other chrome.
    weak var formattingBar: NSView? {
        didSet {
            guard formattingBar !== oldValue else { return }
            updateObscuredContentInsets()
        }
    }

    /// The find bar overlay (permanent, toggled by isHidden) — like the
    /// formatting bar, it hangs below the titlebar over this editor.
    weak var findOverlay: NSView?

    /// Reapplies the page padding; the window controller calls this when
    /// the find overlay is shown or hidden.
    func chromeOverlaysDidChange() {
        updateObscuredContentInsets()
    }

    private var contentLayoutObservation: NSKeyValueObservation?

    /// Titlebar chrome can change without this view getting a layout pass —
    /// the native tab bar appears when another document joins the window's
    /// tab group — so the padding follows contentLayoutRect directly. The
    /// observation only reads state and reapplies the page padding: forcing
    /// layout from here re-enters the layout pass that changed the rect and
    /// breaks the edit-mode reveal machinery.
    private func observeWindowChrome() {
        guard let window = view.window else {
            contentLayoutObservation = nil
            return
        }
        guard contentLayoutObservation == nil else { return }
        contentLayoutObservation = window.observe(\.contentLayoutRect) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.updateObscuredContentInsets()
            }
        }
    }

    /// The whole obscured strip — titlebar, toolbar, tab bar, and visible
    /// bottom accessories. Floating formatting controls are excluded: their
    /// clearance is page padding, not an obscured strip or scrollbar inset.
    /// contentLayoutRect already excludes the titlebar chrome, so the gap
    /// alone is that chrome's height; adding accessory heights on top
    /// double-counted them and left a blank band below the formatting bar.
    private var fullChromeTopInset: CGFloat {
        guard let window = view.window, let contentView = window.contentView else {
            return view.safeAreaInsets.top
        }
        // Whether contentLayoutRect excludes a bottom accessory depends on
        // its scroll-edge style: .hard reserves layout, .automatic floats
        // over the content. Measure the real bottom edge of every visible
        // accessory instead of assuming either, so the buffer always lays
        // out below the lowest piece of chrome.
        var gap = contentView.bounds.height - window.contentLayoutRect.maxY
        if MainSplitViewController.usesNativeChromeAccessories {
            // See ContentViewController.fullChromeTopInset: the safe area
            // lags accessory changes by a layout pass, so measure the bars.
            gap += MainSplitViewController.nativeAccessoryHeight(findOverlay, in: window)
            if !MainSplitViewController.usesFloatingFormattingBar {
                gap += MainSplitViewController.nativeAccessoryHeight(formattingBar, in: window)
            }
            return max(0, gap)
        }
        for accessory in window.titlebarAccessoryViewControllers
        where accessory.layoutAttribute == .bottom && !accessory.isHidden
            && accessory.view.window === window {
            let rect = contentView.convert(accessory.view.bounds, from: accessory.view)
            gap = max(gap, contentView.bounds.height - rect.minY)
        }
        // The formatting bar and find overlay are content-view chrome
        // hanging directly below the titlebar, so contentLayoutRect never
        // accounts for them. fittingSize instead of the frame: the frame is
        // unresolved between install and the next layout pass, and forcing
        // layout from here would re-enter the pass that called us. With a
        // visible tab bar the stack tucks up into the tab bar's margin
        // (MainSplitViewController.formattingBarTabBarOverlap), so that
        // amount comes back off once.
        var overlays: CGFloat = 0
        if !MainSplitViewController.usesFloatingFormattingBar,
           let bar = formattingBar, bar.window === window, !bar.isHidden {
            overlays += bar.fittingSize.height
        }
        if let find = findOverlay, find.window === window, !find.isHidden {
            overlays += find.fittingSize.height
        }
        if overlays > 0 {
            gap += overlays
            gap -= MainSplitViewController.tabBarOverlap(for: window)
        }
        return max(0, gap)
    }

    /// On macOS 26 and later, page scrolling lets WebKit supply the native
    /// backdrop across the toolbar and visible chrome rows.
    private func updateObscuredContentInsets() {
        guard #available(macOS 26.0, *), view.window != nil else { return }
        let inset = fullChromeTopInset
        if webView.obscuredContentInsets.top != inset {
            webView.obscuredContentInsets = NSEdgeInsets(
                top: inset, left: 0, bottom: 0, right: 0
            )
            updatePageTopInset()
        }
    }

    /// Tells the page how much of its top the toolbar covers, so the source
    /// mode's room past the end is measured from the visible part of the pane.
    private func updatePageTopInset() {
        guard #available(macOS 26.0, *) else { return }
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--mdp-top-inset', '\(webView.obscuredContentInsets.top)px')", completionHandler: nil)
    }

    /// See ContentViewController.updateUnderPageBackgroundColor — set on
    /// theme and appearance changes only, never per layout pass.
    private func updateUnderPageBackgroundColor() {
        if #unavailable(macOS 26.0) {
            view.needsDisplay = true
        }
        guard #available(macOS 26.0, *) else { return }
        // WebKit snapshots the color in the setter. These explicit palette
        // and fallback colors must be reassigned when the appearance changes.
        let isDark = view.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme: ThemeColorScheme = isDark ? .dark : .light
        let colors = ThemeColorsSetting.current
        webView.underPageBackgroundColor = colors.color(.editorBackground, scheme)
            ?? colors.color(.windowBackground, scheme)
            ?? .clear
    }

    /// Current buffer contents, or nil if the editor isn't ready.
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor ? window.__mdEditor.getMarkdown() : null") { value, _ in
            completion(value as? String)
        }
    }

    func find(_ query: String,
              backwards: Bool = false,
              mode: SearchMode = .contains,
              completion: ((FindResult) -> Void)? = nil) {
        findCompletion = completion
        let script = "window.__mdEditor?.find(\(EditorHTML.jsStringLiteral(query)), \(backwards), \(mode == .beginsWith))"
        webView.evaluateJavaScript(script) { result, _ in
            guard let result = result as? [String: Any],
                  let index = result["index"] as? Int,
                  let total = result["total"] as? Int else {
                completion?(.none)
                return
            }
            completion?(FindResult(top: nil, bottom: nil, index: index, total: total))
        }
    }

    func focusEditor() {
        view.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.focus()") { _, _ in }
    }

    /// Applies a normalized preview scroll position after CodeMirror has
    /// measured its own scrollable document. The JS promise resolves after a
    /// paint frame so the editor can be revealed at the final position.
    func applyScrollProgress(_ progress: CGFloat,
                             sourceAnchor: SourceScrollAnchor?,
                             completion: @escaping () -> Void) {
        let clamped = min(max(progress, 0), 1)
        let arguments: [String: Any] = [
            "progress": Double(clamped),
            "sourcePosition": sourceAnchor.map { Double($0.sourcePosition) } ?? NSNull(),
            "sourceGap": sourceAnchor.map { Double($0.topGap) } ?? 0,
        ]
        webView.callAsyncJavaScript(
            """
            if (!window.__mdEditor) return false;
            return await window.__mdEditor.setScrollPosition(progress, sourcePosition, sourceGap);
            """,
            arguments: arguments,
            in: nil,
            in: .page
        ) { _ in
            completion()
        }
    }

    /// Navigate to a heading in the current editor source without moving the cursor.
    func scrollToSourceLine(_ line: Int) {
        guard line > 0 else { return }
        webView.evaluateJavaScript(
            "window.__mdEditor && window.__mdEditor.setScrollPosition(0, \(line), 0)"
        ) { _, _ in }
    }

    func fetchScrollAnchor(_ completion: @escaping (SourceScrollAnchor?) -> Void) {
        webView.evaluateJavaScript(
            "window.__mdEditor && window.__mdEditor.getScrollAnchor()"
        ) { result, _ in
            completion(SourceScrollAnchor(scriptResult: result))
        }
    }

    /// Run a formatting command (bold, italic, h1, quote, …) on the
    /// current selection. Command names map to the bundle's exec() table.
    func exec(_ command: String) {
        let name = EditorHTML.jsStringLiteral(command)
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.exec(\(name))") { _, _ in }
    }

    func fetchHeadingLevel(_ completion: @escaping (Int) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.getHeadingLevel()") { result, _ in
            completion(result as? Int ?? 0)
        }
    }

    func fetchListStyle(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.getListStyle()") { result, _ in
            completion(result as? String ?? "none")
        }
    }

    func fetchBlockStyle(_ completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.getBlockStyle()") { result, _ in
            completion(result as? String ?? "none")
        }
    }

    func setBlockStyle(_ style: String, language: String) {
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.setBlockStyle(\(EditorHTML.jsStringLiteral(style)), \(EditorHTML.jsStringLiteral(language)))") { _, _ in }
    }

    func setListStyle(_ style: String) {
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.setListStyle(\(EditorHTML.jsStringLiteral(style)))") { _, _ in }
    }

    struct LinkSelection {
        let text: String
        let from: Int
        let to: Int
    }

    /// The selection, widened to the whole link it is in unless
    /// `expandingLink` is false.
    func fetchLinkSelection(expandingLink: Bool = true, _ completion: @escaping (LinkSelection?) -> Void) {
        webView.evaluateJavaScript("window.__mdEditor && window.__mdEditor.getLinkSelection(\(expandingLink))") { result, _ in
            guard let value = result as? [String: Any], let text = value["text"] as? String,
                  let from = value["from"] as? Int, let to = value["to"] as? Int else {
                completion(nil)
                return
            }
            completion(LinkSelection(text: text, from: from, to: to))
        }
    }

    func insertLink(text: String, url: String, from: Int, to: Int) {
        let script = "window.__mdEditor && window.__mdEditor.insertLinkFromPopover(\(EditorHTML.jsStringLiteral(text)), \(EditorHTML.jsStringLiteral(url)), \(from), \(to))"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    func insertMarkdown(_ markdown: String,
                        from: Int,
                        to: Int,
                        completion: ((Bool) -> Void)? = nil) {
        let script = """
        (() => {
            if (!window.__mdEditor) return false;
            window.__mdEditor.insertTextAt(\(EditorHTML.jsStringLiteral(markdown)), \(from), \(to));
            return true;
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            completion?(error == nil && (result as? Bool) == true)
        }
    }

    /// Replaces the source after an image rename without rebuilding the page,
    /// preserving the editor's selection and scroll position.
    func replaceMarkdown(_ markdown: String) {
        let script = "window.__mdEditor && window.__mdEditor.replaceMarkdown(\(EditorHTML.jsStringLiteral(markdown)))"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    fileprivate func handle(message: Any) {
        if let message = message as? String {
            switch message {
            case "dirty":
                hasChanges = true
                contentDidChange?()
            case "ready":
                hasLoadedEditorPage = true
                updateChromeZoom()
                updatePageTopInset()
                // Fresh page — the bar padding lives in the DOM and must be
                // re-applied even when the tracked value hasn't changed,
                // and WebKit re-derives the under-page color from the new
                // page, clobbering the themed value.
                updateUnderPageBackgroundColor()
                updateObscuredContentInsets()
                // The setting can change while the page loads.
                applySourceMode()
                editorDidBecomeReady?()
            case "cancel":
                cancelRequested?()
            case let error where error.hasPrefix("error:"):
                NSLog("Markdown editor JavaScript error: %@", error)
            default:
                break
            }
            return
        }

        guard let payload = message as? [String: Any],
              let kind = payload["kind"] as? String else { return }
        switch kind {
        case "copyCode":
            guard let text = payload["value"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "formattingState":
            guard let heading = payload["heading"] as? Int,
                  (0...6).contains(heading),
                  let commands = payload["commands"] as? [String] else { return }
            formattingDidChange?(heading, Set(commands), payload["selectedText"] as? String)
        case "findResult":
            guard let index = payload["index"] as? Int,
                  let total = payload["total"] as? Int else { return }
            findCompletion?(FindResult(top: nil, bottom: nil, index: index, total: total))
        case "pasteImage":
            guard let from = payload["from"] as? NSNumber,
                  let to = payload["to"] as? NSNumber else { return }
            pasteImageRequested?(from.intValue, to.intValue)
        case "imageClick":
            guard let source = payload["src"] as? String,
                  let url = URL(string: source),
                  let fileURL = MarkdownAssetResolution.fileURL(for: url) else { return }
            imageClicked?(fileURL)
        case "tableContextMenu":
            presentTableContextMenu(payload)
        case "tablePopup":
            guard let markdown = payload["markdown"] as? String else { return }
            TablePreviewWindow.shared.present(markdown: markdown, title: nil,
                                              assetBaseURL: currentAssetBaseURL, pageZoom: webView.pageZoom,
                                              relativeTo: view.window)
        default:
            break
        }
    }

    private func presentTableContextMenu(_ payload: [String: Any]) {
        guard let token = payload["token"] as? String else { return }
        let context = TableContextMenuPresenter.Context(
            canInsertRowAbove: (payload["canInsertRowAbove"] as? NSNumber)?.boolValue ?? false,
            canDuplicateRow: (payload["canDuplicateRow"] as? NSNumber)?.boolValue ?? false,
            canDeleteRow: (payload["canDeleteRow"] as? NSNumber)?.boolValue ?? false,
            canDeleteColumn: (payload["canDeleteColumn"] as? NSNumber)?.boolValue ?? false,
            showsDuplicateRow: (payload["showsDuplicateRow"] as? NSNumber)?.boolValue ?? false
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let presenter = TableContextMenuPresenter(context: context) { [weak self] operation in
                guard let self else { return }
                let script = "window.__mdEditor && window.__mdEditor.performTableContextAction(\(EditorHTML.jsStringLiteral(token)), \(EditorHTML.jsStringLiteral(operation)))"
                self.webView.evaluateJavaScript(script) { _, _ in }
            }
            presenter.present(in: self.webView)
        }
    }

    // MARK: - Page assembly

    private static func vendorResource(_ name: String, ext: String, subdir: String) -> String? {
        // Synced-folder resources are copied flat into Resources/, so try
        // the subdirectory first and fall back to the bundle root — same
        // lookup MarkdownHTML uses for its vendor files.
        let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdir)
            ?? Bundle.main.url(forResource: name, withExtension: ext)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static let editorJavaScript =
        vendorResource("mdedit.min", ext: "js", subdir: "Vendor/CodeMirror") ?? ""
    private static let mermaidJavaScript =
        vendorResource("pele.global", ext: "js", subdir: "Vendor/Pele") ?? ""

    private static func containsMermaidFence(in markdown: String) -> Bool {
        markdown.range(
            // A fence can also open after quote markers or a list marker.
            of: #"(?im)^[ \t>]*(?:(?:[-+*]|\d+[.)])[ \t]+)*(?:`{3,}|~{3,})[ \t]*mermaid(?:[ \t]|$)"#,
            options: .regularExpression
        ) != nil
    }

    private static func editorHTML(markdown: String,
                                   includesMermaid: Bool,
                                   assetBaseURL: URL?) -> String {
        // Baked into the base stylesheet, not only the override element:
        // WebKit derives the obscured-inset fill from the base stylesheet's
        // html/body background, so a theme color only present in the later
        // override <style> leaves the toolbar strip on stock Canvas (dark
        // #1e1e1e) in edit mode.
        let colors = ThemeColorsSetting.current
        func pageBackground(_ scheme: ThemeColorScheme) -> String {
            let hex = colors.hexValue(.editorBackground, scheme)
                ?? colors.hexValue(.windowBackground, scheme)
            return MarkdownHTML.ThemeOverrides.sanitizedHexColor(hex) ?? "transparent"
        }
        let lightPageBackground = pageBackground(.light)
        let darkPageBackground = pageBackground(.dark)
        let usesPageScrolling: Bool
        if #available(macOS 26.0, *) {
            usesPageScrolling = true
        } else {
            usesPageScrolling = false
        }
        return EditorHTML.render(
            markdown: markdown,
            editorJavaScript: editorJavaScript,
            mermaidJavaScript: includesMermaid ? mermaidJavaScript : nil,
            assetBaseURL: assetBaseURL,
            configuration: .init(
                fullWidth: ContentWidthSetting.current == .fullWidth,
                lightPageBackground: lightPageBackground,
                darkPageBackground: darkPageBackground,
                themeOverrideCSS: colors.editorOverrideCSS,
                usesPageScrolling: usesPageScrolling,
                bridgeName: EditorBridge.name,
                sourceMode: EditorSourceModeSetting.current
            )
        )
    }
}

private final class EditorBridge: NSObject, WKScriptMessageHandler {
    static let name = "mdEditorHost"
    weak var owner: EditorViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == EditorBridge.name else { return }
        owner?.handle(message: message.body)
    }
}

private final class LegacyEditorBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme: ThemeColorScheme = isDark ? .dark : .light
        let colors = ThemeColorsSetting.current
        let background = colors.color(.editorBackground, scheme)
            ?? colors.color(.windowBackground, scheme)
            ?? (isDark ? nil : NSColor.white)
        layer?.backgroundColor = background?.cgColor
    }
}

private final class EditorWKWebView: WKWebView {
    var appearanceDidChange: (() -> Void)?
    /// A block style and its code language, chosen in the context menu.
    var blockStyleRequested: ((String, String) -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }

    // Left clicks in the transparent titlebar strip stay native (window
    // drag) instead of being consumed by WebKit — see ChromeStripClickThrough.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if declinesChromeStripClick(at: point) { return nil }
        return super.hitTest(point)
    }

    /// Shortens WebKit's menu to the editing commands and adds the app's
    /// own. The switch between the formatted style and the Markdown source
    /// leads, named for the style it goes to. Then the Markdown source gets
    /// the commands of a code editor (Find, Navigate), the formatted style
    /// the formatting commands.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let sourceMode = EditorSourceModeSetting.current
        let appDelegate = NSApp.delegate as? AppDelegate
        menu.keepOnlyEditingCommands()

        let title = sourceMode
            ? NSLocalizedString("Show Markdown", comment: "Editor context menu: leave the Markdown source for the formatted style")
            : NSLocalizedString("Show Source", comment: "Editor context menu: show the Markdown source of the file")
        let toggle = NSMenuItem(title: title,
                                action: #selector(toggleSourceModeFromContextMenu(_:)),
                                keyEquivalent: "")
        toggle.target = self
        let submenus = (sourceMode
            ? [appDelegate?.makeFindContextMenuItem(), makeNavigateMenuItem()]
            : [appDelegate?.makeFormatContextMenuItem()]).compactMap { $0 }
        let leading = [toggle, .separator()] + submenus + (submenus.isEmpty ? [] : [.separator()])
        for (index, item) in leading.enumerated() {
            menu.insertItem(item, at: index)
        }

        if !sourceMode {
            // Below WebKit's Cut, Copy, and Paste: the commands used most,
            // without a submenu.
            let groups = [
                appDelegate?.makeFormatContextMenuItems(commands: ["bold", "italic", "strikethrough", "code"]) ?? [],
                makeCodeBlockItems(),
                [makeBlockStyleItem(NSLocalizedString("Insert Table", comment: "Editor context menu: insert a Markdown table"),
                                    style: "table")],
            ]
            for group in groups where !group.isEmpty {
                menu.addItem(.separator())
                group.forEach(menu.addItem)
            }
        }
        super.willOpenMenu(menu, with: event)
    }

    private var documentWindowController: DocumentWindowController? {
        window?.windowController as? DocumentWindowController
    }

    /// The file of the document; nil for a document that has none.
    private var documentFileURL: URL? {
        documentWindowController?.currentFileURL
    }

    /// AppKit asks about every type of every Service, and
    /// `NSImage.imageTypes` builds its list on each call.
    private static let imageReturnTypes = Set(NSImage.imageTypes)

    /// Tells AppKit that this view takes an image, so it appends the
    /// commands of a nearby iPhone or iPad (Take Photo, Scan Documents, Add
    /// Sketch) to the context menu. An image goes into a folder beside the
    /// Markdown file, so a document without a file cannot take one.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, documentFileURL != nil,
           Self.imageReturnTypes.contains(returnType.rawValue) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Plain Text Block, and Code Block with its languages.
    private func makeCodeBlockItems() -> [NSMenuItem] {
        let codeBlock = NSMenuItem(title: NSLocalizedString("Code Block", comment: "Editor context menu: submenu with the languages for a fenced code block"),
                                   action: nil,
                                   keyEquivalent: "")
        let languages = NSMenu()
        for language in CodeLanguageCatalog.all {
            languages.addItem(makeBlockStyleItem(language.name, style: "fenced", language: language.id))
        }
        codeBlock.submenu = languages
        return [
            makeBlockStyleItem(NSLocalizedString("Plain Text Block", comment: "Editor context menu: make the paragraph a code block without a language"),
                               style: "plain"),
            codeBlock,
        ]
    }

    private struct BlockStyle {
        let style: String
        let language: String
    }

    private func makeBlockStyleItem(_ title: String, style: String, language: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title,
                              action: #selector(setBlockStyleFromContextMenu(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = BlockStyle(style: style, language: language)
        return item
    }

    @objc private func setBlockStyleFromContextMenu(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? BlockStyle else { return }
        if !block.language.isEmpty { CodeLanguageCatalog.remember(block.language) }
        blockStyleRequested?(block.style, block.language)
    }

    /// Where the open file is: in the sidebar's file tree and in Finder.
    /// Nil for a document that has no file.
    private func makeNavigateMenuItem() -> NSMenuItem? {
        guard documentFileURL != nil else { return nil }
        let submenu = NSMenu()
        for (title, action) in [
            (NSLocalizedString("Reveal in Project Navigator", comment: "Editor context menu, Navigate submenu: show the open file in the sidebar's file tree"),
             #selector(revealInNavigatorFromContextMenu(_:))),
            (NSLocalizedString("Show in Finder", comment: "Project navigator context menu"),
             #selector(showInFinderFromContextMenu(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: NSLocalizedString("Navigate", comment: "Editor context menu: submenu with the places that show the open file"),
                              action: nil,
                              keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// The file tree keeps the open file selected, so showing the tree
    /// reveals it.
    @objc private func revealInNavigatorFromContextMenu(_ sender: Any?) {
        documentWindowController?.selectFilesMode(sender)
    }

    @objc private func showInFinderFromContextMenu(_ sender: Any?) {
        guard let url = documentFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleSourceModeFromContextMenu(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.toggleEditorSourceMode()
    }
}

// WKWebView has its own, undeclared `readSelection(from:)` for Services
// that return text. This one takes the image of a nearby device and hands
// everything else to WebKit's.
extension EditorWKWebView: NSServicesMenuRequestor {
    func readSelection(from pboard: NSPasteboard) -> Bool {
        if documentWindowController?.insertImage(from: pboard) == true {
            return true
        }
        let selector = #selector(NSServicesMenuRequestor.readSelection(from:))
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return false }
        typealias ReadSelection = @convention(c) (AnyObject, Selector, NSPasteboard) -> Bool
        let webKitReadSelection = unsafeBitCast(method_getImplementation(method), to: ReadSelection.self)
        return webKitReadSelection(self, selector, pboard)
    }
}

private extension NSMenu {
    /// WebKit's items that take the selected text somewhere else.
    private static let lookupItemIdentifiers: Set<String> = [
        "WKMenuItemIdentifierLookUp",
        "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierSearchWeb",
        "WKMenuItemIdentifierShareMenu",
    ]

    /// Shortens WebKit's menu for editable text to the editing commands
    /// (Cut, Copy, Paste). The lookups and Share go. The text-style items
    /// (Spelling, Substitutions, Font, Speech, the writing directions) are
    /// submenus, and not all of them have an identifier, so every submenu
    /// goes; so do the items macOS appends (Services).
    func keepOnlyEditingCommands() {
        allowsContextMenuPlugIns = false
        items.removeAll { item in
            item.hasSubmenu || Self.lookupItemIdentifiers.contains(item.identifier?.rawValue ?? "")
        }
        // Removing a whole group leaves its separator behind.
        var kept: [NSMenuItem] = []
        for item in items where !(item.isSeparatorItem && (kept.last?.isSeparatorItem ?? true)) {
            kept.append(item)
        }
        if kept.last?.isSeparatorItem == true { kept.removeLast() }
        items = kept
    }
}
