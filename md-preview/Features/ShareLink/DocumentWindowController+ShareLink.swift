//
//  DocumentWindowController+ShareLink.swift
//  md-preview
//
//  "Copy Link" in the Share popover. The picker closes on click, so a
//  small popover on the Share button reports progress and the result.
//

import AppKit
import Observation
import SwiftUI

extension DocumentWindowController {

    /// The Share popover row, or nil while the feature is off or the
    /// window has no saved file to link.
    func shareLinkService() -> NSSharingService? {
        guard ShareLinkFeature.isEnabled, currentFileURL != nil, currentMarkdown != nil else {
            return nil
        }
        return NSSharingService(title: L("Copy Link"),
                                image: NSImage(systemSymbolName: "link",
                                               accessibilityDescription: L("Copy Link")) ?? NSImage(),
                                alternateImage: nil) { [weak self] in
            self?.copyShareLink()
        }
    }

    private func copyShareLink() {
        guard let fileURL = currentFileURL, let markdown = currentMarkdown else { return }
        let status = ShareLinkStatus()
        let popover = showShareLinkStatus(status)

        Task { @MainActor [weak self] in
            do {
                let link = try await ShareLinkSession.link(forFile: fileURL, markdown: markdown)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                status.state = .copied
                try? await Task.sleep(for: .seconds(1.5))
                popover?.close()
            } catch {
                popover?.close()
                guard let window = self?.documentWindow else { return }
                let alert = NSAlert()
                alert.messageText = L("Could Not Copy Link")
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
    enum State { case working, copied }
    var state = State.working
}

private struct ShareLinkStatusView: View {
    let status: ShareLinkStatus

    var body: some View {
        HStack(spacing: 8) {
            switch status.state {
            case .working:
                ProgressView().controlSize(.small)
                Text(L("Creating Link…"))
            case .copied:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("Link Copied"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
    }
}
