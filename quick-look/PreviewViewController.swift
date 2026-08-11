//
//  PreviewViewController.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Quartz
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController, WKNavigationDelegate {
    private var webView: WKWebView!

    override func loadView() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        view = webView
        preferredContentSize = NSSize(
            width: MarkdownHTML.preferredPageWidth,
            height: MarkdownHTML.preferredPageWidth
        )
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let appearanceMode = AppearanceMode.current
        let colorScheme: MarkdownHTML.ColorScheme
        switch appearanceMode {
        case .automatic:
            let appearance = NSApplication.shared.effectiveAppearance
            let systemIsDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            colorScheme = appearanceMode.resolvedColorScheme(systemIsDark: systemIsDark)
        case .light:
            colorScheme = .light
        case .dark:
            colorScheme = .dark
        }

        let renderedHTML = MarkdownHTML.makeHTML(
            from: text,
            allowsScroll: true,
            colorScheme: colorScheme
        )
        let baseDirectory = url.deletingLastPathComponent()
        let rewrite = InlineLocalAssets.rewriteRelativeImages(
            html: renderedHTML,
            baseDirectory: baseDirectory,
            reader: { try Data(contentsOf: $0) }
        )

        loadViewIfNeeded()
        webView.loadHTMLString(
            InlineLocalAssets.dataURLHTML(from: rewrite),
            // Admitted local images are already data URLs. A directory base
            // would let WebKit fetch rejected or over-budget relative images.
            baseURL: nil
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let isPageFragment = url.scheme == "about"
            && url.path == "blank"
            && url.fragment != nil
        if isPageFragment {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
