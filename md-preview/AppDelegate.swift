//
//  AppDelegate.swift
//  md-preview
//

import Cocoa
import Sparkle
import UniformTypeIdentifiers

private enum CommandLineToolInstallError: LocalizedError {
    case terminalAutomationFailed(String?)
    case installerScriptWriteFailed(String)
    case bundledToolMissing

    var errorDescription: String? {
        switch self {
        case .terminalAutomationFailed(let message):
            if let message, !message.isEmpty {
                return "Terminal automation failed: \(message)"
            }
            return "Terminal automation failed."
        case .installerScriptWriteFailed(let message):
            return "Failed to write CLI installer script: \(message)"
        case .bundledToolMissing:
            return "The bundled Markdown Preview CLI could not be found."
        }
    }
}

private extension String {
    var appleScriptQuotedString: String {
        let escaped = replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    var shellQuotedString: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum AppAppearanceMode: String, CaseIterable {
    case automatic
    case light
    case dark

    private static let defaultsKey = "MarkdownPreview.appearance"

    static var current: AppAppearanceMode {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(AppAppearanceMode.init(rawValue:)) ?? .automatic
        }
        set {
            if newValue == .automatic {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .automatic: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet private weak var checkForUpdatesMenuItem: NSMenuItem?

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private weak var hideSidebarMenuItem: NSMenuItem?
    private weak var outlineMenuItem: NSMenuItem?
    private weak var filesMenuItem: NSMenuItem?
    private weak var automaticAppearanceMenuItem: NSMenuItem?
    private weak var lightAppearanceMenuItem: NSMenuItem?
    private weak var darkAppearanceMenuItem: NSMenuItem?
    private weak var normalContentWidthMenuItem: NSMenuItem?
    private weak var fullContentWidthMenuItem: NSMenuItem?
    private var isOpeningDocumentFromPrompt = false
    private var isPromptingForDocument = false
    private var isDocumentPromptScheduled = false
    private var isTerminationSaveInProgress = false
    private var pendingTerminationSaveCount = 0
    private var terminationSaveFailed = false

    private static let markdownFileExtensions = ["md", "markdown", "mdown", "txt"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.start()
        applyAppearanceMode(AppAppearanceMode.current, reloadPreviews: false)
        installAppearanceMenuItems()
        installContentWidthMenuItems()
        installSidebarViewMenuItems()
        installEditModeMenuItem()
        installFormatMenu()
        installNewTabMenuItem()
        installGoMenu()
        installAppMenuItemIcons()
        installZoomMenuItemIcons()
        scheduleDocumentPrompt(requiresNoDocuments: true)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        scheduleDocumentPrompt(requiresNoDocuments: true)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            scheduleDocumentPrompt(requiresNoDocuments: true)
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isExistingDirectory {
                openFolder(url)
                continue
            }

            NSDocumentController.shared.openDocument(withContentsOf: url,
                                                     display: true) { _, _, error in
                guard let error else { return }
                NSAlert(error: error).runModal()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminationSaveInProgress {
            return .terminateLater
        }

        let controllers = NSDocumentController.shared.documents
            .flatMap(\.windowControllers)
            .compactMap { $0 as? DocumentWindowController }
            .filter(\.hasPendingEditorChanges)
        guard !controllers.isEmpty else { return .terminateNow }

        isTerminationSaveInProgress = true
        pendingTerminationSaveCount = controllers.count
        terminationSaveFailed = false

        for controller in controllers {
            controller.commitPendingEditsForTermination { [weak self, weak sender] success in
                guard let self, let sender, self.isTerminationSaveInProgress else { return }
                self.terminationSaveFailed = self.terminationSaveFailed || !success
                self.pendingTerminationSaveCount -= 1
                guard self.pendingTerminationSaveCount == 0 else { return }

                let shouldTerminate = !self.terminationSaveFailed
                self.isTerminationSaveInProgress = false
                self.terminationSaveFailed = false
                sender.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    @IBAction func checkForUpdates(_ sender: Any?) {
        updaterController.updater.checkForUpdates()
    }

    @IBAction func toggleCrashReporting(_ sender: NSMenuItem) {
        CrashReporter.isEnabled.toggle()
        sender.state = CrashReporter.isEnabled ? .on : .off
    }

    @objc private func installCommandLineTools(_ sender: Any?) {
        do {
            let commandLineToolURL = try bundledCommandLineToolURL()
            let installerScriptURL = try writeCommandLineToolInstallerScript(
                commandLineToolURL: commandLineToolURL
            )
            let installCommand = makeCommandLineToolInstallCommand(scriptURL: installerScriptURL)
            try runInstallCommandInTerminal(installCommand)
        } catch {
            NSLog("Failed to run Markdown Preview CLI installer in Terminal: \(error.localizedDescription)")
        }
    }

    @IBAction func openDocument(_ sender: Any?) {
        promptForDocument()
    }

    @IBAction func performFindPanelAction(_ sender: Any?) {
        activeDocumentWindowController?.handleFindAction(sender)
    }

    @IBAction func performTextFinderAction(_ sender: Any?) {
        activeDocumentWindowController?.handleFindAction(sender)
    }

    @objc private func hideSidebarFromMenu(_ sender: Any?) {
        activeDocumentWindowController?.hideSidebarFromMenu(sender)
        syncSidebarViewMenuState()
    }

    @objc private func selectOutlineMode(_ sender: Any?) {
        activeDocumentWindowController?.selectOutlineMode(sender)
        syncSidebarViewMenuState()
    }

    @objc private func selectFilesMode(_ sender: Any?) {
        activeDocumentWindowController?.selectFilesMode(sender)
        syncSidebarViewMenuState()
    }

    @objc private func selectAppearanceMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = AppAppearanceMode(rawValue: rawValue),
              mode != AppAppearanceMode.current else { return }

        AppAppearanceMode.current = mode
        applyAppearanceMode(mode, reloadPreviews: true)
    }

    @objc private func selectContentWidthSetting(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let setting = ContentWidthSetting(rawValue: rawValue),
              setting != ContentWidthSetting.current else { return }

        ContentWidthSetting.current = setting
        syncContentWidthMenuState()
        reloadDocumentPreviewsForSettingChange()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        syncSidebarViewMenuState()
        syncAppearanceMenuState()
        syncContentWidthMenuState()
        switch menuItem.action {
        case #selector(hideSidebarFromMenu(_:)),
             #selector(selectOutlineMode(_:)),
             #selector(selectFilesMode(_:)),
             #selector(performFindPanelAction(_:)),
             #selector(performTextFinderAction(_:)):
            return activeDocumentWindowController != nil
        case #selector(selectAppearanceMode(_:)),
             #selector(selectContentWidthSetting(_:)):
            return true
        case #selector(toggleCrashReporting(_:)):
            menuItem.state = CrashReporter.isEnabled ? .on : .off
            return true
        case #selector(toggleEditModeFromMenu(_:)):
            return activeDocumentWindowController?.canToggleEditMode ?? false
        case #selector(formatMarkdownFromMenu(_:)):
            return activeDocumentWindowController?.canFormatMarkdown ?? false
        default:
            return true
        }
    }

    private var activeDocumentWindowController: DocumentWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? DocumentWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? DocumentWindowController {
            return controller
        }
        return NSDocumentController.shared.documents
            .flatMap(\.windowControllers)
            .compactMap { $0 as? DocumentWindowController }
            .first
    }

    private func promptForDocument() {
        guard !isPromptingForDocument else { return }
        isPromptingForDocument = true
        defer { isPromptingForDocument = false }

        let panel = makeOpenPanel()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.isExistingDirectory {
            openFolder(url)
            return
        }

        isOpeningDocumentFromPrompt = true
        NSDocumentController.shared.openDocument(withContentsOf: url,
                                                 display: true) { [weak self] _, _, error in
            self?.isOpeningDocumentFromPrompt = false
            guard let error else { return }
            NSAlert(error: error).runModal()
        }
    }

    private func scheduleDocumentPrompt(requiresNoDocuments: Bool = false) {
        guard !isPromptingForDocument,
              !isDocumentPromptScheduled else { return }

        isDocumentPromptScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDocumentPromptScheduled = false
            guard !requiresNoDocuments || NSDocumentController.shared.documents.isEmpty else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.promptForDocument()
        }
    }

    private func openFolder(_ url: URL) {
        if let controller = activeDocumentWindowController {
            controller.openFolder(url)
            return
        }

        let document = MarkdownDocument()
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        guard let controller = document.windowControllers.first as? DocumentWindowController else {
            return
        }
        controller.openFolder(url)
    }

    private func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a Markdown file or folder"
        panel.allowedContentTypes = Self.markdownFileExtensions
            .compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    private func makeCommandLineToolInstallerScript(commandLineToolURL: URL) -> String {
        """
        #!/bin/sh
        set -eu
        installer_path=$0
        trap 'rm -f "$installer_path"' EXIT
        bundled_cli=\(commandLineToolURL.path.shellQuotedString)

        path_contains() {
          case ":$PATH:" in
            *":$1:"*) return 0 ;;
            *) return 1 ;;
          esac
        }

        can_install_without_sudo() {
          dir="$1"
          if [ -d "$dir" ]; then
            [ -w "$dir" ] && [ -x "$dir" ]
            return
          fi

          parent="${dir%/*}"
          [ "$parent" != "$dir" ] || parent="."
          [ -d "$parent" ] && [ -w "$parent" ] && [ -x "$parent" ]
        }

        is_safe_path_dir() {
          case "$1" in
            ""|.|/bin|/sbin|/usr/bin|/usr/sbin|/System/*) return 1 ;;
            /*) return 0 ;;
            *) return 1 ;;
          esac
        }

        choose_install_dir() {
          for dir in "$HOME/.local/bin" "$HOME/bin"; do
            if path_contains "$dir" && can_install_without_sudo "$dir"; then
              printf '%s\t%s\n' "$dir" "false"
              return 0
            fi
          done

          old_ifs=$IFS
          IFS=:
          set -- $PATH
          IFS=$old_ifs

          for dir in /usr/local/bin /opt/homebrew/bin; do
            if path_contains "$dir"; then
              if can_install_without_sudo "$dir"; then
                printf '%s\t%s\n' "$dir" "false"
              else
                printf '%s\t%s\n' "$dir" "true"
              fi
              return 0
            fi
          done

          for dir do
            if is_safe_path_dir "$dir" && can_install_without_sudo "$dir"; then
              printf '%s\t%s\n' "$dir" "false"
              return 0
            fi
          done

          for dir do
            if is_safe_path_dir "$dir"; then
              printf '%s\t%s\n' "$dir" "true"
              return 0
            fi
          done

          return 1
        }

        choice=$(choose_install_dir) || {
          echo "Could not find a usable PATH directory for Markdown Preview command line tools." >&2
          exit 1
        }

        install_dir=${choice%	*}
        needs_sudo=${choice#*	}
        primary="$install_dir/md-preview"

        is_markdown_preview_launcher() {
          path="$1"
          [ -f "$path" ] && [ ! -L "$path" ] || return 1
          if grep -q '^# Managed by Markdown Preview CLI$' "$path"; then
            return 0
          fi
          grep -q 'exec open -b "doc.md-preview"' "$path"
        }

        can_replace_primary() {
          path="$1"
          if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            return 0
          fi
          is_markdown_preview_launcher "$path"
        }

        can_replace_alias() {
          alias_path="$1"
          if [ ! -e "$alias_path" ] && [ ! -L "$alias_path" ]; then
            return 0
          fi
          [ -L "$alias_path" ] || return 1
          alias_target=$(readlink "$alias_path" || true)
          [ "$alias_target" = "md-preview" ] ||
            [ "$alias_target" = "$primary" ] ||
            [ "$alias_target" = "$install_dir/md-preview" ]
        }

        refuse_existing_command() {
          echo "Refusing to replace existing command that was not installed by Markdown Preview: $1" >&2
          exit 1
        }

        can_replace_primary "$primary" || refuse_existing_command "$primary"
        for alias in mdp markdown-preview; do
          can_replace_alias "$install_dir/$alias" || refuse_existing_command "$install_dir/$alias"
        done

        if [ "$needs_sudo" = "true" ]; then
          echo "Installing Markdown Preview command line tools to $install_dir requires your password."
          sudo mkdir -p "$install_dir"
          sudo install -m 755 "$bundled_cli" "$primary"
        else
          mkdir -p "$install_dir"
          install -m 755 "$bundled_cli" "$primary"
        fi

        for alias in mdp markdown-preview; do
          alias_path="$install_dir/$alias"
          if [ "$needs_sudo" = "true" ]; then
            sudo ln -sfn "md-preview" "$alias_path"
          else
            ln -sfn "md-preview" "$alias_path"
          fi
        done

        echo
        echo "Markdown Preview CLI is ready."
        echo
        echo "Use any of these commands:"
        echo "  mdp"
        echo "  md-preview"
        echo "  markdown-preview"
        echo
        echo "Examples:"
        echo "  mdp README.md        Open a Markdown file"
        echo "  mdp .                Open the current folder"
        echo "  mdp docs             Browse a folder in Markdown Preview"
        echo
        echo "Tips:"
        echo "  Use mdp for the shortest command."
        echo "  Re-run Install CLI... after updating the app to refresh these commands."
        echo "  Installed in: $install_dir"
        echo

        if command -v mdp >/dev/null 2>&1; then
          echo "Try it now: mdp ."
        else
          echo "Open a new terminal window, then try: mdp ."
        fi
        """
    }

    private func bundledCommandLineToolURL() throws -> URL {
        guard let url = Bundle.main.url(forResource: "markdown-preview",
                                        withExtension: nil,
                                        subdirectory: "bin") else {
            throw CommandLineToolInstallError.bundledToolMissing
        }
        return url
    }

    private func writeCommandLineToolInstallerScript(commandLineToolURL: URL) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-markdown-preview-cli-\(UUID().uuidString).sh")

        do {
            try makeCommandLineToolInstallerScript(commandLineToolURL: commandLineToolURL)
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: url.path)
            return url
        } catch {
            throw CommandLineToolInstallError.installerScriptWriteFailed(error.localizedDescription)
        }
    }

    private func makeCommandLineToolInstallCommand(scriptURL: URL) -> String {
        "/bin/sh \(scriptURL.path.shellQuotedString)"
    }

    private func runInstallCommandInTerminal(_ command: String) throws {
        let source = """
        tell application "Terminal"
            activate
            do script \(command.appleScriptQuotedString)
        end tell
        """

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw CommandLineToolInstallError.terminalAutomationFailed(nil)
        }

        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? errorInfo.description
            throw CommandLineToolInstallError.terminalAutomationFailed(message)
        }
    }

    private func installNewTabMenuItem() {
        guard let fileMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "File" })?.submenu,
              fileMenu.items.first(where: {
                  $0.action == #selector(NSResponder.newWindowForTab(_:))
              }) == nil else { return }

        // nil target: resolves through the responder chain to the key
        // document window's controller, and disables itself when no
        // document window is open.
        let item = NSMenuItem(title: "New Tab",
                              action: #selector(NSResponder.newWindowForTab(_:)),
                              keyEquivalent: "t")
        let insertIndex = fileMenu.items
            .firstIndex { $0.action == #selector(openDocument(_:)) } ?? 0
        fileMenu.insertItem(item, at: insertIndex)
    }

    private func installGoMenu() {
        guard let mainMenu = NSApp.mainMenu,
              mainMenu.items.first(where: { $0.title == "Go" }) == nil else { return }

        func arrow(_ functionKey: Int) -> String {
            UnicodeScalar(functionKey).map { String(Character($0)) } ?? ""
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        func makeItem(_ title: String,
                      action: Selector,
                      keyEquivalent: String,
                      modifiers: NSEvent.ModifierFlags,
                      symbol: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(symbolConfig) {
                image.isTemplate = true
                item.image = image
            }
            return item
        }

        let menu = NSMenu(title: "Go")

        menu.addItem(makeItem("Up",
                              action: #selector(NSResponder.scrollLineUp(_:)),
                              keyEquivalent: arrow(NSUpArrowFunctionKey),
                              modifiers: [],
                              symbol: "arrow.up"))
        menu.addItem(makeItem("Down",
                              action: #selector(NSResponder.scrollLineDown(_:)),
                              keyEquivalent: arrow(NSDownArrowFunctionKey),
                              modifiers: [],
                              symbol: "arrow.down"))
        menu.addItem(makeItem("Page Up",
                              action: #selector(NSResponder.scrollPageUp(_:)),
                              keyEquivalent: arrow(NSPageUpFunctionKey),
                              modifiers: [],
                              symbol: "chevron.up.square"))
        menu.addItem(makeItem("Page Down",
                              action: #selector(NSResponder.scrollPageDown(_:)),
                              keyEquivalent: arrow(NSPageDownFunctionKey),
                              modifiers: [],
                              symbol: "chevron.down.square"))

        menu.addItem(.separator())

        menu.addItem(makeItem("Previous Item",
                              action: #selector(MarkdownWebView.mdScrollPreviousHeading(_:)),
                              keyEquivalent: arrow(NSUpArrowFunctionKey),
                              modifiers: .option,
                              symbol: "arrow.up.document"))
        menu.addItem(makeItem("Next Item",
                              action: #selector(MarkdownWebView.mdScrollNextHeading(_:)),
                              keyEquivalent: arrow(NSDownArrowFunctionKey),
                              modifiers: .option,
                              symbol: "arrow.down.document"))

        menu.addItem(.separator())

        menu.addItem(makeItem("Top of Document",
                              action: #selector(NSResponder.scrollToBeginningOfDocument(_:)),
                              keyEquivalent: arrow(NSUpArrowFunctionKey),
                              modifiers: .command,
                              symbol: "arrow.up.to.line"))
        menu.addItem(makeItem("Bottom of Document",
                              action: #selector(NSResponder.scrollToEndOfDocument(_:)),
                              keyEquivalent: arrow(NSDownArrowFunctionKey),
                              modifiers: .command,
                              symbol: "arrow.down.to.line"))

        let goItem = NSMenuItem(title: "Go", action: nil, keyEquivalent: "")
        goItem.submenu = menu

        let insertIndex = mainMenu.items.firstIndex(where: { $0.title == "Window" })
            ?? mainMenu.items.count
        mainMenu.insertItem(goItem, at: insertIndex)
    }

    private func installZoomMenuItemIcons() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu else { return }
        let icons: [(title: String, symbol: String)] = [
            ("Actual Size", "magnifyingglass"),
            ("Zoom In", "plus.magnifyingglass"),
            ("Zoom Out", "minus.magnifyingglass")
        ]
        for (title, symbol) in icons {
            guard let item = viewMenu.items.first(where: { $0.title == title }),
                  let image = NSImage(systemSymbolName: symbol,
                                      accessibilityDescription: title)
            else { continue }
            image.isTemplate = true
            item.image = image
        }
    }

    private func installAppearanceMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu,
              viewMenu.items.first(where: { $0.title == "Appearance" }) == nil else { return }

        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        if let image = NSImage(systemSymbolName: "circle.lefthalf.filled",
                               accessibilityDescription: "Appearance") {
            image.isTemplate = true
            appearanceItem.image = image
        }

        let submenu = NSMenu(title: "Appearance")
        for mode in AppAppearanceMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(selectAppearanceMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            submenu.addItem(item)

            switch mode {
            case .automatic:
                automaticAppearanceMenuItem = item
            case .light:
                lightAppearanceMenuItem = item
            case .dark:
                darkAppearanceMenuItem = item
            }
        }
        appearanceItem.submenu = submenu
        viewMenu.insertItem(appearanceItem, at: 0)
        viewMenu.insertItem(.separator(), at: 1)
        syncAppearanceMenuState()
    }

    private func installContentWidthMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu,
              viewMenu.items.first(where: { $0.title == "Content Width" }) == nil else { return }

        let widthItem = NSMenuItem(title: "Content Width", action: nil, keyEquivalent: "")
        if let image = NSImage(systemSymbolName: "arrow.left.and.right.text.vertical",
                               accessibilityDescription: "Content Width") {
            image.isTemplate = true
            widthItem.image = image
        }

        let submenu = NSMenu(title: "Content Width")
        for setting in ContentWidthSetting.allCases {
            let item = NSMenuItem(title: setting.title,
                                  action: #selector(selectContentWidthSetting(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = setting.rawValue
            submenu.addItem(item)

            switch setting {
            case .normal:
                normalContentWidthMenuItem = item
            case .fullWidth:
                fullContentWidthMenuItem = item
            }
        }
        widthItem.submenu = submenu
        let insertIndex = viewMenu.items
            .firstIndex(where: { $0.title == "Appearance" })
            .map { $0 + 1 } ?? 0
        viewMenu.insertItem(widthItem, at: insertIndex)
        syncContentWidthMenuState()
    }

    private func applyAppearanceMode(_ mode: AppAppearanceMode, reloadPreviews: Bool) {
        let appearance = mode.appearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
        syncAppearanceMenuState()
        if reloadPreviews {
            reloadDocumentPreviewsForSettingChange()
        }
    }

    private func syncAppearanceMenuState() {
        let mode = AppAppearanceMode.current
        automaticAppearanceMenuItem?.state = mode == .automatic ? .on : .off
        lightAppearanceMenuItem?.state = mode == .light ? .on : .off
        darkAppearanceMenuItem?.state = mode == .dark ? .on : .off
    }

    private func syncContentWidthMenuState() {
        let setting = ContentWidthSetting.current
        normalContentWidthMenuItem?.state = setting == .normal ? .on : .off
        fullContentWidthMenuItem?.state = setting == .fullWidth ? .on : .off
    }

    private func reloadDocumentPreviewsForSettingChange() {
        NSDocumentController.shared.documents
            .flatMap(\.windowControllers)
            .compactMap { $0 as? DocumentWindowController }
            .forEach { $0.reloadPreviewForSettingChange() }
    }

    private func installAppMenuItemIcons() {
        checkForUpdatesMenuItem?.target = updaterController
        checkForUpdatesMenuItem?.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))

        guard let updatesItem = checkForUpdatesMenuItem,
              let appMenu = updatesItem.menu
        else { return }

        let cliItem = NSMenuItem(title: "Install CLI...",
                                 action: #selector(installCommandLineTools(_:)),
                                 keyEquivalent: "")
        cliItem.target = self
        appMenu.insertItem(.separator(), at: appMenu.index(of: updatesItem) + 1)
        appMenu.insertItem(cliItem, at: appMenu.index(of: updatesItem) + 2)

        let icons: [(NSMenuItem, String)] = [
            (updatesItem, "arrow.triangle.2.circlepath"),
            (cliItem, "terminal")
        ]
        for (item, symbol) in icons {
            guard let image = NSImage(systemSymbolName: symbol,
                                      accessibilityDescription: item.title)
            else { continue }
            image.isTemplate = true
            item.image = image
        }
    }

    private func installSidebarViewMenuItems() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu else { return }

        if let existing = viewMenu.items.first(where: { $0.title == "Show Sidebar" }) {
            viewMenu.removeItem(existing)
        }
        guard viewMenu.items.first(where: { $0.action == #selector(hideSidebarFromMenu(_:)) }) == nil else {
            return
        }

        let insertIndex = (viewMenu.items.firstIndex(where: { $0.isSeparatorItem }) ?? -1) + 1

        let hide = makeSidebarViewMenuItem(title: "Hide Sidebar",
                                           symbol: "sidebar.leading",
                                           keyEquivalent: "1",
                                           action: #selector(hideSidebarFromMenu(_:)))
        viewMenu.insertItem(hide, at: insertIndex)
        hideSidebarMenuItem = hide

        let outline = makeSidebarViewMenuItem(title: "Table of Contents",
                                              symbol: "list.bullet.indent",
                                              keyEquivalent: "2",
                                              action: #selector(selectOutlineMode(_:)))
        viewMenu.insertItem(outline, at: insertIndex + 1)
        outlineMenuItem = outline

        let files = makeSidebarViewMenuItem(title: "Project Navigator",
                                            symbol: "folder",
                                            keyEquivalent: "3",
                                            action: #selector(selectFilesMode(_:)))
        viewMenu.insertItem(files, at: insertIndex + 2)
        filesMenuItem = files

        viewMenu.insertItem(.separator(), at: insertIndex + 3)
    }

    private func installEditModeMenuItem() {
        guard let viewMenu = NSApp.mainMenu?.items
            .first(where: { $0.title == "View" })?.submenu,
              viewMenu.items.first(where: {
                  $0.action == #selector(toggleEditModeFromMenu(_:))
              }) == nil else { return }

        let item = NSMenuItem(title: "Toggle Edit Mode",
                              action: #selector(toggleEditModeFromMenu(_:)),
                              keyEquivalent: "e")
        item.keyEquivalentModifierMask = [.command]
        item.target = self

        let insertIndex = viewMenu.items.firstIndex(where: { $0.title == "Actual Size" })
            ?? viewMenu.numberOfItems
        viewMenu.insertItem(item, at: insertIndex)
        viewMenu.insertItem(.separator(), at: insertIndex + 1)
    }

    @objc private func toggleEditModeFromMenu(_ sender: Any?) {
        activeDocumentWindowController?.toggleEditMode()
    }

    private func installFormatMenu() {
        guard let mainMenu = NSApp.mainMenu,
              mainMenu.items.first(where: { $0.title == "Format" }) == nil else { return }

        func item(_ title: String,
                  command: String,
                  key: String = "",
                  modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title,
                                  action: #selector(formatMarkdownFromMenu(_:)),
                                  keyEquivalent: key)
            item.target = self
            item.representedObject = command
            item.keyEquivalentModifierMask = modifiers
            return item
        }

        let menu = NSMenu(title: "Format")
        menu.addItem(item("Body", command: "h0"))
        menu.addItem(item("Heading 1", command: "h1", key: "1", modifiers: [.shift, .command]))
        menu.addItem(item("Heading 2", command: "h2", key: "2", modifiers: [.shift, .command]))
        menu.addItem(item("Heading 3", command: "h3", key: "3", modifiers: [.shift, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Bold", command: "bold", key: "b"))
        menu.addItem(item("Italic", command: "italic", key: "i"))
        menu.addItem(item("Strikethrough", command: "strikethrough", key: "x", modifiers: [.shift, .command]))
        menu.addItem(item("Inline Code", command: "code", key: "`"))
        menu.addItem(item("Link", command: "link", key: "k"))
        menu.addItem(.separator())
        menu.addItem(item("Bulleted List", command: "bulletList", key: "7", modifiers: [.shift, .command]))
        menu.addItem(item("Numbered List", command: "orderedList", key: "9", modifiers: [.shift, .command]))
        menu.addItem(item("Checklist", command: "taskList", key: "l", modifiers: [.shift, .command]))
        menu.addItem(item("Block Quote", command: "quote", key: "'"))

        let rootItem = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        rootItem.submenu = menu
        let insertIndex = mainMenu.items.firstIndex(where: { $0.title == "View" })
            ?? mainMenu.items.count
        mainMenu.insertItem(rootItem, at: insertIndex)
    }

    @objc private func formatMarkdownFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        activeDocumentWindowController?.formatMarkdown(command)
    }

    private func makeSidebarViewMenuItem(title: String,
                                         symbol: String,
                                         keyEquivalent: String,
                                         action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = [.option, .command]
        item.target = self
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            image.isTemplate = true
            item.image = image
        }
        return item
    }

    private func syncSidebarViewMenuState() {
        guard let state = activeDocumentWindowController?.sidebarMenuState else {
            hideSidebarMenuItem?.state = .off
            outlineMenuItem?.state = .off
            filesMenuItem?.state = .off
            return
        }
        hideSidebarMenuItem?.state = state.sidebarVisible ? .off : .on
        outlineMenuItem?.state = (state.sidebarVisible && state.mode == .outline) ? .on : .off
        filesMenuItem?.state = (state.sidebarVisible && state.mode == .files) ? .on : .off
    }
}
