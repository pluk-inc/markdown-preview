//
//  DocumentFetchIndicator.swift
//  md-preview
//
//  The same "Loading…" panel as a slow file read, for a document that is
//  still coming from the network: a shared link, or the release notes.
//  There is no page for it yet — the window or tab opens only when the
//  download ends — so the panel floats over the front window, or in the
//  middle of the screen when the app has no window.
//

import Cocoa

@MainActor
final class DocumentFetchIndicator {
    static let shared = DocumentFetchIndicator()

    /// The same delay as a slow file read: a download that ends inside it
    /// never flashes the panel.
    private static let delay: TimeInterval = 0.2

    private var activeFetches = 0
    private var pendingShow: DispatchWorkItem?
    private var panel: NSPanel?

    /// Shows the panel while `fetch` runs. Wrap only the waiting, not a
    /// prompt or an alert: the panel would sit behind it.
    func during<T>(_ fetch: () async throws -> T) async rethrows -> T {
        begin()
        defer { end() }
        return try await fetch()
    }

    private func begin() {
        activeFetches += 1
        guard activeFetches == 1 else { return }
        let work = DispatchWorkItem { [weak self] in self?.show() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    private func end() {
        activeFetches -= 1
        guard activeFetches == 0 else { return }
        pendingShow?.cancel()
        pendingShow = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }

    private func show() {
        pendingShow = nil
        guard panel == nil else { return }
        let content = DocumentLoadingOverlayView()
        let size = content.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content

        // Over the window the document will open in or beside, so the
        // reader sees it where they are looking.
        // In the background the app has no main window; the front document
        // window stands in.
        let host = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.orderedWindows.first {
            $0.isVisible && $0.windowController is DocumentWindowController
        }
        let area = host?.frame ?? (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                     y: (area.midY - size.height / 2).rounded()))
        if let host {
            host.addChildWindow(panel, ordered: .above)
        } else {
            panel.level = .floating
            panel.orderFrontRegardless()
        }
        self.panel = panel
    }
}
