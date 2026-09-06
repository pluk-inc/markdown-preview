//
//  MermaidDiagramPopup.swift
//  md-preview
//
//  Floating panel with a stable 16:9 viewport. The diagram is fit only when
//  larger than the viewport; smaller diagrams keep their natural size.
//  Mouse-wheel zoom and pointer dragging navigate the diagram independently
//  of the panel size. Space restores the initial diagram scale and position.
//

import AppKit
import WebKit

@MainActor
private final class MermaidPopupWebView: WKWebView {
    private var pendingDeltaY = 0.0
    private var pendingClientX = 0.0
    private var pendingClientY = 0.0
    private var flushScheduled = false

    override func scrollWheel(with event: NSEvent) {
        guard event.scrollingDeltaY != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Precise devices report points; coarse wheels report small line deltas.
        pendingDeltaY += Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 8)
        pendingClientX = point.x
        pendingClientY = isFlipped ? point.y : bounds.height - point.y
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushWheel()
        }
    }

    private func flushWheel() {
        guard pendingDeltaY != 0 else {
            flushScheduled = false
            return
        }
        let deltaY = pendingDeltaY
        let clientX = pendingClientX
        let clientY = pendingClientY
        pendingDeltaY = 0
        flushScheduled = false
        evaluateJavaScript(
            "window.mdPreviewZoom?.(\(deltaY), \(clientX), \(clientY));",
            completionHandler: nil
        )
    }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        evaluateJavaScript("window.mdPreviewReset?.();", completionHandler: nil)
    }
}


@MainActor
final class MermaidDiagramPopup: NSObject, WKNavigationDelegate {
    static let shared = MermaidDiagramPopup()

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var pendingNavigation: WKNavigation?

    private override init() {
        super.init()
    }
    struct Request {
        let svgHTML: String
        /// Nearest preceding Markdown heading, if any — gives the window a
        /// title that's more useful than the generic "Mermaid diagram" when
        /// reopening the popup on a different diagram.
        let sectionTitle: String?
    }

    func present(_ request: Request, relativeTo parentWindow: NSWindow?) {
        guard MermaidPopupSizing.canPresent(svgHTML: request.svgHTML) else { return }

        let screen = parentWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let contentSize = MermaidPopupSizing.preferredContentSize(screen: visible)

        let panel = ensurePanel()
        webView?.alphaValue = 0
        // Detach from a previous parent so re-opening re-centers correctly.
        if let currentParent = panel.parent {
            currentParent.removeChildWindow(panel)
        }
        panel.setContentSize(contentSize)

        // Center on the hosting screen's visible frame, not on the document
        // window. The document can be offset or partially off-screen.
        var frame = panel.frame
        if let screen {
            let visibleFrame = screen.visibleFrame
            frame.origin = NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            )
            frame.origin = clampedOrigin(frame.origin, size: frame.size, screen: screen)
            panel.setFrame(frame, display: false)
        }

        panel.title = Self.title(for: request.sectionTitle)
        load(svgHTML: request.svgHTML)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
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
        let webView = MermaidPopupWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        // Wheel events are consumed by the native view and forwarded to the
        // popup canvas, so macOS does not turn them into page scrolling.
        webView.setValue(false, forKey: "drawsBackground")
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
        pendingNavigation = nil
        // Drop the heavy SVG document when the user closes the panel.
        webView?.loadHTMLString("", baseURL: nil)
    }

    private func load(svgHTML: String) {
        let safeSVG = MermaidPopupSizing.sanitizedSVGHTML(svgHTML)
        let label = Self.htmlAttributeEscape(
            NSLocalizedString("Mermaid diagram", comment: "Mermaid diagram popup window title")
        )

        let scriptNonce = UUID().uuidString
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(scriptNonce)'; style-src 'unsafe-inline'; img-src data:">
        <style>
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
          .stage {
            position: absolute;
            inset: 0;
            overflow: hidden;
            cursor: grab;
            touch-action: none;
            user-select: none;
          }
          .stage.dragging { cursor: grabbing; }
          .stage svg {
            position: absolute;
            left: 0;
            top: 0;
            display: block;
            transform-origin: 0 0;
            max-width: none;
          }
        </style>
        </head>
        <body>
        <div class="stage" role="img" aria-label="\(label)">\(safeSVG)</div>
        <script nonce="\(scriptNonce)">
        (() => {
          const stage = document.querySelector('.stage');
          const svg = stage.querySelector('svg');
          if (!svg) return;
          const vb = svg.viewBox.baseVal;
          const naturalWidth = vb.width || parseFloat(svg.getAttribute('width')) || 1;
          const naturalHeight = vb.height || parseFloat(svg.getAttribute('height')) || 1;
          svg.setAttribute('width', naturalWidth + 'px');
          svg.setAttribute('height', naturalHeight + 'px');
          svg.removeAttribute('style');
          let scale = 1;
          let minimumScale = 0.1;
          let tx = 0;
          let ty = 0;
          let drag;
          const apply = () => {
            svg.style.transform = `translate(${tx}px, ${ty}px) scale(${scale})`;
          };
          const center = () => {
            const availableWidth = Math.max(stage.clientWidth - 48, 1);
            const availableHeight = Math.max(stage.clientHeight - 48, 1);
            scale = Math.min(1, availableWidth / naturalWidth, availableHeight / naturalHeight);
            minimumScale = Math.min(0.1, scale / 10);
            tx = (stage.clientWidth - naturalWidth * scale) / 2;
            ty = (stage.clientHeight - naturalHeight * scale) / 2;
            apply();
          };
          window.mdPreviewReset = center;
          window.addEventListener('keydown', (event) => {
            if (event.code !== 'Space' && event.key !== ' ') return;
            event.preventDefault();
            center();
          });
          const zoomAt = (deltaY, x, y) => {
            const oldScale = scale;
            const magnitude = Math.min(Math.abs(deltaY), 40);
            const nextScale = Math.max(
              minimumScale,
              Math.min(8, oldScale * Math.exp(-Math.sign(deltaY) * magnitude * 0.015))
            );
            tx = x - (x - tx) * nextScale / oldScale;
            ty = y - (y - ty) * nextScale / oldScale;
            scale = nextScale;
            apply();
          };
          window.mdPreviewZoom = zoomAt;
          stage.addEventListener('wheel', (event) => {
            event.preventDefault();
            const rect = stage.getBoundingClientRect();
            const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? stage.clientHeight : 1;
            zoomAt(event.deltaY * unit, event.clientX - rect.left, event.clientY - rect.top);
          }, { passive: false });
          stage.addEventListener('pointerdown', (event) => {
            if (event.button !== 0) return;
            stage.setPointerCapture(event.pointerId);
            drag = { id: event.pointerId, x: event.clientX, y: event.clientY };
            stage.classList.add('dragging');
          });
          stage.addEventListener('pointermove', (event) => {
            if (!drag || drag.id !== event.pointerId) return;
            tx += event.clientX - drag.x;
            ty += event.clientY - drag.y;
            drag.x = event.clientX;
            drag.y = event.clientY;
            apply();
          });
          const stop = (event) => {
            if (!drag || drag.id !== event.pointerId) return;
            drag = null;
            stage.classList.remove('dragging');
          };
          stage.addEventListener('pointerup', stop);
          stage.addEventListener('pointercancel', stop);
          window.addEventListener('resize', center);
          center();
        })();
        </script>
        </body>
        </html>
        """
        pendingNavigation = webView?.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, navigation === pendingNavigation else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await webView.callAsyncJavaScript(
                    "await document.fonts.ready; window.mdPreviewReset();",
                    arguments: [:], in: nil, contentWorld: .page
                )
                guard let self, navigation === self.pendingNavigation else { return }
                // Wait for WebKit to render the prepared layout before revealing it.
                _ = try await webView.takeSnapshot(configuration: nil)
                guard navigation === self.pendingNavigation else { return }
                self.pendingNavigation = nil
                webView.alphaValue = 1
            } catch {
                guard let self, navigation === self.pendingNavigation else { return }
                self.pendingNavigation = nil
                self.panel?.close()
                NSApp.presentError(error)
            }
        }
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
