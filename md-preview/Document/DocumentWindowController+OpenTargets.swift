//
//  DocumentWindowController+OpenTargets.swift
//  md-preview
//
//  The Open, Open-in-LLM, and Open-With toolbar items and their menus.
//

import Cocoa

extension DocumentWindowController {
    // MARK: - Open

    /// Re-resolves the default hand-off app after Settings changes it.
    func refreshOpenTargets() {
        refreshOpenWithItem()
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
    }

    func makeOpenActionsItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .openActions)
        let open = NSLocalizedString("Open", comment: "Open toolbar item label")
        item.label = open
        item.paletteLabel = open
        item.toolTip = NSLocalizedString("Open document in another app", comment: "Open toolbar item tooltip")
        item.target = self
        item.action = #selector(openActionsPrimaryAction(_:))
        item.showsIndicator = true
        openActionsItem = item
        refreshOpenActionsItem()
        return item
    }

    func refreshOpenActionsItem() {
        let editors = currentFileURL.map { editorCandidates(for: $0) } ?? []
        let defaultEditor = resolveDefaultEditor(among: editors)
        let llmApps = llmCandidates()
        let defaultLLM = resolveDefaultLLM(among: llmApps)
        let defaultAction = resolveDefaultOpenAction(editors: editors,
                                                     defaultEditor: defaultEditor,
                                                     llmApps: llmApps,
                                                     defaultLLM: defaultLLM)

        let primaryTitle = openActionsTitle(for: defaultAction)

        openActionsItem?.label = NSLocalizedString("Open", comment: "Open toolbar item label")
        openActionsItem?.image = openActionsImage(for: defaultAction)
        openActionsItem?.toolTip = primaryTitle ?? NSLocalizedString(
            "Open document in another app",
            comment: "Open toolbar item tooltip"
        )
        openActionsItem?.menu = buildOpenActionsMenu(editorCandidates: editors,
                                                     llmCandidates: llmApps,
                                                     defaultAction: defaultAction)
    }

    private func openActionsTitle(for selection: OpenActionSelection?) -> String? {
        switch selection {
        case .editor(let editor):
            return localizedOpenIn(displayName(for: editor.url))
        case .llm(let candidate):
            return localizedOpenIn(candidate.target.title)
        case nil:
            return nil
        }
    }

    func localizedOpenIn(_ applicationName: String) -> String {
        String(
            format: NSLocalizedString("Open in %@", comment: "Open toolbar item for a named application"),
            applicationName
        )
    }

    private func openActionsImage(for selection: OpenActionSelection?) -> NSImage {
        switch selection {
        case .editor(let editor):
            let editorURL = editor.url
            return openWithImage(for: editorURL)
        case .llm(let candidate):
            return openInLLMImage(for: candidate)
        case nil:
            return openWithImage(for: nil)
        }
    }

    private func resolveDefaultOpenAction(editors: [EditorCandidate],
                                          defaultEditor: EditorCandidate?,
                                          llmApps: [LLMCandidate],
                                          defaultLLM: LLMCandidate?) -> OpenActionSelection? {
        OpenTargetCatalog.resolveDefaultOpenAction(editors: editors,
                                                   defaultEditor: defaultEditor,
                                                   llmApps: llmApps,
                                                   defaultLLM: defaultLLM)
    }

    private func buildOpenActionsMenu(editorCandidates: [EditorCandidate],
                                      llmCandidates: [LLMCandidate],
                                      defaultAction: OpenActionSelection?) -> NSMenu {
        let menu = NSMenu()

        guard currentFileURL != nil else {
            menu.addItem(disabledItem(NSLocalizedString("No document open", comment: "Open menu empty state")))
            return menu
        }

        if editorCandidates.isEmpty && llmCandidates.isEmpty {
            menu.addItem(disabledItem(NSLocalizedString("No apps available", comment: "Open menu empty state")))
            return menu
        }

        if !llmCandidates.isEmpty {
            let header = NSMenuItem()
            header.title = NSLocalizedString("AI Apps", comment: "Open menu section header")
            header.isEnabled = false
            menu.addItem(header)

            for candidate in llmCandidates {
                let item = NSMenuItem(
                    title: candidate.target.title,
                    action: #selector(pickLLMTarget(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = candidate.target.id
                let icon = NSWorkspace.shared.icon(forFile: candidate.appURL.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                if case .llm(let selectedLLM) = defaultAction,
                   candidate.target.id == selectedLLM.target.id {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        if !editorCandidates.isEmpty {
            if !llmCandidates.isEmpty {
                menu.addItem(.separator())
            }

            let header = NSMenuItem()
            header.title = NSLocalizedString("Editors", comment: "Open menu section header")
            header.isEnabled = false
            menu.addItem(header)

            for candidate in editorCandidates {
                let item = NSMenuItem(
                    title: displayName(for: candidate.url),
                    action: #selector(pickEditor(_:)),
                    keyEquivalent: ""
                )
                let icon = NSWorkspace.shared.icon(forFile: candidate.url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                item.target = self
                item.representedObject = candidate
                if case .editor(let selectedEditor) = defaultAction,
                   sameEditor(candidate, selectedEditor) {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        return menu
    }

    @objc private func openActionsPrimaryAction(_ sender: Any?) {
        guard let fileURL = currentFileURL else { return }
        let editors = editorCandidates(for: fileURL)
        let defaultEditor = resolveDefaultEditor(among: editors)
        let llmApps = llmCandidates()
        let defaultLLM = resolveDefaultLLM(among: llmApps)
        guard let defaultAction = resolveDefaultOpenAction(editors: editors,
                                                           defaultEditor: defaultEditor,
                                                           llmApps: llmApps,
                                                           defaultLLM: defaultLLM) else {
            NSSound.beep()
            return
        }

        switch defaultAction {
        case .editor(let editor):
            launch(fileURL, with: editor.url)
        case .llm(let target):
            openInLLM(target, fileURL: fileURL)
        }
    }

    // MARK: - Open in LLM

    private static let llmDeepLinkCharacterLimit = 12_000
    private static let claudeColdLaunchDeepLinkDelay: TimeInterval = 1.25
    private static let chatGPTColdLaunchFileOpenDelay: TimeInterval = 1.25

    var hasLLMTargetsAvailable: Bool {
        !llmCandidates().isEmpty
    }

    func makeOpenInLLMItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .openInLLM)
        let openInLLM = NSLocalizedString("Open in LLM", comment: "Open in LLM toolbar item label")
        item.label = openInLLM
        item.paletteLabel = openInLLM
        item.toolTip = NSLocalizedString("Open document in an LLM app", comment: "Open in LLM toolbar item tooltip")
        item.target = self
        item.action = #selector(openInLLMPrimaryAction(_:))
        item.showsIndicator = true
        openInLLMItem = item
        refreshOpenInLLMItem()
        return item
    }

    func refreshOpenInLLMItem() {
        let candidates = llmCandidates()
        guard !candidates.isEmpty else {
            removeOpenInLLMToolbarItem()
            return
        }
        let resolvedDefault = resolveDefaultLLM(among: candidates)
        let openInTitle = resolvedDefault.map { localizedOpenIn($0.target.title) }
        openInLLMItem?.label = openInTitle ?? NSLocalizedString("Open in LLM", comment: "Open in LLM toolbar item label")
        openInLLMItem?.image = openInLLMImage(for: resolvedDefault)
        openInLLMItem?.toolTip = openInTitle ?? NSLocalizedString(
            "Open document in an LLM app",
            comment: "Open in LLM toolbar item tooltip"
        )
        openInLLMItem?.menu = buildOpenInLLMMenu(candidates: candidates,
                                                 defaultTarget: resolvedDefault)
    }

    private func removeOpenInLLMToolbarItem() {
        guard let toolbar = documentWindow.toolbar,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .openInLLM }) else {
            return
        }
        toolbar.removeItem(at: index)
    }

    func openInLLMImage(for candidate: LLMCandidate?) -> NSImage {
        if let appURL = candidate?.appURL {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 20, height: 20)
            return icon
        }
        return NSImage(systemSymbolName: "sparkles",
                       accessibilityDescription: NSLocalizedString("Open in LLM", comment: "Open in LLM toolbar image")) ?? NSImage()
    }

    func llmCandidates() -> [LLMCandidate] {
        OpenTargetCatalog.llmCandidates()
    }

    func resolveDefaultLLM(among candidates: [LLMCandidate]) -> LLMCandidate? {
        OpenTargetCatalog.resolveDefaultLLM(among: candidates)
    }

    private func buildOpenInLLMMenu(candidates: [LLMCandidate],
                                    defaultTarget: LLMCandidate?) -> NSMenu {
        let menu = NSMenu()

        guard currentFileURL != nil else {
            menu.addItem(disabledItem(NSLocalizedString("No document open", comment: "Open menu empty state")))
            return menu
        }
        guard !candidates.isEmpty else {
            menu.addItem(disabledItem(NSLocalizedString("No LLM apps available", comment: "Open menu empty state")))
            return menu
        }

        let header = NSMenuItem()
        header.title = NSLocalizedString("Open in LLM…", comment: "Open in LLM menu header")
        header.isEnabled = false
        menu.addItem(header)

        for candidate in candidates {
            let item = NSMenuItem(
                title: candidate.target.title,
                action: #selector(pickLLMTarget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.target.id
            let icon = NSWorkspace.shared.icon(forFile: candidate.appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            if let defaultTarget, candidate.target.id == defaultTarget.target.id {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func openInLLMPrimaryAction(_ sender: Any?) {
        guard let fileURL = currentFileURL else { return }
        let candidates = llmCandidates()
        guard let target = resolveDefaultLLM(among: candidates) else {
            NSSound.beep()
            return
        }
        openInLLM(target, fileURL: fileURL)
    }

    @objc private func pickLLMTarget(_ sender: NSMenuItem) {
        guard let targetID = sender.representedObject as? String,
              let candidate = llmCandidates().first(where: { $0.target.id == targetID }),
              let fileURL = currentFileURL else { return }
        OpenTargetCatalog.setDefaultLLM(candidate)
        refreshOpenInLLMItem()
        refreshOpenActionsItem()
        openInLLM(candidate, fileURL: fileURL)
    }

    func openInLLM(_ candidate: LLMCandidate, fileURL: URL) {
        let folderURL = fileURL.deletingLastPathComponent()

        switch candidate.target.handoff {
        case .codexDesktop:
            let prompt = llmPathPrompt(for: fileURL)
            if let url = codexDeepLink(prompt: prompt, folderURL: folderURL) {
                NSWorkspace.shared.open(url)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        case .claudeCodeDesktop:
            let prompt = llmEmbeddedMarkdownPrompt(for: fileURL)
            if prompt.count <= Self.llmDeepLinkCharacterLimit,
               let url = claudeCodeDeepLink(prompt: prompt, folderURL: folderURL) {
                openDeepLink(url, afterLaunchingIfNeeded: candidate, delay: Self.claudeColdLaunchDeepLinkDelay)
            } else {
                copyPromptAndOpen(candidate: candidate, prompt: prompt)
            }
        case .chatGPTDocumentOpen:
            openDocumentInChatGPT(fileURL, candidate: candidate)
        default:
            let prompt = llmPathPrompt(for: fileURL)
            copyPromptAndOpen(candidate: candidate, prompt: prompt)
        }
    }

    private func openDeepLink(_ url: URL, afterLaunchingIfNeeded candidate: LLMCandidate, delay: TimeInterval) {
        guard !isRunning(candidate) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: candidate.appURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSSound.beep()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func openDocumentInChatGPT(_ fileURL: URL, candidate: LLMCandidate) {
        if isRunning(candidate) {
            sendDocumentOpenEventToChatGPT(fileURL, candidate: candidate)
            return
        }

        let delay = Self.chatGPTColdLaunchFileOpenDelay
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: candidate.appURL,
            configuration: configuration
        ) { [weak self] _, error in
            if error != nil {
                NSSound.beep()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.sendDocumentOpenEventToChatGPT(fileURL, candidate: candidate)
            }
        }
    }

    private func isRunning(_ candidate: LLMCandidate) -> Bool {
        candidate.target.bundleIDs.contains { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
    }

    private func sendDocumentOpenEventToChatGPT(_ fileURL: URL, candidate: LLMCandidate) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: candidate.appURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSSound.beep()
            }
        }
    }

    private func copyPromptAndOpen(candidate: LLMCandidate, prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: candidate.appURL,
            configuration: configuration
        ) { _, _ in }
    }

    private func codexDeepLink(prompt: String, folderURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "new"
        components.queryItems = [
            URLQueryItem(name: "prompt", value: prompt),
            URLQueryItem(name: "path", value: folderURL.path)
        ]
        return components.url
    }

    private func claudeCodeDeepLink(prompt: String, folderURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "q", value: prompt),
            URLQueryItem(name: "folder", value: folderURL.path)
        ]
        return components.url
    }

    private func llmPathPrompt(for fileURL: URL) -> String {
        """
        Open this Markdown file and use it as the working context:
        \(fileURL.path)
        """
    }

    private func llmEmbeddedMarkdownPrompt(for fileURL: URL) -> String {
        guard let markdown = currentMarkdown
                ?? (try? String(contentsOf: fileURL, encoding: .utf8)),
              !markdown.isEmpty else {
            return llmPathPrompt(for: fileURL)
        }

        return """
        Use this Markdown document as the working context.

        The local path is included only as a reference. Do not rely on opening it to read the document contents.

        File name: \(fileURL.lastPathComponent)
        Local path: \(fileURL.path)

        Markdown content:
        ````markdown
        \(markdown)
        ````
        """
    }

    // MARK: - Open With

    static let markdownFileExtensions = ["md", "markdown", "mdown", "txt"]

    func makeOpenWithItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .openWith)
        let openWith = NSLocalizedString("Open With", comment: "Open With toolbar item label")
        item.label = openWith
        item.paletteLabel = openWith
        item.toolTip = NSLocalizedString("Open in another editor", comment: "Open With toolbar item tooltip")
        item.target = self
        item.action = #selector(openWithPrimaryAction(_:))
        item.showsIndicator = true
        openWithItem = item
        refreshOpenWithItem()
        return item
    }

    func refreshOpenWithItem() {
        let candidates = currentFileURL.map { editorCandidates(for: $0) } ?? []
        let resolvedDefault = resolveDefaultEditor(among: candidates)
        let openInTitle = resolvedDefault.map { localizedOpenIn(displayName(for: $0.url)) }
        openWithItem?.label = openInTitle ?? NSLocalizedString("Open With", comment: "Open With toolbar item label")
        openWithItem?.image = openWithImage(for: resolvedDefault?.url)
        openWithItem?.toolTip = openInTitle ?? NSLocalizedString(
            "Open in another editor",
            comment: "Open With toolbar item tooltip"
        )
        openWithItem?.menu = buildOpenWithMenu(candidates: candidates,
                                               defaultEditor: resolvedDefault)
    }

    func openWithImage(for url: URL?) -> NSImage {
        if let url {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 20, height: 20)
            return icon
        }
        return NSImage(systemSymbolName: "highlighter",
                       accessibilityDescription: NSLocalizedString("Open With", comment: "Open With toolbar image")) ?? NSImage()
    }

    @objc private func openWithPrimaryAction(_ sender: Any?) {
        guard let fileURL = currentFileURL else { return }
        let candidates = editorCandidates(for: fileURL)
        if let editor = resolveDefaultEditor(among: candidates) {
            launch(fileURL, with: editor.url)
        }
    }

    func editorCandidates(for fileURL: URL) -> [EditorCandidate] {
        OpenTargetCatalog.editorCandidates(for: fileURL)
    }

    func resolveDefaultEditor(among candidates: [EditorCandidate]) -> EditorCandidate? {
        OpenTargetCatalog.resolveDefaultEditor(among: candidates)
    }

    private func buildOpenWithMenu(candidates: [EditorCandidate],
                                   defaultEditor: EditorCandidate?) -> NSMenu {
        let menu = NSMenu()

        guard currentFileURL != nil else {
            menu.addItem(disabledItem(NSLocalizedString("No document open", comment: "Open menu empty state")))
            return menu
        }
        guard !candidates.isEmpty else {
            menu.addItem(disabledItem(NSLocalizedString("No editors available", comment: "Open menu empty state")))
            return menu
        }

        let header = NSMenuItem()
        header.title = NSLocalizedString("Open with…", comment: "Open With menu header")
        header.isEnabled = false
        menu.addItem(header)

        for candidate in candidates {
            let item = NSMenuItem(
                title: displayName(for: candidate.url),
                action: #selector(pickEditor(_:)),
                keyEquivalent: ""
            )
            let icon = NSWorkspace.shared.icon(forFile: candidate.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.target = self
            item.representedObject = candidate
            if let defaultEditor, sameEditor(candidate, defaultEditor) {
                item.state = .on
            }
            menu.addItem(item)
        }
        return menu
    }

    func displayName(for appURL: URL) -> String {
        OpenTargetCatalog.displayName(for: appURL)
    }

    func sameEditor(_ lhs: EditorCandidate, _ rhs: EditorCandidate) -> Bool {
        OpenTargetCatalog.sameEditor(lhs, rhs)
    }

    private func sameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
        OpenTargetCatalog.sameApplication(lhs, rhs)
    }

    private func canonicalAppURL(_ url: URL) -> URL {
        OpenTargetCatalog.canonicalAppURL(url)
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func pickEditor(_ sender: NSMenuItem) {
        guard let candidate = sender.representedObject as? EditorCandidate,
              let fileURL = currentFileURL else { return }
        OpenTargetCatalog.setDefaultEditor(candidate)
        refreshOpenWithItem()
        refreshOpenActionsItem()
        launch(fileURL, with: candidate.url)
    }

    func launch(_ fileURL: URL, with appURL: URL) {
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }
}
