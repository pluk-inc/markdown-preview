//
//  ShareAsLinkTip.swift
//  md-preview
//
//  A TipKit popover on the Share toolbar button that points out Share as
//  Link. The row itself lives in the system share picker, which apps cannot
//  anchor a popover to, so the tip anchors to the button that opens it. It
//  shows in the key window only, and stops for good once the user opens the
//  share picker, shares the file, closes the tip, or opens a file that
//  already has a link, or after it has shown three times.
//

import AppKit
import SwiftUI
import TipKit

struct ShareAsLinkTip: Tip {
    /// The id from when the feature was named Publish to Web, so TipKit keeps
    /// its saved state and a tip the user already retired stays retired.
    var id: String { "PublishToWebTip" }
    var title: Text { Text(NSLocalizedString("Share as Link", comment: "Tip title")) }
    var message: Text? {
        Text(NSLocalizedString(
            "Create a link anyone can use to read this document in a web browser.",
            comment: "Tip message"))
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(3)] }

    /// Closed, acted on, or shown its maximum number of times.
    var isRetired: Bool {
        if case .invalidated = status { true } else { false }
    }
}

extension DocumentWindowController {

    /// TipKit wants one configure call per launch, before any tip shows.
    /// Weekly only spaces out different tips: a tip that has already shown
    /// returns on each window switch, and each return counts toward its
    /// MaxDisplayCount.
    private static let tipsConfigured: Void = {
        try? Tips.configure([.displayFrequency(.weekly)])
    }()

    func startShareAsLinkTip() {
        guard canShareAsLink, shareAsLinkTipTask == nil else { return }
        let alreadyShared = isSharedByLink
        let tip = ShareAsLinkTip()
        // Async, so TipKit's setup and store load stay off the launch path:
        // the first window becomes key while the app is still launching.
        shareAsLinkTipTask = Task { @MainActor [weak self] in
            _ = Self.tipsConfigured
            guard !tip.isRetired else { return }
            // A file with a link means the user has already shared it.
            if alreadyShared { return tip.invalidate(reason: .actionPerformed) }
            for await shouldDisplay in tip.shouldDisplayUpdates {
                guard let self else { return }
                if shouldDisplay { self.showShareAsLinkTip(tip) } else { self.dismissShareAsLinkTip() }
            }
        }
    }

    /// A new file loaded in the window: retire the tip if the file already has
    /// a link, hide it if the file cannot be shared, or start it if the
    /// window became key before the file loaded.
    func refreshShareAsLinkTip() {
        guard documentWindow.isKeyWindow else { return }
        if isSharedByLink || !canShareAsLink { stopShareAsLinkTip() }
        startShareAsLinkTip()
    }

    func stopShareAsLinkTip() {
        shareAsLinkTipTask?.cancel()
        shareAsLinkTipTask = nil
        dismissShareAsLinkTip()
    }

    /// The user found the feature: never show the tip again.
    func invalidateShareAsLinkTip() {
        stopShareAsLinkTip()
        _ = Self.tipsConfigured
        let tip = ShareAsLinkTip()
        if !tip.isRetired { tip.invalidate(reason: .actionPerformed) }
    }

    private func showShareAsLinkTip(_ tip: ShareAsLinkTip) {
        guard shareAsLinkTipPopover == nil, canShareAsLink,
              let toolbar = documentWindow.toolbar, toolbar.isVisible,
              let shareItem = toolbar.items.first(where: { $0.itemIdentifier == .share })
        else { return }
        // TipNSPopover sizes itself to one long line of text and cannot be
        // narrowed, so host the tip's SwiftUI view at a fixed width instead.
        let host = NSHostingController(rootView: TipView(tip)
            .tipBackground(.clear)
            // The last line's descender room reads as extra space below.
            .padding(.bottom, -3)
            .frame(width: 300))
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.contentViewController = host
        popover.behavior = .applicationDefined
        shareAsLinkTipPopover = popover
        popover.show(relativeTo: shareItem)
    }

    private func dismissShareAsLinkTip() {
        shareAsLinkTipPopover?.close()
        shareAsLinkTipPopover = nil
    }
}
