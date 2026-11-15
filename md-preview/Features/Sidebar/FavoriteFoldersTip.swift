//
//  FavoriteFoldersTip.swift
//  md-preview
//
//  A TipKit popover on the file sidebar's folder button that points out
//  the favorite folders. It shows in the key window only, and stops for
//  good once the user opens the folder menu, adds a favorite, closes the
//  tip, or after it has shown three times.
//

import AppKit
import SwiftUI
import TipKit

struct FavoriteFoldersTip: Tip {
    var title: Text { Text(NSLocalizedString("Favorite Folders", comment: "Tip title")) }
    var message: Text? {
        Text(NSLocalizedString("Add folders you use often, and switch between them here.", comment: "Tip message"))
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(3)] }
}

extension FavoriteFoldersTip {
    /// Closed, acted on, or shown its maximum number of times.
    var isRetired: Bool {
        if case .invalidated = status { true } else { false }
    }

    /// TipKit wants one configure call per launch, before any tip shows.
    @MainActor static let configured: Void = {
        #if DEBUG
        // `-MarkdownPreview.showAllTips YES` forgets that the tip was shown
        // or closed, to check it again.
        if UserDefaults.standard.bool(forKey: "MarkdownPreview.showAllTips") {
            try? Tips.resetDatastore()
            Tips.showAllTipsForTesting()
        }
        #endif
        try? Tips.configure()
    }()
}

/// Shows the tip beside `anchor` while the owner says it can show.
@MainActor
final class FavoriteFoldersTipPresenter {
    private weak var anchor: NSView?
    private var task: Task<Void, Never>?
    private var popover: NSPopover?

    init(anchor: NSView) {
        self.anchor = anchor
    }

    /// Starts the tip when the folder button is on screen in the key
    /// window, and hides it otherwise.
    func update(canShow: Bool) {
        guard canShow else { return stop() }
        guard task == nil else { return }
        let tip = FavoriteFoldersTip()
        // Async, so TipKit's setup and store load stay off the launch path.
        task = Task { @MainActor [weak self] in
            _ = FavoriteFoldersTip.configured
            guard !tip.isRetired else { return }
            // A favorite means the user has already found the feature.
            if !FavoriteFolders.all.isEmpty { return tip.invalidate(reason: .actionPerformed) }
            for await shouldDisplay in tip.shouldDisplayUpdates {
                guard let self else { return }
                if shouldDisplay { self.show(tip) } else { self.dismiss() }
            }
        }
    }

    /// The user found the feature: never show the tip again.
    func invalidate() {
        stop()
        _ = FavoriteFoldersTip.configured
        let tip = FavoriteFoldersTip()
        if !tip.isRetired { tip.invalidate(reason: .actionPerformed) }
    }

    private func stop() {
        task?.cancel()
        task = nil
        dismiss()
    }

    private func show(_ tip: FavoriteFoldersTip) {
        guard popover == nil, let anchor, anchor.window != nil else { return }
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
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    private func dismiss() {
        popover?.close()
        popover = nil
    }
}
