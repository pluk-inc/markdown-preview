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

        Task { @MainActor in
            await self.resizeWebViewToContentHeight()
            self.runPrintToFile()
        }
    }

    /// Grow the offscreen web view to the full rendered document height (same
    /// idea as the live preview path) so AppKit paginates once instead of
    /// tiling a one-page-tall view across thousands of PDF pages.
    private func resizeWebViewToContentHeight() async {
        let width = paperSize.pointSize.width
        var contentHeight = paperSize.pointSize.height

        do {
            let result = try await webView.evaluateJavaScript(Self.contentHeightScript)
            if let number = result as? NSNumber {
                contentHeight = CGFloat(truncating: number)
            } else if let value = result as? Double {
                contentHeight = CGFloat(value)
            }
        } catch {
            Self.log.warning(
                "Could not measure export content height: \(error.localizedDescription, privacy: .public); using paper height"
            )
        }

        contentHeight = max(ceil(contentHeight), 1)
        webView.setFrameSize(NSSize(width: width, height: contentHeight))
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
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds

        let ok = operation.run()
        if ok {
            Self.log.debug("Export print succeeded → \(self.destinationURL.path, privacy: .public)")
        } else {
            Self.log.debug("Export print failed")
        }
        finish(ok ? .success(destinationURL) : .failure(ExportError.printFailed))
    }

    private func finish(_ result: Result<URL, Error>) {
        timeoutWork?.cancel()
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.hostMessageName)
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
