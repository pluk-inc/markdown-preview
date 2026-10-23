//
//  DocumentWindowController+ShareLink.swift
//  md-preview
//
//  The Share popover's share-link row: "Copy Link" while the file has no
//  link, "Manage Shared Document…" while it has one. The picker closes on
//  click; creating a link shows nothing unless it fails.
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
        guard ShareLinkFeature.isEnabled, let fileURL = currentFileURL, currentMarkdown != nil else {
            return []
        }
        if ShareLinkStore.shared.record(forFile: fileURL) != nil {
            let title = L("Manage Shared Document…")
            return [NSSharingService(
                title: title,
                image: NSImage(systemSymbolName: "person.crop.circle.badge.checkmark",
                               accessibilityDescription: title) ?? NSImage(),
                alternateImage: nil
            ) { [weak self] in
                self?.showManageSharedDocument()
            }]
        }
        return [NSSharingService(
            title: L("Copy Link"),
            image: NSImage(systemSymbolName: "link", accessibilityDescription: L("Copy Link")) ?? NSImage(),
            alternateImage: nil
        ) { [weak self] in
            self?.confirmAndCopyShareLink()
        }]
    }

    private func showManageSharedDocument() {
        guard let fileURL = currentFileURL, let markdown = currentMarkdown,
              let host = documentWindow.contentViewController,
              documentWindow.attachedSheet == nil
        else { return }
        ShareLinkManageSheet.present(on: host, fileURL: fileURL, markdown: markdown)
    }

    /// Creating the first link starts sharing, so it asks first.
    /// A plain alert sheet: on macOS 26 it hides the app icon and matches
    /// the system's own "Copy Link to Share" alert (ShareKit uses NSAlert).
    private func confirmAndCopyShareLink() {
        guard documentWindow.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L("Copy Link to Share")
        alert.informativeText = L("Anyone with the link can read this document, until you stop sharing or the link expires in 7 days. The document is encrypted, and only the link can open it.")
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: documentWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.createAndCopyShareLink()
        }
    }

    /// No "copied" message, as with the system's Copy rows. A slow upload
    /// shows a progress sheet that can cancel it; an error gets an alert.
    private func createAndCopyShareLink() {
        guard let fileURL = currentFileURL, let markdown = currentMarkdown else { return }
        var upload: Task<Void, Never>?
        let progress = ShareLinkProgressSheet(window: documentWindow,
                                              message: L("Uploading Document…")) {
            upload?.cancel()
        }
        upload = Task { @MainActor [weak self] in
            defer { progress.finish() }
            do {
                let link = try await ShareLinkSession.link(forFile: fileURL, markdown: markdown)
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard let window = self?.documentWindow else { return }
                let alert = NSAlert()
                alert.messageText = L("Could Not Copy Link")
                alert.informativeText = ShareLinkSession.message(for: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
