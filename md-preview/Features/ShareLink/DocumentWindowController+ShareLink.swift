//
//  DocumentWindowController+ShareLink.swift
//  md-preview
//
//  The Share popover's share-link row: "Publish to Web" while the file has no
//  link, "Manage Shared Document…" while it has one. The picker closes on
//  click; once Publish to Web has created the link, the Manage Shared Document
//  sheet opens, so the user sees it was copied and where to stop sharing.
//

import AppKit

extension DocumentWindowController {

    /// Whether the window's file has a live share link; shown as "Shared"
    /// in the window subtitle.
    var isSharedByLink: Bool {
        guard ShareLinkFeature.isEnabled, let currentFileURL else { return false }
        return ShareLinkStore.shared.record(forFile: currentFileURL) != nil
    }

    func observeShareLinks() {
        NotificationCenter.default.addObserver(self, selector: #selector(shareLinksDidChange(_:)),
                                               name: ShareLinkStore.didChangeNotification, object: nil)
    }

    @objc private func shareLinksDidChange(_ notification: Notification) {
        updateWindowSubtitle()
    }

    /// The Share popover row; none while the feature is off or the window
    /// has no saved file to link.
    func shareLinkServices() -> [NSSharingService] {
        guard ShareLinkFeature.isEnabled, currentFileURL != nil, currentMarkdown != nil,
              !isReceivedShare else {
            return []
        }
        // Same test as the "Shared" subtitle, so the row and the subtitle agree.
        let shared = isSharedByLink
        let title = shared ? L("Manage Shared Document…") : L("Publish to Web")
        let symbol = shared ? "person.crop.circle.badge.checkmark" : "globe"
        return [NSSharingService(
            title: title,
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
            alternateImage: nil
        ) { [weak self] in
            if shared { self?.showManageSharedDocument() } else { self?.confirmAndCopyShareLink() }
        }]
    }

    private func showManageSharedDocument() {
        withSharedMarkdown { [weak self] markdown in
            guard let self, let fileURL = self.currentFileURL,
                  let host = self.documentWindow.contentViewController,
                  self.documentWindow.attachedSheet == nil
            else { return }
            ShareLinkManageSheet.present(on: host, fileURL: fileURL, markdown: markdown)
        }
    }

    /// The text a link shares: while editing, the editor's live text, which
    /// `currentMarkdown` only catches up with on save or preview.
    private func withSharedMarkdown(_ body: @escaping (String) -> Void) {
        guard isEditing, let editor = mainSplit?.editorViewController else {
            if let markdown = currentMarkdown { body(markdown) }
            return
        }
        editor.fetchMarkdown { [weak self] markdown in
            guard let markdown = markdown ?? self?.currentMarkdown else { return }
            body(markdown)
        }
    }

    /// Creating the first link starts sharing, so it asks first.
    /// A plain alert sheet: on macOS 26 it hides the app icon and matches
    /// the system's own "Copy Link to Share" alert (ShareKit uses NSAlert).
    private func confirmAndCopyShareLink() {
        guard documentWindow.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L("Publish to Web")
        alert.informativeText = L("Anyone with the link can read this document, until you stop sharing or the link expires in 7 days. The document is encrypted, and only the link can open it.")
        alert.addButton(withTitle: L("Publish"))
        // Long enough that the alert stacks its buttons full width, as the
        // system's own Copy Link alert does.
        alert.addButton(withTitle: L("Keep Document Private"))
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: documentWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.createAndCopyShareLink()
        }
    }

    /// A slow upload shows a progress sheet that can cancel it; success
    /// opens the Manage Shared Document sheet; an error gets an alert.
    private func createAndCopyShareLink() {
        withSharedMarkdown { [weak self] markdown in self?.createAndCopyShareLink(markdown: markdown) }
    }

    private func createAndCopyShareLink(markdown: String) {
        guard let fileURL = currentFileURL else { return }
        var upload: Task<Void, Never>?
        let progress = ShareLinkProgressSheet(window: documentWindow,
                                              message: L("Uploading Document…")) {
            upload?.cancel()
        }
        upload = Task { @MainActor [weak self] in
            defer { progress.finish() }
            do {
                try await ShareLinkSession.copyLink(forFile: fileURL, markdown: markdown)
                progress.finish()
                guard let self, let host = self.documentWindow.contentViewController else { return }
                ShareLinkManageSheet.present(on: host, fileURL: fileURL, markdown: markdown)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard let window = self?.documentWindow else { return }
                let alert = NSAlert()
                alert.messageText = L("Could Not Publish Document")
                alert.informativeText = ShareLinkSession.message(for: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
