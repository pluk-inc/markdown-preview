//
//  PDFExporter.swift
//  md-preview
//

import Cocoa
import os
import WebKit

/// Renders a Markdown document into a dedicated offscreen WKWebView and writes
/// a paginated PDF to `destinationURL`. The render is independent of the live
/// preview (its own web view, forced light appearance, full vendor inline). It
/// waits for a `renderComplete` host message (with a hard timeout) so async
/// renderers finish before printing, then runs a silent NSPrintOperation.
///
/// The instance retains itself via `selfRetain` for the duration of the export
/// so callers can fire-and-forget after constructing it. Script messages are
/// routed through a weak `MessageProxy` so `WKUserContentController` does not
/// form a strong-ref cycle with the exporter.
@MainActor final class PDFExporter: NSObject, WKNavigationDelegate {

    enum ExportError: LocalizedError {
        case renderFailed
        case printFailed

        var errorDescription: String? {
            switch self {
            case .renderFailed: return "The document could not be prepared for export."
            case .printFailed:  return "The PDF could not be written."
            }
        }
    }

    private static let hostMessageName = "mdPreviewHost"
    /// Offscreen export can stall on rAF-throttled renderers (hljs, Mermaid);
    /// 30 s covers worst-case Mermaid-heavy docs without returning too early.
    private static let readinessTimeout: TimeInterval = 30.0
    private static let contentHeightScript = """
    Math.max(
        document.documentElement.scrollHeight,
        document.body ? document.body.scrollHeight : 0
    )
    """
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "doc.md-preview",
                                    category: "export")

    private let webView: WKWebView
    /// Off-screen host window. A `WKWebView` that is never placed in a window is
    /// never composited by WebKit, so the print operation captures blank pages.
    /// Hosting it in a borderless window parked far off-screen forces a real
    /// render while staying invisible to the user.
    private var hostWindow: NSWindow?
    private let assetScheme = MarkdownAssetScheme()
    private let messageProxy = MessageProxy()
    private let destinationURL: URL
    private let paperSize: PaperSize
    private var completion: (@MainActor (Result<URL, Error>) -> Void)?
    private var didFinish = false
    private var timeoutWork: DispatchWorkItem?
    private var selfRetain: PDFExporter?

    init(markdown: String,
         assetBaseURL: URL?,
         destinationURL: URL,
         completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.destinationURL = destinationURL
        self.completion = completion
        self.paperSize = PaperSize.forRegion(Locale.current.region?.identifier)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(assetScheme, forURLScheme: MarkdownAssetScheme.scheme)
        // A4/Letter portrait point width gives layout a sensible measure; the
        // print operation re-paginates to the paper size regardless.
        let frame = NSRect(x: 0, y: 0,
                           width: paperSize.pointSize.width,
                           height: paperSize.pointSize.height)
        webView = WKWebView(frame: frame, configuration: config)

        super.init()

        assetScheme.setBaseURL(assetBaseURL)
        messageProxy.owner = self
        webView.configuration.userContentController.add(messageProxy, name: Self.hostMessageName)
        webView.navigationDelegate = self
        // Required (not just CSS): Mermaid reads `prefers-color-scheme` via
        // `matchMedia`, which follows NSAppearance — `.aqua` forces light diagrams.
        webView.appearance = NSAppearance(named: .aqua)

        // Host the web view in an off-screen window so WebKit actually renders
        // the page (an unhosted web view never paints → blank PDF pages). The
        // window is borderless, excluded from the menu/cycle, and parked far
        // outside any display so it never appears on screen.
        let window = NSWindow(contentRect: frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        window.alphaValue = 0.0   // rendered (so WebKit paints) but not visible
        window.contentView = webView
        // Park at the very bottom-left of the main screen; alpha 0 keeps it
        // invisible while staying on the screen list so runModal can attach and
        // WebKit composites the page.
        window.setFrameOrigin((NSScreen.main?.frame.origin ?? .zero))
        window.orderFrontRegardless()
        hostWindow = window

        let rendered = MarkdownHTML.render(
            markdown: markdown,
            assetBaseHref: "\(MarkdownAssetScheme.scheme):///",
            vendorLoading: .inline,
            forExport: true
        )

        selfRetain = self
        ExportContentRules.install(on: config.userContentController) { [weak self] in
            guard let self else { return }
            self.webView.loadHTMLString(rendered.html, baseURL: nil)
            self.scheduleTimeout()
        }
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Best-effort contract: a stuck renderer still exports whatever
            // rendered; the completion type stays `.success` (no partial flag).
            Self.log.warning("Export readiness timed out after \(Self.readinessTimeout)s; exporting best-effort partial render")
            self.printToFile()
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessTimeout, execute: work)
    }

    fileprivate func didReceiveHostMessage(_ message: WKScriptMessage) {
        guard message.name == Self.hostMessageName,
              let body = message.body as? [String: Any],
              body["kind"] as? String == "renderComplete" else { return }
        printToFile()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("Export navigation failed: \(error.localizedDescription, privacy: .public)")
        finish(.failure(ExportError.renderFailed))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        Self.log.error("Export provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        finish(.failure(ExportError.renderFailed))
    }

    // MARK: - Printing

    private func printToFile() {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()

        // Callback-based (not async/await): runPrintToFile() runs an AppKit modal
        // print loop, which must not be driven from inside a Swift async
        // continuation. The JS-evaluation completion is delivered on the main
        // thread, so resize + print happen on the main run loop normally.
        webView.evaluateJavaScript(Self.contentHeightScript) { [weak self] result, _ in
            guard let self else { return }
            self.resizeWebViewToContentHeight(measuredHeight: result)
            self.runPrintToFile()
        }
    }

    /// Grow the host web view to the full rendered document height (same idea as
    /// the live preview path) so AppKit paginates the whole document instead of
    /// tiling a one-page-tall view.
    private func resizeWebViewToContentHeight(measuredHeight: Any?) {
        let width = paperSize.pointSize.width
        var contentHeight = paperSize.pointSize.height
        if let number = measuredHeight as? NSNumber {
            contentHeight = CGFloat(truncating: number)
        }
        contentHeight = max(ceil(contentHeight), 1)
        // The web view is the host window's content view; resizing the window
        // lays out the whole document before printing.
        hostWindow?.setContentSize(NSSize(width: width, height: contentHeight))
        webView.layoutSubtreeIfNeeded()
        Self.log.debug("Export web view sized to \(width, privacy: .public)×\(contentHeight, privacy: .public) pt")
    }

    private func runPrintToFile() {
        // Clean-slate print settings — not `NSPrintInfo.shared.copy()` — so
        // export ignores the user's printer defaults and margin presets.
        let printInfo = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: destinationURL,
        ])
        printInfo.paperSize = NSSize(width: paperSize.pointSize.width,
                                     height: paperSize.pointSize.height)
        // Margins come from the export stylesheet's @page rule; keep the print
        // operation's own margins at zero so they don't stack.
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds

        // Use runModal(for:…), NOT run(): WKWebView renders print content
        // asynchronously, and run() returns before that finishes, producing
        // blank pages with the correct page count. runModal lets WebKit's async
        // render complete and reports the result via the didRun callback. This
        // matches the working live print path (MarkdownWebView.printDocument).
        guard let window = hostWindow else {
            let ok = operation.run()
            finish(ok ? .success(destinationURL) : .failure(ExportError.printFailed))
            return
        }
        operation.runModal(for: window,
                           delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                           contextInfo: nil)
    }

    // NSPrintOperation runs WKWebView's modal print on a background NSThread and
    // calls this didRun callback from that thread — so it must be `nonisolated`
    // (a @MainActor callback trips the executor assertion and crashes). Hop back
    // to the main actor to finish.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation,
                                                        success: Bool,
                                                        contextInfo: UnsafeMutableRawPointer?) {
        let url = destinationURL
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Self.log.debug("Export print finished, success=\(success, privacy: .public) → \(url.path, privacy: .public)")
            self.finish(success ? .success(url) : .failure(ExportError.printFailed))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        timeoutWork?.cancel()
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.hostMessageName)
        // Tear down the off-screen host window.
        hostWindow?.orderOut(nil)
        hostWindow?.contentView = nil
        hostWindow = nil
        completion?(result)
        completion = nil
        selfRetain = nil
    }
}

// Receives postMessage() from the export page's host-bridge script. Held weakly
// by the WKUserContentController via this proxy so PDFExporter's lifetime is
// governed solely by `selfRetain`, not a config retain cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: PDFExporter?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.didReceiveHostMessage(message)
    }
}
