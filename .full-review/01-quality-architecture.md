# Phase 1: Code Quality & Architecture Review

## Code Quality Findings (by severity)

**High**
- **Q1 — `timeoutWork` not cancelled on navigation-failure path** (`PDFExporter.swift` finish/scheduleTimeout). `didFail`/`didFailProvisionalNavigation` call `finish()` directly, which never cancels the scheduled timeout DispatchWorkItem. Safe today only because of `[weak self]` + `didFinish`; fragile under refactor. Fix: move `timeoutWork?.cancel()` into `finish()`.
- **Q2 — highlight.js `requestAnimationFrame` time-slicing stalls offscreen** (`MarkdownHTML.swift` `highlightAllBody`). The export WebView is never in a window hierarchy, so WebKit throttles `rAF`. hljs got no `__mdPreviewRenderAll` eager path (Mermaid did), so code-heavy docs can exhaust the 8 s timeout and export with un-highlighted code, returned as `.success` with no user signal. Fix: synchronous highlight loop when `window.__mdPreviewRenderAll`.

**Medium**
- **Q3 — Timeout best-effort path returns `.success` for a possibly blank/partial PDF.** Caller only surfaces `.failure`; a timed-out render yields a wrong PDF silently. Fix: distinguish a `partialRender`/`timedOut` result, or at minimum `os.Logger` the timeout.
- **Q4 — Dual retention (`selfRetain` + implicit `WKUserContentController` strong-ref cycle).** Correct today but opaque; the project already has the idiomatic answer (`HostBridge` weak-owner proxy in `MarkdownWebView`). Fix: adopt a `MessageProxy` so `selfRetain` is the sole, truthful lifetime mechanism.

**Low**
- **Q5** — redundant `user-selected.read-only` left alongside new `read-write` in entitlements.
- **Q6** — file/type name mismatch: `PDFPageSize.swift` contains type `PaperSize`.
- **Q7** — Export toolbar item always enabled (no `NSUserInterfaceValidations`); only the menu item is validated. Pre-existing pattern, but most relevant for the empty-document case here.

**Verified correct:** `didFinish` race guard, single-fire `renderComplete`, Mermaid error paths unblock export, dataset↔attribute name mapping, `__mdPreviewRenderAll` ordering before renderer scripts, scheme-handler lifetime, `baseURL: nil` with inline vendors, sandbox scope, export CSS cascade/validity.

## Architecture Findings (by severity)

**Medium**
- **A1 — Shared `"mdPreviewHost"` handler name as two independent string literals** (`MarkdownWebView.HostBridge.name` and `PDFExporter.hostMessageName`). No runtime cross-talk (separate configs) but a hidden contract; the export bridge silently drops non-`renderComplete` messages (height/log/scroll). Fix: one shared constant.
- **A2 — Done-marker convention inconsistency + undocumented 8 s timeout.** KaTeX uses `dataset.mathDone`, hljs uses string attribute `data-hljs-done`; both valid but harder to audit. Timeout value has no documented rationale. (Overlaps Q2/Q3 on the readiness mechanism.)
- **A3 — `NSPrintOperation.run()` blocks the main thread with no progress UI.** The app appears frozen during export of large docs; print path uses `runModal` with a progress panel. Acceptable for v1; recommend an indeterminate progress sheet later.

**Low**
- **A4** — `exportMarkdownAsPDF` lives in `DocumentWindowController` (explicit `target=self`) while `printMarkdown` lives in `MainSplitViewController` (nil-target responder chain). Both correct for their designs; add a comment explaining the explicit target.
- **A5** — redundant read-only entitlement (same as Q5).
- `membershipExceptions` fix verified structurally correct; `forExport` flag is a clean seam; coupling to `MarkdownAssetScheme`/`MarkdownHTML`/`PaperSize` all appropriate; three-layer decomposition (pure → WebKit) praised as well-designed and unit-testable.

## Critical Issues for Phase 2 Context

- **Performance:** Q2 (hljs rAF stall offscreen → timeouts on code-heavy docs) and A3 (`operation.run()` main-thread block, no progress) are the primary performance/responsiveness concerns. Also assess offscreen-WebView render throughput and the 50 ms readiness poll.
- **Security:** Export reuses `MarkdownHTML.render` which sanitizes via DOMPurify before injection; assess the export-only injected `<script>`/`<style>` (readiness + `__mdPreviewRenderAll` + export CSS) for any new injection surface, the `md-asset://` scheme reuse, `NSSavePanel` path/extension handling, and the broadened `user-selected.read-write` entitlement under the sandbox.
