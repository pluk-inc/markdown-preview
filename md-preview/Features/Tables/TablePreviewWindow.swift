import AppKit
import WebKit

/// A read-only snapshot of one table, using the regular sanitized renderer and
/// link/asset policies. The source document and its editing state stay intact.
/// It opens as an ordinary window: the reader decides whether to make it
/// fullscreen, minimize it, or resize it, and Escape closes it. It opens at
/// the text size of the view it came from; zooming it does not change the
/// saved text size.
@MainActor
final class TablePreviewWindow: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = TablePreviewWindow()
    private var tableWindow: NSWindow?
    private var preview: MarkdownWebView?
    private var escapeMonitor: Any?

    func present(markdown: String, title: String?, assetBaseURL: URL?, pageZoom: CGFloat,
                 relativeTo parent: NSWindow?) {
        guard !markdown.isEmpty else { return }
        let window: NSWindow
        let preview: MarkdownWebView
        if let existing = tableWindow, let existingPreview = self.preview {
            window = existing
            preview = existingPreview
        } else {
            let frame = (parent?.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1100, height: 800)
            window = NSWindow(contentRect: frame.insetBy(dx: 32, dy: 32),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]
            window.setFrameAutosaveName("TablePreviewWindow")
            window.delegate = self
            preview = MarkdownWebView(frame: .zero)
            // Fill the table window independently of the document's reading
            // column and custom margins. Keep the standard theme and fonts.
            preview.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
                const tableWindowStyle = document.createElement('style');
                tableWindowStyle.textContent = `
                    body { padding: 24px !important; }
                    article.markdown-body { max-width: none !important; margin: 0 !important; }
                    .md-table-actions { display: none !important; }
                    .md-table-wrap { padding-top: 0 !important; margin-top: 0 !important; }
                    /* The header row sticks to the window, so the page
                       must be the only scroller: the article and the table
                       scroll horizontally in the document. A theme page
                       color wins over the default background here. */
                    html { overflow-x: auto !important; }
                    :where(html) { background: -apple-system-text-background; }
                    article.markdown-body, table { overflow: visible; }
                    /* Only the column header row: row headers in a raw
                       HTML table body would pile up at the top. */
                    thead th {
                        position: sticky;
                        top: 0;
                        background: var(--mdp-page-bg, -apple-system-text-background);
                        box-shadow: inset 0 -1px var(--grid);
                    }
                `;
                document.head.append(tableWindowStyle);
                """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            window.contentView = preview
            tableWindow = window
            self.preview = preview
        }
        window.title = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? NSLocalizedString("Table", comment: "Expanded table window title")
        preview.contentDidReplace = { [weak window, weak preview] in
            preview?.contentDidReplace = nil
            window?.makeKeyAndOrderFront(nil)
        }
        preview.applyPageZoom(pageZoom)
        preview.display(markdown: markdown, assetBaseURL: assetBaseURL)
        // The web view consumes key events, so Escape is caught before it.
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Caps Lock is a lock state, not a modifier the reader holds.
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
                guard let self, let tableWindow, event.window === tableWindow,
                      event.keyCode == 53, modifiers.isEmpty
                else { return event }
                tableWindow.close()
                return nil
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // The window delegate is in the responder chain, so View > Zoom reaches
    // the table window here instead of being disabled.
    @IBAction func zoomInDocument(_ sender: Any?) { preview?.zoomIn() }
    @IBAction func zoomOutDocument(_ sender: Any?) { preview?.zoomOut() }
    @IBAction func resetDocumentZoom(_ sender: Any?) { preview?.resetZoom() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(resetDocumentZoom(_:)) {
            return abs((preview?.pageZoom ?? 1.0) - 1.0) > 0.001
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        preview?.contentDidReplace = nil
        preview?.clearContent()
        preview = nil
        tableWindow = nil
    }
}
