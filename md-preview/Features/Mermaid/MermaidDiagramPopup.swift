//
//  MermaidDiagramPopup.swift
//  md-preview
//
//  Floating panel that shows a rendered Mermaid SVG at a measured size.
//  Resizable — the diagram scales with the window. Behaves like a regular
//  window: it stays open when it loses key focus and closes via its close
//  button / ⌘W, so the diagram can be read alongside the document.
//

import AppKit
import WebKit

@MainActor
final class MermaidDiagramPopup: NSObject {
    static let shared = MermaidDiagramPopup()

    private var panel: NSPanel?
    private var webView: WKWebView?

    private override init() {
        super.init()
    }

    struct Request {
        let svgHTML: String
        let naturalSize: CGSize
        let displaySize: CGSize
        /// Nearest preceding Markdown heading, if any — gives the window a
        /// title that's more useful than the generic "Mermaid diagram" when
        /// reopening the popup on a different diagram.
        let sectionTitle: String?
    }

    func present(_ request: Request, relativeTo parentWindow: NSWindow?) {
        guard MermaidPopupSizing.canPresent(svgHTML: request.svgHTML) else { return }

        let screen = parentWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let contentSize = MermaidPopupSizing.preferredContentSize(
            natural: request.naturalSize,
            display: request.displaySize,
            screen: visible
        )

        let panel = ensurePanel()
        // Detach from a previous parent so re-opening re-centers correctly.
        if let currentParent = panel.parent {
            currentParent.removeChildWindow(panel)
        }
        panel.setContentSize(contentSize)

        // Frame size after setContentSize includes chrome; use it for placement.
        var frame = panel.frame
        if let parent = parentWindow {
            let parentFrame = parent.frame
            frame.origin = NSPoint(
                x: parentFrame.midX - frame.width / 2,
                y: parentFrame.midY - frame.height / 2
            )
            frame.origin = clampedOrigin(frame.origin, size: frame.size, screen: screen)
            panel.setFrame(frame, display: false)
            // Don't use addChildWindow — a child stays tied to the parent's
            // ordering/visibility. Keep it as an independent float.
        } else if let screen {
            panel.center()
            frame = panel.frame
            frame.origin = clampedOrigin(frame.origin, size: frame.size, screen: screen)
            panel.setFrame(frame, display: false)
        }

        panel.title = Self.title(for: request.sectionTitle)
        load(svgHTML: request.svgHTML)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func title(for sectionTitle: String?) -> String {
        let base = NSLocalizedString("Mermaid diagram", comment: "Mermaid diagram popup window title")
        guard let sectionTitle, !sectionTitle.isEmpty else { return base }
        return String(
            format: NSLocalizedString(
                "%@ — Mermaid diagram",
                comment: "Mermaid diagram popup window title with the nearest markdown heading for context"
            ),
            sectionTitle
        )
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.normal`, not `.floating`: a floating level keeps the panel above
        // every *other* application's windows too, which is why AppKit pairs
        // that level with `hidesOnDeactivate`. Reading the diagram alongside
        // the document only needs it to outlive losing key focus.
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: MermaidPopupSizing.minimumWidth, height: MermaidPopupSizing.minimumHeight)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        // Window resize is the zoom control; keep the page scale at 1.
        webView.allowsMagnification = false
        webView.autoresizingMask = [.width, .height]
        panel.contentView = webView

        self.panel = panel
        self.webView = webView

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )

        return panel
    }

    @objc private func panelWillClose(_ notification: Notification) {
        // Drop the heavy SVG document when the user closes the panel.
        webView?.loadHTMLString("", baseURL: nil)
    }

    private func load(svgHTML: String) {
        // Strip scripts just in case; mermaid SVGs are static markup.
        let safeSVG = MermaidPopupSizing.sanitizedSVGHTML(svgHTML)
        // Same generic label the inline figure carries, so the popup is no
        // less navigable than the diagram it was opened from.
        let label = Self.htmlAttributeEscape(
            NSLocalizedString("Mermaid diagram", comment: "Mermaid diagram popup window title")
        )

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>
          /* Let the page follow the window's appearance on its own, so
             toggling system dark mode restyles an open popup live. */
          html, body {
            margin: 0;
            width: 100%;
            height: 100%;
            overflow: hidden;
            color-scheme: light dark;
            background: #ffffff;
          }
          @media (prefers-color-scheme: dark) {
            html, body { background: #1e1e1e; }
          }
          /* Fill the web view; diagram scales with window resize. */
          .stage {
            position: absolute;
            inset: 0;
            box-sizing: border-box;
            padding: 16px;
            display: flex;
            align-items: center;
            justify-content: center;
          }
          .stage svg {
            display: block;
            width: 100%;
            height: 100%;
            max-width: 100%;
            max-height: 100%;
          }
        </style>
        </head>
        <body>
        <div class="stage" role="img" aria-label="\(label)">\(safeSVG)</div>
        </body>
        </html>
        """
        webView?.loadHTMLString(html, baseURL: nil)
    }

    private static func htmlAttributeEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize, screen: NSScreen?) -> NSPoint {
        guard let visible = screen?.visibleFrame else { return origin }
        var x = origin.x
        var y = origin.y
        // Keep the title bar reachable.
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if y + size.height > visible.maxY { y = visible.maxY - size.height }
        if x < visible.minX { x = visible.minX }
        if y < visible.minY { y = visible.minY }
        return NSPoint(x: x, y: y)
    }
}
