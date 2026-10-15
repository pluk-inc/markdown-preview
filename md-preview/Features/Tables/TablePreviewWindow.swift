import AppKit
import WebKit

/// A read-only snapshot of one table, using the regular sanitized renderer and
/// link/asset policies. The source document and its editing state stay intact.
/// It opens as an ordinary window: the reader decides whether to make it
/// fullscreen, minimize it, or resize it, and Escape closes it.
@MainActor
final class TablePreviewWindow: NSObject, NSWindowDelegate {
    static let shared = TablePreviewWindow()
    private var tableWindow: NSWindow?
    private var preview: MarkdownWebView?
    private var escapeMonitor: Any?

    func present(markdown: String, title: String?, assetBaseURL: URL?, relativeTo parent: NSWindow?) {
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
