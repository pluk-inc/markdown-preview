//
//  PublishToWebTip.swift
//  md-preview
//
//  A TipKit popover on the Share toolbar button that points out Publish to
//  Web. The row itself lives in the system share picker, which apps cannot
//  anchor a popover to, so the tip anchors to the button that opens it. It
//  shows in the key window only, and stops for good once the user opens the
//  share picker, publishes, closes the tip, or opens a file that already has
//  a link, or after it has shown three times.
//

import AppKit
import SwiftUI
import TipKit

struct PublishToWebTip: Tip {
    var title: Text { Text(NSLocalizedString("Publish to Web", comment: "Tip title")) }
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
    /// Weekly, so a tip the user has not acted on does not return on every
    /// window switch.
    private static let tipsConfigured: Void = {
        try? Tips.configure([.displayFrequency(.weekly)])
    }()

    func startPublishToWebTip() {
        guard canPublishToWeb, publishTipTask == nil else { return }
        let alreadyShared = isSharedByLink
        let tip = PublishToWebTip()
        // Async, so TipKit's setup and store load stay off the launch path:
        // the first window becomes key while the app is still launching.
        publishTipTask = Task { @MainActor [weak self] in
            _ = Self.tipsConfigured
            guard !tip.isRetired else { return }
            // A file with a link means the user has already published.
            if alreadyShared { return tip.invalidate(reason: .actionPerformed) }
            for await shouldDisplay in tip.shouldDisplayUpdates {
                guard let self else { return }
                if shouldDisplay { self.showPublishToWebTip(tip) } else { self.dismissPublishToWebTip() }
            }
        }
    }

    /// A new file loaded in the window: retire the tip if the file already has
    /// a link, or start it if the window became key before the file loaded.
    func refreshPublishToWebTip() {
        guard documentWindow.isKeyWindow else { return }
        if isSharedByLink { stopPublishToWebTip() }
        startPublishToWebTip()
    }

    func stopPublishToWebTip() {
        publishTipTask?.cancel()
        publishTipTask = nil
        dismissPublishToWebTip()
    }

    /// The user found the feature: never show the tip again.
    func invalidatePublishToWebTip() {
        stopPublishToWebTip()
        _ = Self.tipsConfigured
        let tip = PublishToWebTip()
        if !tip.isRetired { tip.invalidate(reason: .actionPerformed) }
    }

    private func showPublishToWebTip(_ tip: PublishToWebTip) {
        guard publishTipPopover == nil, canPublishToWeb,
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
        publishTipPopover = popover
        popover.show(relativeTo: shareItem)
    }

    private func dismissPublishToWebTip() {
        publishTipPopover?.close()
        publishTipPopover = nil
    }
}
