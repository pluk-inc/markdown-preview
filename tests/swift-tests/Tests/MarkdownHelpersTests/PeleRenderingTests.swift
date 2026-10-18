import WebKit
import XCTest
@testable import MarkdownHelpers

/// Exercise the production adapter and both unmodified offline bundles in
/// WebKit, including the lazy path used by the app and inline Quick Look pages.
@MainActor
final class PeleRenderingTests: XCTestCase {
    private let source = "flowchart LR\n  A[Original source] --> B[Rendered SVG]"

    func testInlinePeleDoesNotEvaluateMermaid() async throws {
        let view = try await load(source)
        try await assertString("document.querySelector('.mermaid').dataset.mmRenderer", equals: "pele", in: view)
        try await assertString("typeof window.mermaid", equals: "undefined", in: view)
        let hasLabels = try await view.evaluateJavaScript(
            "document.querySelector('.mermaid svg').textContent.includes('Original source')") as? Bool
        XCTAssertEqual(hasLabels, true)
    }

    func testCommonBuiltInTypesUsePele() async throws {
        for diagram in [
            "sequenceDiagram\n Alice->>Bob: Hello\n Bob-->>Alice: Ready",
            "classDiagram\n Animal <|-- Duck\n class Animal {\n +int age\n }",
            "stateDiagram-v2\n [*] --> Ready\n Ready --> [*]",
            "erDiagram\n PERSON ||--o{ NOTE : writes",
            "gantt\n dateFormat YYYY-MM-DD\n section Work\n Task :2026-10-01, 1d",
            "pie title Share\n \"A\" : 60\n \"B\" : 40"
        ] {
            let view = try await load(diagram)
            try await assertString("document.querySelector('.mermaid').dataset.mmRenderer", equals: "pele", in: view)
            try await assertString("typeof window.mermaid", equals: "undefined", in: view)
        }
    }

    func testExplicitMermaidFeaturesKeepCompatibilityRenderer() async throws {
        for diagram in [
            "%%{init: {'theme': 'forest'}}%%\n" + source,
            "---\nconfig:\n  theme: forest\n---\n" + source,
            "flowchart LR\n A[\"<b>HTML label</b>\"] --> B",
            source + "\nclassDef highlighted fill:#ffaaaa\nclass A highlighted",
            source + "\nstyle A fill:#ffaaaa"
        ] {
            let view = try await load(diagram)
            let outcome = try await view.callAsyncJavaScript("""
                try { return (await window.MdPreviewDiagrams.render(source)).renderer; }
                catch (error) { return String(error.stack || error); }
                """, arguments: ["source": diagram], in: nil, contentWorld: .page) as? String
            XCTAssertEqual(outcome, "mermaid", diagram)
            let renderer = try await view.evaluateJavaScript("document.querySelector('.mermaid').dataset.mmRenderer") as? String
            XCTAssertEqual(renderer, "mermaid", diagram)
            let rendered = try await view.evaluateJavaScript("!!document.querySelector('.mermaid svg')") as? Bool
            XCTAssertEqual(rendered, true, diagram)
        }
    }

    func testPeleFailureRetriesOriginalSourceWithMermaid() async throws {
        let view = try await load(source)
        let result = try await view.callAsyncJavaScript("""
            window.pele = { ...pele, render() { throw new Error('Injected Pele failure'); } };
            const node = document.querySelector('.mermaid');
            await window.MdPreview.mermaidRenderAll('dark');
            return [node.dataset.mmRenderer, node.__mdSrc, !!node.querySelector('svg')];
            """, in: nil, contentWorld: .page) as? [Any]
        XCTAssertEqual(result?[0] as? String, "mermaid")
        XCTAssertEqual((result?[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), source)
        XCTAssertEqual(result?[2] as? Bool, true)
    }

    func testUnavailablePeleUsesMermaid() async throws {
        let view = try await load(source)
        let renderer = try await view.callAsyncJavaScript("""
            window.pele = undefined;
            const node = document.querySelector('.mermaid');
            await window.MdPreview.mermaidRenderAll('dark');
            return node.dataset.mmRenderer;
            """, in: nil, contentWorld: .page) as? String
        XCTAssertEqual(renderer, "mermaid")
    }

    func testInvalidDiagramRetainsSourceWithoutAnOrphanErrorSVG() async throws {
        let invalid = "flowchart LR\n  A -->"
        let view = try await load(invalid)
        try await assertString("document.querySelector('.mermaid').textContent.trim()", equals: invalid, in: view)
        let failedCleanly = try await view.evaluateJavaScript("""
            document.querySelector('.mermaid-figure').classList.contains('mermaid-error')
                && !document.querySelector('svg')
            """) as? Bool
        XCTAssertEqual(failedCleanly, true)
    }

    func testThemeChangesAndPaperRenderingKeepPortableSVGColors() async throws {
        let view = try await load(source, colorScheme: .dark)
        let background = "document.querySelector('.mermaid svg').style.getPropertyValue('--pele-bg')"
        try await assertString(background, equals: "#1e1e1e", in: view)
        _ = try await view.callAsyncJavaScript("await window.MdPreview.mermaidRenderAll('default');",
                                              in: nil, contentWorld: .page)
        try await assertString(background, equals: "#ffffff", in: view)
        _ = try await view.callAsyncJavaScript("await window.MdPreview.mermaidRenderAll();",
                                              in: nil, contentWorld: .page)
        try await assertString(background, equals: "#1e1e1e", in: view)
        try await assertString("typeof window.mermaid", equals: "undefined", in: view)
    }

    func testPopupSnapshotRetainsPeleVariablesAndFonts() async throws {
        let bridge = PopupBridge()
        let view = try await load(source, colorScheme: .dark, bridge: bridge)
        _ = try await view.evaluateJavaScript("document.querySelector('[data-mm-act=popup]').click(); true")
        let deadline = Date().addingTimeInterval(5)
        while bridge.svg == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let svg = try XCTUnwrap(bridge.svg)
        XCTAssertTrue(svg.contains("--pele-bg: #1e1e1e"), svg)
        XCTAssertTrue(svg.contains("--_fg:"), svg)
        XCTAssertTrue(svg.contains("font-family:"), svg)
        // Standalone snapshots must resolve their fill without reader CSS.
        let popup = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        popup.loadHTMLString("<html><body>\(MermaidPopupSizing.sanitizedSVGHTML(svg))</body></html>", baseURL: nil)
        try await waitForNavigation(in: popup)
        try await assertString("getComputedStyle(document.querySelector('.pele-node rect')).fill",
                               equals: "rgb(44, 44, 46)", in: popup)
    }

    func testLazyModeLoadsOnlyPeleUntilCompatibilityIsNeeded() async throws {
        let assets = VendorFiles()
        let view = try await load(source, mode: .lazy, assets: assets)
        XCTAssertEqual(assets.requested, ["pele.global.js"])
        try await assertString("document.querySelector('.mermaid').dataset.mmRenderer", equals: "pele", in: view)
        _ = try await view.callAsyncJavaScript("""
            await Promise.all([
                window.MdPreviewDiagrams.render('%%{init: {}}%%\\n' + source),
                window.MdPreviewDiagrams.render('%%{init: {}}%%\\n' + source)
            ]);
            """, arguments: ["source": source], in: nil, contentWorld: .page)
        XCTAssertEqual(assets.requested, ["pele.global.js", "mermaid.min.js"])
    }

    func testLazyModeRecoversFromMissingPeleAsset() async throws {
        let assets = VendorFiles(missingPele: true)
        let view = try await load(source, mode: .lazy, assets: assets)
        try await assertString("document.querySelector('.mermaid').dataset.mmRenderer", equals: "mermaid", in: view)
        XCTAssertEqual(assets.requested, ["pele.global.js", "mermaid.min.js"])
    }

    private func load(_ source: String, mode: MarkdownHTML.VendorLoading = .inline,
                      colorScheme: MarkdownHTML.ColorScheme = .light,
                      assets: VendorFiles? = nil, bridge: PopupBridge? = nil) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        if let assets { config.setURLSchemeHandler(assets, forURLScheme: "md-asset") }
        if let bridge { config.userContentController.add(bridge, name: "mdPreviewHost") }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        let html = MarkdownHTML.render(markdown: "```mermaid\n\(source)\n```", vendorLoading: mode,
                                       colorScheme: colorScheme).html
        view.loadHTMLString(html, baseURL: nil)
        try await waitForNavigation(in: view)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if try await view.evaluateJavaScript("typeof window.MdPreview?.mermaidRenderAll === 'function'") as? Bool == true {
                _ = try await view.callAsyncJavaScript("await window.MdPreview.mermaidRenderAll();",
                                                      in: nil, contentWorld: .page)
                return view
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebViewLayoutHarness.Failure("Diagram adapter did not become ready")
    }

    private func waitForNavigation(in view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(10)
        while view.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !view.isLoading else { throw WebViewLayoutHarness.Failure("Diagram page did not load") }
    }

    private func string(_ script: String, in view: WKWebView) async throws -> String {
        let value = try await view.evaluateJavaScript(script)
        return try XCTUnwrap(value as? String)
    }

    private func assertString(_ script: String, equals expected: String, in view: WKWebView,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let value = try await string(script, in: view)
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private final class PopupBridge: NSObject, WKScriptMessageHandler {
        var svg: String?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any], payload["kind"] as? String == "mermaidPopup" else { return }
            svg = payload["svg"] as? String
        }
    }

    private final class VendorFiles: NSObject, WKURLSchemeHandler {
        var requested: [String] = []
        private let missingPele: Bool
        init(missingPele: Bool = false) { self.missingPele = missingPele }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let name = url.lastPathComponent
            requested.append(name)
            guard !(missingPele && name == "pele.global.js"),
                  let directory = ["pele.global.js": "Pele", "mermaid.min.js": "Mermaid"][name],
                  let data = try? Data(contentsOf: TestVendor.repositoryRoot
                    .appendingPathComponent("md-preview/Vendor/\(directory)/\(name)")) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: "application/javascript", expectedContentLength: data.count,
                                        textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }
}
