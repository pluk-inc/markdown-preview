//
//  DocumentWindowController+ShareLink.swift
//  md-preview
//
//  The Share popover's share-link row: "Copy Link" while the file has no
//  link, "Manage Shared Document…" while it has one. The picker closes on
//  click, so a small popover on the Share button reports progress and the
//  result of creating a link.
//

import AppKit
import Observation
import SwiftUI

extension DocumentWindowController {

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
    private func confirmAndCopyShareLink() {
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

    private func createAndCopyShareLink() {
        guard let fileURL = currentFileURL, let markdown = currentMarkdown else { return }
        runShareLinkTask(working: L("Creating Link…"), done: L("Link Copied"),
                         failure: L("Could Not Copy Link")) {
            let link = try await ShareLinkSession.link(forFile: fileURL, markdown: markdown)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
        }
    }

    private func runShareLinkTask(working: String, done: String, failure: String,
                                  _ work: @escaping @MainActor () async throws -> Void) {
        let status = ShareLinkStatus(message: working)
        let popover = showShareLinkStatus(status)

        Task { @MainActor [weak self] in
            do {
                try await work()
                status.finish(done)
                try? await Task.sleep(for: .seconds(1.5))
                popover?.close()
            } catch {
                popover?.close()
                guard let window = self?.documentWindow else { return }
                let alert = NSAlert()
                alert.messageText = failure
                alert.informativeText = ShareLinkSession.message(for: error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// Anchored on the Share toolbar button, or the window's top edge when
    /// the button is not in the toolbar or has no view of its own.
    private func showShareLinkStatus(_ status: ShareLinkStatus) -> NSPopover? {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        let host = NSHostingController(rootView: ShareLinkStatusView(status: status))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        if let button = documentWindow.toolbar?.items
            .first(where: { $0.itemIdentifier == .share })?.view,
           button.window != nil {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = documentWindow.contentView {
            let anchor = NSRect(x: content.bounds.midX, y: content.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: anchor, of: content, preferredEdge: .minY)
        } else {
            return nil
        }
        return popover
    }
}

@MainActor @Observable
private final class ShareLinkStatus {
    private(set) var message: String
    private(set) var isDone = false

    init(message: String) { self.message = message }

    func finish(_ message: String) {
        self.message = message
        isDone = true
    }
}

private struct ShareLinkStatusView: View {
    let status: ShareLinkStatus

    var body: some View {
        HStack(spacing: 8) {
            if status.isDone {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(status.message)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
    }
}
