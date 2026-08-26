//
//  DocumentWindowController+DocumentOpening.swift
//  md-preview
//
//  Opening documents: tabs, windows, folders, and the open panel.
//

import Cocoa
import UniformTypeIdentifiers

extension DocumentWindowController {
    private struct ContextOpenPayload {
        let fileURL: URL
        let appURL: URL
    }

    func openInNewTab(_ fileURL: URL) {
        Self.markNextWindowAsTab()
        openDocumentWindow(for: fileURL) {
            // If the document was already open, no window was created and
            // the override wasn't consumed — don't let it leak to the next one.
            Self.nextWindowRequestsTab = false
        }
    }

    func openInNewWindow(_ fileURL: URL) {
        Self.markNextWindowAsSeparate()
        openDocumentWindow(for: fileURL) {
            // If the document was already open, no window was created and
            // the override wasn't consumed — don't let it leak to the next one.
            Self.nextWindowDeclinesTabbing = false
        }
    }

    private func openDocumentWindow(for fileURL: URL, completion: (() -> Void)? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: fileURL,
                                                 display: true) { [weak self] _, _, error in
            completion?()
            guard let self, let error else { return }
            NSAlert(error: error).beginSheetModal(for: self.documentWindow)
        }
    }

    /// Backs File > New Tab. Deliberately NOT the NSResponder
    /// `newWindowForTab(_:)` override: responding to that selector is what
    /// makes AppKit show the "+" button in the tab bar, and the app hides
    /// that button. New tabs remain file-backed, so prompt for a file and
    /// open it as a tab — an explicit tab request, unlike ⌘O.
    @objc func newDocumentTab(_ sender: Any?) {
        promptForDocument(openAsTab: true)
    }

    func openFolder(_ folderURL: URL) {
        let folderURL = folderURL.standardizedFileURL
        if currentFileURL == nil {
            documentWindow.title = folderURL.lastPathComponent
            updateWindowSubtitle()
        }
        (documentWindow.contentViewController as? MainSplitViewController)?
            .openFolder(folderURL, selectedFileURL: currentFileURL)
        documentWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
        syncSidebarMenuState()
    }

    func contextMenuEditorItems(for fileURL: URL) -> [NSMenuItem] {
        let candidates = editorCandidates(for: fileURL)
        let defaultEditor = resolveDefaultEditor(among: candidates)

        var items: [NSMenuItem] = []

        let externalItem = NSMenuItem(
            title: NSLocalizedString("Open with External Editor", comment: "Context menu item"),
            action: #selector(contextLaunchEditor(_:)),
            keyEquivalent: ""
        )
        externalItem.image = NSImage(systemSymbolName: "arrow.up.right.square",
                                     accessibilityDescription: nil)
        if let defaultEditor {
            externalItem.target = self
            externalItem.representedObject = ContextOpenPayload(fileURL: fileURL, appURL: defaultEditor.url)
            externalItem.toolTip = localizedOpenIn(displayName(for: defaultEditor.url))
        } else {
            externalItem.isEnabled = false
        }
        items.append(externalItem)

        let openAs = NSMenuItem(
            title: NSLocalizedString("Open As", comment: "Context menu submenu"),
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        if candidates.isEmpty {
            submenu.addItem(disabledItem(NSLocalizedString("No editors available", comment: "Open As empty state")))
        } else {
            for candidate in candidates {
                let item = NSMenuItem(
                    title: displayName(for: candidate.url),
                    action: #selector(contextLaunchEditor(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = ContextOpenPayload(fileURL: fileURL, appURL: candidate.url)
                let icon = NSWorkspace.shared.icon(forFile: candidate.url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                if let defaultEditor, sameEditor(candidate, defaultEditor) {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }
        openAs.submenu = submenu
        items.append(openAs)

        return items
    }

    @objc private func contextLaunchEditor(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ContextOpenPayload else { return }
        launch(payload.fileURL, with: payload.appURL)
    }

    @IBAction func openDocument(_ sender: Any?) {
        promptForDocument(openAsTab: false)
    }

    private func promptForDocument(openAsTab: Bool) {
        let panel = makeOpenPanel()
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if url.isExistingDirectory {
                self.openFolder(url)
                return
            }
            if openAsTab {
                self.openInNewTab(url)
            } else {
                // Plain open: tab placement follows the system
                // "Prefer tabs" setting via attachToExistingTabGroupIfNeeded.
                self.openDocumentWindow(for: url)
            }
        }
    }

    private func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = NSLocalizedString(
            "Choose a Markdown file or folder",
            comment: "Open panel prompt"
        )
        panel.allowedContentTypes = Self.markdownFileExtensions
            .compactMap { UTType(filenameExtension: $0) }
        return panel
    }

    func loadFile(at url: URL, silentOnFailure: Bool = false) {
        Task { @concurrent [weak self] in
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                await self?.applyLoadedMarkdown(text, fileURL: url)
            } catch {
                // Wrap as NSError (Sendable) so the original presentation —
                // localizedDescription + recovery suggestion — survives the
                // hop back to MainActor.
                let nsError = error as NSError
                await self?.applyLoadFailure(error: nsError,
                                             fileURL: url,
                                             silentOnFailure: silentOnFailure)
            }
        }
    }

    private func applyLoadedMarkdown(_ text: String, fileURL: URL) {
        guard currentFileURL?.standardizedFileURL == fileURL.standardizedFileURL else { return }
        currentMarkdown = text
        resetAutoSaveFeedback()
        updateWindowSubtitle()
        refreshOpenInLLMItem()
        updateEditToolbarItem()
        markdownDocument?.replaceContents(markdown: text, fileURL: fileURL)
        renderCurrentDocument(text: text, fileURL: fileURL)
        if pendingEditModeURL == fileURL.standardizedFileURL {
            pendingEditModeURL = nil
            enterEditMode()
        }
    }

    private func applyLoadFailure(error: NSError, fileURL: URL, silentOnFailure: Bool) {
        if pendingEditModeURL == fileURL.standardizedFileURL {
            pendingEditModeURL = nil
            dismissEditChrome()
        }
        guard !silentOnFailure else { return }
        NSAlert(error: error).beginSheetModal(for: documentWindow)
    }

    func renderCurrentDocument(text: String, fileURL: URL?) {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .display(markdown: text,
                     fileName: fileURL?.lastPathComponent
                         ?? NSLocalizedString("Untitled", comment: "Untitled document name"),
                     url: fileURL,
                     assetBaseURL: fileURL?.deletingLastPathComponent())
    }
}
