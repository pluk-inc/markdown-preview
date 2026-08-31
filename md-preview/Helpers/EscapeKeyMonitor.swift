//
//  EscapeKeyMonitor.swift
//  md-preview
//
//  Escape handling for surfaces AppKit does not route `cancelOperation(_:)`
//  to. A transient popover dismisses on an outside click by itself, but its
//  SwiftUI content never takes key focus, so nothing in the responder chain
//  ever sees the keystroke — a local key monitor does.
//
//  Sheets and windows do not need this: they are key, so overriding
//  `cancelOperation(_:)` is the right mechanism there.
//

import Cocoa

@MainActor
final class EscapeKeyMonitor {
    private static let escapeKeyCode: UInt16 = 53
    private var monitor: Any?

    /// Starts watching for Escape. `handler` returns true when it consumed
    /// the keystroke, which stops the event going any further.
    func start(_ handler: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.escapeKeyCode else { return event }
            // The monitor runs on the main thread; NSEvent simply is not
            // Sendable, so the isolation has to be asserted rather than
            // inferred across the closure boundary.
            let consumed = MainActor.assumeIsolated { handler() }
            return consumed ? nil : event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}
