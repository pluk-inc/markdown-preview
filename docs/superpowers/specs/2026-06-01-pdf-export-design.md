# PDF Export — Design

**Date:** 2026-06-01
**Branch:** `feat/add-pdf-export`
**Status:** Approved (design); pending implementation plan

## Summary

Add a dedicated **Export as PDF…** feature to Markdown Preview. The macOS Print
panel can already save a PDF, so this feature is about a clean, one-click path
straight to a save panel that produces print-friendly, correctly paginated
output — independent of the user's current zoom, scroll position, and search
highlights.

The PDF is produced by rendering the document into a **dedicated offscreen
`WKWebView`** (separate from the live preview), waiting until it is fully laid
out and all asynchronous renderers (KaTeX, Mermaid, highlight.js) have settled,
then running a **silent `NSPrintOperation` to a file**.

## Background — how rendering and printing work today

- All preview rendering is WebKit. `MarkdownHTML.render()`
  (`md-preview/MarkdownHTML.swift`) turns markdown into a single self-contained
  HTML document, displayed in a `WKWebView` wrapped by `MarkdownWebView`
  (`md-preview/MarkdownWebView.swift`).
- Two vendor-loading modes exist (`MarkdownHTML.VendorLoading`): `.inline`
  (KaTeX/Mermaid/highlight.js embedded directly — self-contained, used by Quick
  Look) and `.lazy` (vendor JS fetched via `md-asset:///__vendor/...` after
  first paint — used by the live app). Math, Mermaid, and code highlighting all
  render **asynchronously** after the page loads.
- Printing already exists: File ▸ Print… (`MainMenu.xib`) → `printMarkdown:`
  (`MainSplitViewController`) → `ContentViewController.printDocument()` →
  `MarkdownWebView.printDocument(from:)`, which runs `webView.printOperation(with:)`.
  A Print toolbar item exists too (`DocumentWindowController`).
- The app is sandboxed. `md-preview.entitlements` currently grants only
  `com.apple.security.files.user-selected.read-only` plus
  `com.apple.security.print`.

## Key decisions

| Decision | Choice |
|---|---|
| Export source | Fresh **offscreen `.inline` render**, not the live preview |
| Generation API | **Silent `NSPrintOperation` to file** (not `WKWebView.createPDF`) |
| Color scheme | **Always light**, regardless of app/system appearance |
| Page size | **Locale-aware** default (A4 vs US Letter); no in-app chooser in v1 |
| UI surface | **File menu item (⌥⌘P) + customizable toolbar item** |

### Why `NSPrintOperation`, not `createPDF`

`WKWebView.createPDF` emits a single content-sized page rather than pages broken
to a paper size; true pagination at a chosen paper size on macOS comes from the
print path (`NSPrintOperation`). Using `NSPrintOperation` also reuses the proven
WebKit print path the existing Print menu already relies on. The PDF is written
by setting `jobDisposition = .save`, `jobSavingURL = <destination>`,
`showsPrintPanel = false`, `showsProgressPanel = false`, and calling
`runOperation()`.

### Why an offscreen render, not the live view

Exporting the on-screen web view would inherit the user's page zoom, any active
search `<mark>` highlights, and the async-render race (diagrams may be missing
if the user exports early). A fresh offscreen render in `.inline` mode is
self-contained (no `md-asset` vendor fetch race), and the export is independent
of preview UI state.

## Components

### A. `PDFExporter` (new file `md-preview/PDFExporter.swift`)

One focused type with a single responsibility: turn markdown + a destination
into a PDF file.

- **Inputs:** `markdown: String`, `assetBaseURL: URL?`, `destinationURL: URL`,
  `pageConfig: PageConfig`, completion handler reporting success/failure.
- **Owns** its own offscreen `WKWebView` (not the preview's). Registers a
  `MarkdownAssetScheme` handler bound to `assetBaseURL` so relative image
  references resolve exactly as in the preview. Registers a
  `WKScriptMessageHandler` for the readiness signal.
- **Flow:** build HTML via `MarkdownHTML.render(markdown:, assetBaseHref:,
  vendorLoading: .inline, forExport: true)` → `loadHTMLString` → await readiness
  (see C) → configure `NSPrintInfo` (see E) → `printOperation(with:)` →
  `runOperation()` writing to `destinationURL` → call back.
- **Lifetime:** retains itself until completion so it isn't deallocated mid-export.

### B. Render-readiness signal

`MarkdownHTML.render(…, forExport: true)` injects an export-only readiness
coordinator into the page. Swift already computes which renderers a document
needs (`containsMath` / `containsMermaid` / `containsCode` on `RenderedHTML`),
so it passes that expected set into the page. The coordinator waits for:

- `window.load` (covers images and inline vendor scripts), **and**
- each expected `md-preview-{math,mermaid,hljs}-rendered` event (already
  dispatched by the existing renderers),

then, after a `requestAnimationFrame` settle, posts `{kind: "renderComplete"}`
over the existing `HostBridge` message channel.

The exporter awaits that message with an **8-second timeout fallback**: on
timeout it performs a best-effort export of whatever has rendered rather than
hanging or failing.

### C. Export stylesheet

A `forExport` CSS block, added to the stylesheet in `MarkdownHTML.swift` and
emitted only when `forExport` is true:

- force light `color-scheme`;
- `print-color-adjust: exact` so code-block / syntax-highlight backgrounds survive;
- hide `.md-code-copy` (copy buttons) and `.mermaid-hud` (zoom HUD);
- neutralize `.md-search-highlight` styling;
- `@page { margin: … }`;
- `break-inside: avoid` on code blocks, tables, and Mermaid figures.

The export web view stays at page zoom 1.0.

### D. Locale-aware page size

A pure function maps `Locale.current.region` to a paper choice:

- **US Letter** for Letter-using regions (e.g. US, CA, MX, CL, CO);
- **A4** for everything else.

It sets `NSPrintInfo.paperName`/size and margins accordingly. No in-app chooser
in v1.

### E. Sandbox entitlement

Add `com.apple.security.files.user-selected.read-write` to
`md-preview.entitlements`. `NSSavePanel` + Powerbox grants a write extension to
the user-chosen destination. The Quick Look target's entitlements are untouched.
Save / Save As remain disabled — export is a standalone action, not `NSDocument`
saving.

### F. UI wiring

- **File menu:** add "Export as PDF…" after Print… in `MainMenu.xib`, custom
  selector `exportMarkdownAsPDF:` (custom rather than a system selector, mirroring
  `printMarkdown:`, so AppKit's responder chain doesn't intercept it higher up),
  key equivalent **⌥⌘P** (currently free; Print is ⌘P, Page Setup is ⇧⌘P), target
  = First Responder.
- **Toolbar:** new `.exportPDF` toolbar item identifier in
  `DocumentWindowController` — **allowed but not in the default set** (user can
  drag it in), SF Symbol `arrow.down.document`, same action.
- **Validation:** both surfaces enabled only when a document with content is open.

## Data flow

1. User triggers `exportMarkdownAsPDF:` (menu or toolbar).
2. `DocumentWindowController` (holds `currentMarkdown` + `currentFileURL`) handles
   it; the action is disabled when no document is open.
3. Present an `NSSavePanel` sheet — default file name = current file basename +
   `.pdf`, `allowedContentTypes = [.pdf]`.
4. On OK, construct a `PDFExporter` with the markdown, `assetBaseURL =
   fileURL.deletingLastPathComponent()`, the chosen destination, and the page config.
5. The exporter renders offscreen, awaits readiness, and prints to the file.
6. On success the file is written (no further UI in v1; revealing in Finder is a
   possible later addition). On failure, show an `NSAlert` on the window.

## Error handling

- **Render timeout:** best-effort export (do not fail the user).
- **Print / write failure:** `NSAlert` with the localized error on the document window.
- **No document open:** menu and toolbar items disabled via validation;
  `NSSound.beep()` as a backstop if somehow invoked.

## Testing

- **Unit (pure, no UI):**
  - locale → paper-name mapping table (region inputs → expected paper);
  - `MarkdownHTML.render(forExport: true)` string assertions: output contains an
    `@page` rule, hides the copy button and Mermaid HUD, sets a light color
    scheme, and includes the readiness coordinator.
  - Confirm during planning whether a test target exists; if none, note it and
    rely on the manual plan (do not silently skip).
- **Manual test plan:**
  - Export a document combining math + Mermaid + code + images + footnotes →
    verify multi-page output, light theme, no copy buttons / HUD, images present,
    correct paper size.
  - Folder-browsing mode (no file) → export disabled.
  - Very large document → completes (readiness timeout path exercised if needed).
  - App in dark mode → exported PDF is still light.

## Out of scope (v1)

- In-app page-size / margin chooser.
- Per-export light/dark toggle.
- Reveal-in-Finder / open-after-export.
- Batch export of multiple files.

## Files touched

- `md-preview/PDFExporter.swift` (new)
- `md-preview/MarkdownHTML.swift` (`forExport` flag: export CSS + readiness coordinator)
- `md-preview/md-preview.entitlements` (add user-selected read-write)
- `md-preview/Base.lproj/MainMenu.xib` (File ▸ Export as PDF…)
- `md-preview/DocumentWindowController.swift` (`exportMarkdownAsPDF:`, save panel,
  toolbar item, validation)
- Tests (location TBD-by-target-existence during planning)
