//
//  MermaidDiagramPopup.swift
//  md-preview
//
//  Floating panel that shows a rendered Mermaid SVG at a measured size.
//  Resizable — the diagram scales with the window. Closes on resign-key.
//

import AppKit
import WebKit

@MainActor
final class MermaidDiagramPopup: NSObject {
    static let shared = MermaidDiagramPopup()

    private var panel: NSPanel?
    private var webView: WKWebView?
    /// Ignores the first resign-key that can fire while the panel is still
    /// being ordered front (e.g. parent briefly re-keying).
    private var ignoreResignUntil: Date = .distantPast

    private override init() {
        super.init()
    }

    struct Request {
        let svgHTML: String
        let naturalSize: CGSize
        let displaySize: CGSize
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
            // Don't use addChildWindow — a child stays tied to the parent and
            // complicates resign-key / focus. Keep it as an independent float.
        } else if let screen {
            panel.center()
            frame = panel.frame
            frame.origin = clampedOrigin(frame.origin, size: frame.size, screen: screen)
            panel.setFrame(frame, display: false)
        }

        load(svgHTML: request.svgHTML, in: panel)
        ignoreResignUntil = Date().addingTimeInterval(0.25)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = NSLocalizedString("Mermaid diagram", comment: "Mermaid diagram popup window title")
        panel.isFloatingPanel = true
        panel.level = .floating
        // We close ourselves on resign; don't leave a hidden panel around.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 200)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        // Become key so didResignKey fires when the user clicks elsewhere.
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        return panel
    }

    @objc private func panelWillClose(_ notification: Notification) {
        // Drop the heavy SVG document when the user closes the panel.
        webView?.loadHTMLString("", baseURL: nil)
    }

    @objc private func panelDidResignKey(_ notification: Notification) {
        closeIfUnfocused()
    }

    @objc private func appDidResignActive(_ notification: Notification) {
        closeIfUnfocused()
    }

    private func closeIfUnfocused() {
        guard let panel, panel.isVisible else { return }
        if Date() < ignoreResignUntil { return }
        panel.close()
    }

    private func load(svgHTML: String, in panel: NSPanel) {
        let appearance = panel.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = isDark ? "#1e1e1e" : "#ffffff"
        // Strip scripts just in case; mermaid SVGs are static markup.
        let safeSVG = MermaidPopupSizing.sanitizedSVGHTML(svgHTML)

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html, body {
            margin: 0;
            width: 100%;
            height: 100%;
            overflow: hidden;
            background: \(background);
            color-scheme: \(isDark ? "dark" : "light");
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
        <div class="stage">\(safeSVG)</div>
        <script>
          (function () {
            var svg = document.querySelector('.stage svg');
            if (!svg) return;
            // Drive layout purely from viewBox so CSS width/height can
            // stretch/shrink the graphic with the window.
            svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
            svg.removeAttribute('width');
            svg.removeAttribute('height');
            svg.style.width = '100%';
            svg.style.height = '100%';
            svg.style.maxWidth = '100%';
            svg.style.maxHeight = '100%';
          })();
        </script>
        </body>
        </html>
        """
        webView?.loadHTMLString(html, baseURL: nil)
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
