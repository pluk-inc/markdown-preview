//
//  PDFExporter.swift
//  md-preview
//

import Cocoa
import WebKit

/// Renders a Markdown document into a dedicated offscreen WKWebView and writes
/// a paginated PDF to `destinationURL`. The render is independent of the live
/// preview (its own web view, forced light appearance, full vendor inline). It
/// waits for a `renderComplete` host message (with a hard timeout) so async
/// renderers finish before printing, then runs a silent NSPrintOperation.
///
/// The instance retains itself for the duration of the export, so callers can
/// fire-and-forget after constructing it.
@MainActor final class PDFExporter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

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
    private static let readinessTimeout: TimeInterval = 8.0

    private let webView: WKWebView
    private let assetScheme = MarkdownAssetScheme()
    private let destinationURL: URL
    private let paperSize: PaperSize
    private var completion: ((Result<URL, Error>) -> Void)?
    private var didFinish = false
    private var timeoutWork: DispatchWorkItem?
    private var selfRetain: PDFExporter?

    init(markdown: String,
         assetBaseURL: URL?,
         destinationURL: URL,
         completion: @escaping (Result<URL, Error>) -> Void) {
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
        webView.configuration.userContentController.add(self, name: Self.hostMessageName)
        webView.navigationDelegate = self
        // Force light so prefers-color-scheme (CSS + Mermaid matchMedia) resolves
        // light, giving print-friendly output regardless of system appearance.
        webView.appearance = NSAppearance(named: .aqua)

        let rendered = MarkdownHTML.render(
            markdown: markdown,
            assetBaseHref: "\(MarkdownAssetScheme.scheme):///",
            vendorLoading: .inline,
            forExport: true
        )

        selfRetain = self
        webView.loadHTMLString(rendered.html, baseURL: nil)
        scheduleTimeout()
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in
            // Best-effort: a stuck renderer still exports what rendered.
            MainActor.assumeIsolated { self?.printToFile() }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessTimeout, execute: work)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.hostMessageName,
              let body = message.body as? [String: Any],
              body["kind"] as? String == "renderComplete" else { return }
        printToFile()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ExportError.renderFailed))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(.failure(ExportError.renderFailed))
    }

    // MARK: - Printing

    private func printToFile() {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()

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

        let ok = operation.run()
        finish(ok ? .success(destinationURL) : .failure(ExportError.printFailed))
    }

    private func finish(_ result: Result<URL, Error>) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.hostMessageName)
        completion?(result)
        completion = nil
        selfRetain = nil
    }
}
