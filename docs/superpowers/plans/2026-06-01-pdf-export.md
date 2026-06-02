# PDF Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Export as PDF…" feature that renders the current Markdown document into a fresh offscreen WebKit view and writes a clean, paginated PDF to a user-chosen location.

**Architecture:** A dedicated `PDFExporter` builds a self-contained HTML document via `MarkdownHTML.render(forExport:)`, loads it into its own offscreen `WKWebView` (forced to light appearance), waits until all asynchronous renderers (KaTeX, Mermaid, highlight.js) report completion over the existing host-bridge message channel, then runs a silent `NSPrintOperation` to file. Pure, testable units (paper-size selection and export HTML assets) live in Foundation-only files compiled by the existing `swift test` package; WebKit/AppKit integration is verified by build + a manual test plan.

**Tech Stack:** Swift 6, AppKit, WebKit (`WKWebView.printOperation`), `NSPrintInfo` save-to-file, XCTest via SwiftPM (`tests/swift-tests`).

---

## Background the engineer needs

- The Xcode project uses **file-system-synchronized groups** (Xcode 16). Any `.swift` file placed in `md-preview/` is automatically compiled into **both** the `md-preview` app target and the embedded `quick-look` extension. Files that use app-only APIs must be excluded from the extension via the quick-look target's `membershipExceptions` in `project.pbxproj` (as was required for `MarkdownExportAssets.swift`).
- Pure Foundation helpers are unit-tested by a separate SwiftPM package at `tests/swift-tests/`. Source files live in `md-preview/` and are **symlinked** into `tests/swift-tests/Sources/<Target>/`. Run tests with: `swift test --package-path tests/swift-tests`.
- `MarkdownHTML.render(...)` (`md-preview/MarkdownHTML.swift`) emits a full HTML document. It already computes `containsMath`, `containsMermaid`, `containsCode` on its `RenderedHTML` result. It has a `VendorLoading` mode: `.inline` embeds all renderer JS (self-contained, what we use for export); `.lazy` is for the live app.
- Renderers signal completion in the DOM: KaTeX sets `data-math-done="1"` on each `.math`; highlight.js sets `data-hljs-done="1"` on each `pre code[class*="language-"]`; Mermaid sets `data-mm-done="1"` on each `.mermaid` (or adds `.mermaid-error` to the figure).
- **Mermaid gotcha:** Mermaid figures render lazily via an `IntersectionObserver` (`md-preview/MarkdownHTML.swift`, `mermaidInitWiring` `bootstrap()`). Offscreen, figures below the fold would never render. We add an eager path gated on `window.__mdPreviewRenderAll` for export.
- The page posts host messages via `window.webkit.messageHandlers.mdPreviewHost.postMessage(...)` (see `hostBridgeScript`). The exporter registers a handler under the same name (`mdPreviewHost`) to receive a `{kind:"renderComplete"}` signal.
- The app is sandboxed; current entitlements are read-only for user files. Writing a PDF needs `com.apple.security.files.user-selected.read-write`.

## File Structure

- **Create** `md-preview/PDFPageSize.swift` — pure Foundation. `PaperSize` enum + locale→paper selection + point dimensions.
- **Create** `md-preview/MarkdownExportAssets.swift` — pure Foundation. Export CSS string, render-readiness `<script>` generator, and the head-injection composer.
- **Create** `md-preview/PDFExporter.swift` — AppKit/WebKit. Offscreen render + silent print-to-file.
- **Modify** `md-preview/MarkdownHTML.swift` — add `forExport` param to `render(...)`; inject export assets; add Mermaid eager path.
- **Modify** `md-preview/md-preview.entitlements` — add user-selected read-write.
- **Modify** `md-preview/DocumentWindowController.swift` — `exportMarkdownAsPDF:` action, save panel, toolbar item, menu validation.
- **Modify** `md-preview/Base.lproj/MainMenu.xib` — File ▸ "Export as PDF…" (⌥⌘P).
- **Create (symlinks + tests)** under `tests/swift-tests/`.

---

### Task 1: `PaperSize` pure helper (locale → paper)

**Files:**
- Create: `md-preview/PDFPageSize.swift`
- Symlink: `tests/swift-tests/Sources/MarkdownHelpers/PDFPageSize.swift`
- Test: `tests/swift-tests/Tests/MarkdownHelpersTests/PDFPageSizeTests.swift`

- [ ] **Step 1: Create the implementation file**

Create `md-preview/PDFPageSize.swift`:

```swift
//
//  PDFPageSize.swift
//  md-preview
//

import Foundation

/// Paper size for PDF export. Selected from the user's region so North
/// American locales default to US Letter and the rest of the world to A4.
/// Pure value type (Foundation only) so it is unit-testable in the SwiftPM
/// helper package; `PDFExporter` maps it onto `NSPrintInfo`.
nonisolated enum PaperSize: Equatable {
    case usLetter
    case a4

    /// Dimensions in PostScript points (72 dpi), portrait orientation.
    var pointSize: (width: Double, height: Double) {
        switch self {
        case .usLetter: return (612, 792)        // 8.5" × 11"
        case .a4:       return (595.28, 841.89)  // 210mm × 297mm
        }
    }

    /// Regions that conventionally use US Letter. Everything else gets A4.
    private static let letterRegions: Set<String> = [
        "US", "CA", "MX", "CL", "CO", "CR", "GT", "DO",
        "PH", "SV", "NI", "PA", "VE", "PR"
    ]

    /// Maps an ISO region code (e.g. "US", "GB") to a paper size. A nil or
    /// unrecognized region falls back to A4 (the international default).
    static func forRegion(_ regionCode: String?) -> PaperSize {
        guard let regionCode else { return .a4 }
        return letterRegions.contains(regionCode.uppercased()) ? .usLetter : .a4
    }
}
```

- [ ] **Step 2: Create the symlink so the test package compiles it**

Run (from repo root):

```bash
ln -s ../../../../md-preview/PDFPageSize.swift tests/swift-tests/Sources/MarkdownHelpers/PDFPageSize.swift
```

Expected: symlink created. Verify: `ls -l tests/swift-tests/Sources/MarkdownHelpers/PDFPageSize.swift` shows it points to `../../../../md-preview/PDFPageSize.swift`.

- [ ] **Step 3: Write the failing test**

Create `tests/swift-tests/Tests/MarkdownHelpersTests/PDFPageSizeTests.swift`:

```swift
import XCTest

@testable import MarkdownHelpers

final class PDFPageSizeTests: XCTestCase {

    func testUSRegionsSelectLetter() {
        XCTAssertEqual(PaperSize.forRegion("US"), .usLetter)
        XCTAssertEqual(PaperSize.forRegion("CA"), .usLetter)
        XCTAssertEqual(PaperSize.forRegion("MX"), .usLetter)
    }

    func testRegionCodeIsCaseInsensitive() {
        XCTAssertEqual(PaperSize.forRegion("us"), .usLetter)
    }

    func testInternationalRegionsSelectA4() {
        XCTAssertEqual(PaperSize.forRegion("GB"), .a4)
        XCTAssertEqual(PaperSize.forRegion("DE"), .a4)
        XCTAssertEqual(PaperSize.forRegion("JP"), .a4)
    }

    func testNilRegionFallsBackToA4() {
        XCTAssertEqual(PaperSize.forRegion(nil), .a4)
    }

    func testUnknownRegionFallsBackToA4() {
        XCTAssertEqual(PaperSize.forRegion("ZZ"), .a4)
    }

    func testPointSizesArePortrait() {
        XCTAssertEqual(PaperSize.usLetter.pointSize.width, 612, accuracy: 0.01)
        XCTAssertEqual(PaperSize.usLetter.pointSize.height, 792, accuracy: 0.01)
        XCTAssertEqual(PaperSize.a4.pointSize.width, 595.28, accuracy: 0.01)
        XCTAssertEqual(PaperSize.a4.pointSize.height, 841.89, accuracy: 0.01)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --package-path tests/swift-tests --filter PDFPageSizeTests`
Expected: all `PDFPageSizeTests` pass. (Implementation was written in Step 1, so this is green on first run; if it fails to compile, fix `PDFPageSize.swift`.)

- [ ] **Step 5: Commit**

```bash
git add md-preview/PDFPageSize.swift \
        tests/swift-tests/Sources/MarkdownHelpers/PDFPageSize.swift \
        tests/swift-tests/Tests/MarkdownHelpersTests/PDFPageSizeTests.swift
git commit -m "feat(pdf): add locale-aware PaperSize helper"
```

---

### Task 2: `MarkdownExportAssets` pure helper (export CSS + readiness script)

**Files:**
- Create: `md-preview/MarkdownExportAssets.swift`
- Symlink: `tests/swift-tests/Sources/MarkdownHelpers/MarkdownExportAssets.swift`
- Test: `tests/swift-tests/Tests/MarkdownHelpersTests/MarkdownExportAssetsTests.swift`

- [ ] **Step 1: Create the implementation file**

Create `md-preview/MarkdownExportAssets.swift`:

```swift
//
//  MarkdownExportAssets.swift
//  md-preview
//

import Foundation

/// HTML/CSS/JS fragments injected into the document only when rendering for
/// PDF export. Pure string builders (Foundation only) so they are unit-tested
/// in the SwiftPM helper package without WebKit. `MarkdownHTML.render` calls
/// `headInjection(...)` when `forExport` is true.
nonisolated enum MarkdownExportAssets {

    /// Print-oriented CSS overrides. Light color scheme is enforced by the
    /// export web view's NSAppearance (so KaTeX/Mermaid/CSS media queries all
    /// resolve light); this stylesheet only removes interactive chrome, keeps
    /// background colors when printing, sets page margins, and avoids ugly
    /// breaks inside code/tables/diagrams.
    static let stylesheet = """
    @page { margin: 18mm; }
    :root { color-scheme: light; }
    body {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
    .md-code-copy { display: none !important; }
    .mermaid-hud { display: none !important; }
    mark.md-search-highlight {
        background: transparent !important;
        color: inherit !important;
        box-shadow: none !important;
    }
    pre, .md-code-wrap, table, .mermaid-figure {
        break-inside: avoid;
    }
    """

    /// `<script>` that waits until the document has fully loaded and every
    /// expected renderer has marked its elements done, then posts
    /// `{kind:"renderComplete"}` to the host. Polls (rather than relying on
    /// one-shot events) so it is robust to renderers that finish before this
    /// script attaches. The Swift side also applies a hard timeout.
    static func readinessScript(containsMath: Bool,
                                containsMermaid: Bool,
                                containsCode: Bool) -> String {
        """
        <script>
        (() => {
            const expectMath = \(containsMath ? "true" : "false");
            const expectMermaid = \(containsMermaid ? "true" : "false");
            const expectCode = \(containsCode ? "true" : "false");

            function ready() {
                if (document.readyState !== 'complete') return false;
                if (expectMath &&
                    document.querySelector('.math:not([data-math-done="1"])')) {
                    return false;
                }
                if (expectCode &&
                    document.querySelector('pre code[class*="language-"]:not([data-hljs-done="1"])')) {
                    return false;
                }
                if (expectMermaid) {
                    const nodes = document.querySelectorAll('.mermaid');
                    for (const node of nodes) {
                        const figure = node.closest('.mermaid-figure');
                        const errored = figure && figure.classList.contains('mermaid-error');
                        if (node.dataset.mmDone !== '1' && !errored) return false;
                    }
                }
                return true;
            }

            function post() {
                try {
                    const h = window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.mdPreviewHost;
                    if (h) h.postMessage({ kind: 'renderComplete' });
                } catch (e) {}
            }

            let done = false;
            function check() {
                if (done) return;
                if (ready()) { done = true; post(); return; }
                setTimeout(check, 50);
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', check, { once: true });
            } else {
                check();
            }
        })();
        </script>
        """
    }

    /// Everything injected into `<head>` for an export render: the eager-render
    /// flag (so Mermaid renders all figures instead of waiting for the
    /// IntersectionObserver), the print stylesheet, and the readiness script.
    /// The flag script must precede the renderer scripts in the head, which is
    /// where `MarkdownHTML.render` places this injection.
    static func headInjection(containsMath: Bool,
                              containsMermaid: Bool,
                              containsCode: Bool) -> String {
        """
        <script>window.__mdPreviewRenderAll = true;</script>
        <style>\(stylesheet)</style>
        \(readinessScript(containsMath: containsMath,
                          containsMermaid: containsMermaid,
                          containsCode: containsCode))
        """
    }
}
```

- [ ] **Step 2: Create the symlink**

Run (from repo root):

```bash
ln -s ../../../../md-preview/MarkdownExportAssets.swift tests/swift-tests/Sources/MarkdownHelpers/MarkdownExportAssets.swift
```

Expected: symlink created pointing to `../../../../md-preview/MarkdownExportAssets.swift`.

- [ ] **Step 3: Write the failing test**

Create `tests/swift-tests/Tests/MarkdownHelpersTests/MarkdownExportAssetsTests.swift`:

```swift
import XCTest

@testable import MarkdownHelpers

final class MarkdownExportAssetsTests: XCTestCase {

    func testStylesheetHidesInteractiveChrome() {
        let css = MarkdownExportAssets.stylesheet
        XCTAssertTrue(css.contains(".md-code-copy"))
        XCTAssertTrue(css.contains(".mermaid-hud"))
        XCTAssertTrue(css.contains("md-search-highlight"))
    }

    func testStylesheetSetsPageAndColorAdjust() {
        let css = MarkdownExportAssets.stylesheet
        XCTAssertTrue(css.contains("@page"))
        XCTAssertTrue(css.contains("print-color-adjust: exact"))
        XCTAssertTrue(css.contains("break-inside: avoid"))
    }

    func testReadinessScriptReflectsExpectedRenderers() {
        let all = MarkdownExportAssets.readinessScript(
            containsMath: true, containsMermaid: true, containsCode: true)
        XCTAssertTrue(all.contains("expectMath = true"))
        XCTAssertTrue(all.contains("expectMermaid = true"))
        XCTAssertTrue(all.contains("expectCode = true"))
        XCTAssertTrue(all.contains("renderComplete"))

        let none = MarkdownExportAssets.readinessScript(
            containsMath: false, containsMermaid: false, containsCode: false)
        XCTAssertTrue(none.contains("expectMath = false"))
        XCTAssertTrue(none.contains("expectMermaid = false"))
        XCTAssertTrue(none.contains("expectCode = false"))
        XCTAssertTrue(none.contains("renderComplete"))
    }

    func testReadinessScriptChecksRendererDoneMarkers() {
        let all = MarkdownExportAssets.readinessScript(
            containsMath: true, containsMermaid: true, containsCode: true)
        XCTAssertTrue(all.contains("data-math-done"))
        XCTAssertTrue(all.contains("data-hljs-done"))
        XCTAssertTrue(all.contains("mmDone"))
    }

    func testHeadInjectionSetsEagerRenderFlagAndStyle() {
        let head = MarkdownExportAssets.headInjection(
            containsMath: false, containsMermaid: true, containsCode: false)
        XCTAssertTrue(head.contains("__mdPreviewRenderAll = true"))
        XCTAssertTrue(head.contains("<style>"))
        XCTAssertTrue(head.contains(".md-code-copy"))
        XCTAssertTrue(head.contains("renderComplete"))
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --package-path tests/swift-tests --filter MarkdownExportAssetsTests`
Expected: all `MarkdownExportAssetsTests` pass.

- [ ] **Step 5: Commit**

```bash
git add md-preview/MarkdownExportAssets.swift \
        tests/swift-tests/Sources/MarkdownHelpers/MarkdownExportAssets.swift \
        tests/swift-tests/Tests/MarkdownHelpersTests/MarkdownExportAssetsTests.swift
git commit -m "feat(pdf): add export CSS and render-readiness assets"
```

---

### Task 3: Thread `forExport` through `MarkdownHTML` + Mermaid eager path

**Files:**
- Modify: `md-preview/MarkdownHTML.swift`

This task is not SwiftPM-testable (the full `MarkdownHTML` is not in the helper package); it is verified by an app build in Task 7. Make the edits precisely.

- [ ] **Step 1: Add the `forExport` parameter to `render(...)`**

In `md-preview/MarkdownHTML.swift`, the `render` signature currently ends with `warmup: Bool = false`. Add a parameter:

```swift
    static func render(markdown: String,
                       allowsScroll: Bool = false,
                       assetBaseHref: String? = nil,
                       vendorLoading: VendorLoading = .inline,
                       warmup: Bool = false,
                       forExport: Bool = false) -> RenderedHTML {
```

- [ ] **Step 2: Build the export injection and place it in the head**

Still in `render(...)`, just before the `let html = """` template (after `let safeBody = ...`), add:

```swift
        let exportInjection = forExport
            ? MarkdownExportAssets.headInjection(containsMath: containsMath,
                                                 containsMermaid: containsMermaid,
                                                 containsCode: containsCode)
            : ""
```

Then, inside the `let html = """ ... """` head, insert `\(exportInjection)` immediately after `\(hostBridgeScript)` and before `\(mathBlock)`. The head block becomes:

```
        \(hostBridgeScript)
        \(exportInjection)
        \(mathBlock)
        \(mermaidBlock)
        \(highlightBlock)
        </head>
```

(Placing it before the renderer scripts guarantees `window.__mdPreviewRenderAll` is set before Mermaid's bootstrap runs.)

- [ ] **Step 3: Add the Mermaid eager-render path**

In `md-preview/MarkdownHTML.swift`, find the `bootstrap()` function inside `mermaidInitWiring` (it currently creates an `IntersectionObserver`). Replace the body so an export render enqueues every figure immediately:

```javascript
            function bootstrap() {
                const figures = document.querySelectorAll('.mermaid-figure');
                if (!figures.length) return;
                if (window.__mdPreviewRenderAll) {
                    figures.forEach((f) => { queue.push(f); ro.observe(f); });
                    drain();
                    return;
                }
                const io = new IntersectionObserver((entries) => {
                    for (const entry of entries) {
                        if (entry.isIntersecting) {
                            io.unobserve(entry.target);
                            queue.push(entry.target);
                            ro.observe(entry.target);
                            drain();
                        }
                    }
                }, { rootMargin: '300px 0px' });
                figures.forEach((f) => io.observe(f));
            }
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. (If `MarkdownExportAssets` is reported as unknown, confirm Task 2 created `md-preview/MarkdownExportAssets.swift`.)

- [ ] **Step 5: Commit**

```bash
git add md-preview/MarkdownHTML.swift
git commit -m "feat(pdf): render export HTML with eager Mermaid + readiness signal"
```

---

### Task 4: `PDFExporter` — offscreen render to PDF file

**Files:**
- Create: `md-preview/PDFExporter.swift`

- [ ] **Step 1: Create the exporter**

Create `md-preview/PDFExporter.swift`:

```swift
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
nonisolated final class PDFExporter: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

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

    @MainActor
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
            self?.printToFile()
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
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add md-preview/PDFExporter.swift
git commit -m "feat(pdf): add offscreen PDFExporter (print-to-file)"
```

---

### Task 5: Sandbox entitlement for saving

**Files:**
- Modify: `md-preview/md-preview.entitlements`

- [ ] **Step 1: Add the read-write entitlement**

In `md-preview/md-preview.entitlements`, immediately after the existing `com.apple.security.files.user-selected.read-only` key/value pair, add:

```xml
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
```

(Leave the existing keys intact. `read-write` lets `NSSavePanel` + Powerbox grant a write extension to the chosen destination.)

- [ ] **Step 2: Verify it builds and stays signed**

Run: `xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add md-preview/md-preview.entitlements
git commit -m "feat(pdf): grant user-selected read-write for PDF export"
```

---

### Task 6: Menu, toolbar, action, and validation wiring

**Files:**
- Modify: `md-preview/DocumentWindowController.swift`
- Modify: `md-preview/Base.lproj/MainMenu.xib`

- [ ] **Step 1: Add the toolbar item identifier**

In `md-preview/DocumentWindowController.swift`, in the `extension NSToolbarItem.Identifier` block (near `static let printDocument = ...`), add:

```swift
    static let exportPDF = NSToolbarItem.Identifier("ExportPDF")
```

- [ ] **Step 2: Make the toolbar item available (allowed, not default)**

In `toolbarAllowedItemIdentifiers(_:)`, add `.exportPDF` to the array (e.g. right after `.printDocument`):

```swift
            .printDocument,
            .exportPDF,
            .copyMarkdown,
```

In `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`, add a case alongside `.printDocument`:

```swift
        case .exportPDF: return makeExportPDFItem()
```

- [ ] **Step 3: Build the toolbar item and the export action**

In `md-preview/DocumentWindowController.swift`, add (next to `makePrintItem()`):

```swift
    private func makeExportPDFItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .exportPDF)
        item.label = "Export PDF"
        item.paletteLabel = "Export as PDF"
        item.toolTip = "Export document as PDF"
        item.image = NSImage(systemSymbolName: "arrow.down.document",
                             accessibilityDescription: "Export as PDF")
        item.isBordered = true
        item.target = self
        item.action = #selector(exportMarkdownAsPDF(_:))
        return item
    }

    @objc func exportMarkdownAsPDF(_ sender: Any?) {
        guard let markdown = currentMarkdown, !markdown.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let baseName = currentFileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = "\(baseName).pdf"
        panel.beginSheetModal(for: documentWindow) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            let assetBaseURL = self.currentFileURL?.deletingLastPathComponent()
            _ = PDFExporter(markdown: markdown,
                            assetBaseURL: assetBaseURL,
                            destinationURL: destination) { [weak self] result in
                guard let self, case .failure(let error) = result else { return }
                NSAlert(error: error).beginSheetModal(for: self.documentWindow)
            }
        }
    }
```

(`PDFExporter` retains itself until completion, so the discard `_ =` is intentional. `UTType` is already imported via `import UniformTypeIdentifiers` at the top of the file, so `.pdf` resolves.)

- [ ] **Step 4: Disable the menu item when no document is open**

In `md-preview/DocumentWindowController.swift`, the existing `validateMenuItem(_:)` returns `true` for everything. Update it:

```swift
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        syncSidebarMenuState()
        if menuItem.action == #selector(exportMarkdownAsPDF(_:)) {
            return !(currentMarkdown?.isEmpty ?? true)
        }
        return true
    }
```

- [ ] **Step 5: Add the File menu item in the XIB**

In `md-preview/Base.lproj/MainMenu.xib`, find the "Print…" menu item (`id="aTl-1u-JFS"`). Immediately after its closing `</menuItem>` (and before the `</items>` that closes the File submenu), add:

```xml
                            <menuItem title="Export as PDF…" keyEquivalent="p" id=" exp-PDF-itm">
                                <modifierMask key="keyEquivalentModifierMask" option="YES" command="YES"/>
                                <connections>
                                    <action selector="exportMarkdownAsPDF:" target="-1" id="exp-PDF-act"/>
                                </connections>
                            </menuItem>
```

Remove the leading space in the `id` value so it reads `id="exp-PDF-itm"` (shown with a space only to avoid a duplicate-id collision if copy-pasted twice — the id must be unique and space-free). `target="-1"` is First Responder, so the action routes through the responder chain to `DocumentWindowController.exportMarkdownAsPDF(_:)`. `keyEquivalent="p"` + option + command = ⌥⌘P.

- [ ] **Step 6: Build and verify the menu/toolbar load**

Run: `xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add md-preview/DocumentWindowController.swift md-preview/Base.lproj/MainMenu.xib
git commit -m "feat(pdf): add Export as PDF menu item, toolbar item, and action"
```

---

### Task 7: Full unit run, app build, and manual verification

**Files:** none (verification only)

- [ ] **Step 1: Run the whole unit suite**

Run: `swift test --package-path tests/swift-tests`
Expected: all tests pass (existing tests + `PDFPageSizeTests` + `MarkdownExportAssetsTests`).

- [ ] **Step 2: Build the app**

Run: `xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual test plan**

Launch the app (run the `md-preview` scheme from Xcode, or open the built `.app`). Verify each:

- [ ] Open a Markdown file that contains **math, a Mermaid diagram, a fenced code block, a relative image, and footnotes**. Choose **File ▸ Export as PDF…** (or ⌥⌘P). A save panel appears with the file's name defaulted to `<name>.pdf`.
- [ ] Save it. Open the resulting PDF: it is **multi-page**, math/diagram/syntax-highlighting/image/footnotes are all present and fully rendered (no raw `$…$`, no missing diagram), there are **no copy buttons or Mermaid zoom HUD**, and there are no search highlight boxes.
- [ ] Output is **light** (dark text on white) even when the system/app is in **Dark Mode** (toggle System Settings ▸ Appearance to Dark, repeat the export).
- [ ] Page size matches your locale (US Letter in a US region; switch region to a European locale and confirm A4), with visible margins.
- [ ] Open a **folder** (no file selected) so the preview is empty: **Export as PDF…** is **disabled** in the File menu.
- [ ] Optionally drag the **Export PDF** toolbar item into the toolbar (right-click toolbar ▸ Customize Toolbar) and confirm it triggers the same save flow.
- [ ] Export a **very large** document and confirm it completes (exercises the readiness path; if a renderer hangs, the 8 s timeout still produces a best-effort PDF).

- [ ] **Step 4: Final commit (if any cleanup was needed)**

If Step 3 surfaced fixes, make them as their own focused commits referencing the failing check. Otherwise nothing to commit here.

---

## Self-Review notes

- **Spec coverage:** offscreen `.inline` render (Task 4) · silent `NSPrintOperation` to file (Task 4) · always-light via NSAppearance (Task 4) · locale-aware paper (Task 1, used in Task 4) · readiness signal + 8 s timeout (Tasks 2 & 4) · export CSS / hide chrome / @page / color-adjust / break-inside (Task 2) · Mermaid eager render for offscreen (Task 3) · sandbox read-write (Task 5) · File menu ⌥⌘P + custom selector + customizable toolbar item + validation (Task 6) · unit tests for the pure units (Tasks 1–2) · manual plan (Task 7). All spec sections map to a task.
- **Type consistency:** `PaperSize` / `PaperSize.forRegion` / `.pointSize` used identically in Tasks 1 and 4. `MarkdownExportAssets.headInjection`/`stylesheet`/`readinessScript` signatures match between Tasks 2 and 3. `exportMarkdownAsPDF(_:)` selector identical in Task 6's action, validation, toolbar item, and the XIB. Host message name `mdPreviewHost` and `{kind:"renderComplete"}` consistent between Task 2's script and Task 4's handler. `window.__mdPreviewRenderAll` set in Task 2's head injection and read in Task 3's bootstrap.
- **Test-target boundary:** only Foundation-only files (`PDFPageSize`, `MarkdownExportAssets`) are symlinked into the SwiftPM package; `MarkdownHTML`/`PDFExporter` (WebKit/AppKit) are verified by app build + manual plan, matching the repo's existing pure-helper testing convention.
