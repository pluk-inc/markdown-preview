import AppKit

/// WKWebView backs its obscured toolbar strip with an AppKit NSScrollPocket
/// laid out across the web view's own bounds. In centered mode the web view
/// starts at the article's leading edge, so the strip would stop there and
/// leave the gutter beside it bare. A fill cannot stand in for the missing
/// part: the pocket is a material that follows the theme, the scroll
/// position and the window's other toolbar backings.
///
/// This widens the pocket itself to span a host view. WebKit lays it out
/// again whenever its geometry updates, so the span is reapplied on every
/// frame change.
///
/// NSScrollPocket is private AppKit, observed on macOS 26 and 27. It is only
/// identified by class; everything done to it is public NSView API, and when
/// it is missing the web view keeps the strip WebKit gave it.
@MainActor
final class ToolbarPocketSpan: NSObject {
    private static let pocketClass: AnyClass? = NSClassFromString("NSScrollPocket")

    private weak var pocket: NSView?
    private weak var host: NSView?

    /// Spans the pocket WebKit added to `webView` across `host`'s width.
    /// Call when either view's geometry or `webView`'s subviews change.
    func update(pocketIn webView: NSView, spanning host: NSView) {
        self.host = host
        let found = Self.pocketClass.flatMap { pocketClass in
            webView.subviews.first { $0.isKind(of: pocketClass) }
        }
        if found !== pocket { observe(found) }
        apply()
    }

    private func observe(_ found: NSView?) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.frameDidChangeNotification, object: pocket)
        pocket = found
        guard let found else { return }
        center.addObserver(self, selector: #selector(pocketFrameDidChange(_:)),
                           name: NSView.frameDidChangeNotification, object: found)
    }

    @objc private func pocketFrameDidChange(_ notification: Notification) {
        apply()
    }

    /// Only the horizontal extent changes; WebKit keeps owning the strip's
    /// height and vertical position.
    private func apply() {
        guard let pocket, let webView = pocket.superview, let host else { return }
        let span = webView.convert(host.bounds, from: host)
        var rect = pocket.alignmentRect(forFrame: pocket.frame)
        let minX = min(span.minX, webView.bounds.minX)
        let maxX = max(span.maxX, webView.bounds.maxX)
        rect.origin.x = minX
        rect.size.width = maxX - minX
        let frame = pocket.frame(forAlignmentRect: rect)
        if !NSEqualRects(pocket.frame, frame) { pocket.frame = frame }
    }
}
