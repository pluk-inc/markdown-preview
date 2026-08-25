import Foundation

/// Serializes cancellation with callbacks for a `WKURLSchemeTask`.
///
/// WebKit raises an Objective-C exception if a scheme handler sends any
/// callback after `stop(_:)` returns. Holding the recursive lock while a
/// callback runs gives `stop()` a precise boundary: it either cancels before
/// the callback starts, or waits for that callback and prevents the next one.
nonisolated final class URLSchemeTaskCallbackGate: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var isStopped = false

    func performIfActive(_ callback: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !isStopped else { return }
        callback()
    }

    func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
    }
}
