# Phase 2: Security & Performance Review

## Security Findings (by severity)

**High**
- **S1 — Network exfiltration during silent export render** (`PDFExporter.swift`, `entitlements`). The app holds `com.apple.security.network.client` app-wide; the export WebView loads with no `decidePolicyFor` sub-resource filtering. A remote `<img src="https://attacker/track?…">` in markdown (DOMPurify allows `<img>` + `https:`) fires a live network request during export — silently, with no loading UI, returning `.success` regardless. Worse than the live preview because it's user-unaware. **Fix:** add a `WKContentRuleList` to the export config blocking all sub-resource loads except the `md-asset://` scheme (CWE-200/918). Alternatives: forbid non-relative `<img src>` in DOMPurify, or drop `network.client` if only Sparkle/XPC needs it.

**Low**
- **S2 — Redundant `user-selected.read-only` alongside `read-write`** (same as Q5/A5). One-line cleanup; no exploit.

**Confirmed safe (no action):** article HTML is DOMPurify-sanitized identically on the export path (export-only injections are static compile-time literals, not user-derived); `<template>` inert-parse + fail-closed sanitizer hold; `</template` escaping intact; `md-asset://` `resolve()` prefix-check prevents path traversal in export context; `NSSavePanel`/Powerbox is the only write path, `nameFieldStringValue` uses `lastPathComponent` (no path injection); no PDF metadata/path leakage; vendor JS bundled at compile time (no runtime supply chain). Web-app OWASP items (SQLi, auth, SSRF, deserialization) N/A.

## Performance Findings (by severity)

**Critical**
- **P1 — highlight.js `requestAnimationFrame` stalls in the offscreen export WebView** (`MarkdownHTML.swift` `highlightAllBody`). Confirmed: WebKit pauses rAF for unparented web views (the repo's own `afterPaint` comment documents this and works around it with `setTimeout(50)`). `highlightAll()` has no such fallback and no `__mdPreviewRenderAll` eager path, so `data-hljs-done` is never set, the readiness poll never resolves, the 8 s timeout fires, and code-heavy docs export **un-highlighted** as a silent `.success`. KaTeX (synchronous) and Mermaid (`drain()` async/await + eager bypass) are unaffected. **Fix:** synchronous highlight loop gated on `window.__mdPreviewRenderAll`, mirroring Mermaid (~200–400 ms for 500 blocks).

**High**
- **P2 — `NSPrintOperation.run()` blocks `@MainActor` with no progress UI** (same root as A3). 0.5–2 s typical, 5–15 s for large docs; app shows as "not responding." Can't move off main thread. **Fix:** set `operation.showsProgressPanel = true` (one line, v1) and/or a progress sheet on the document window (v1.1).

**Medium**
- **P3 — 8 s timeout is at the low edge; silent partial render returned as `.success`** (overlaps Q3). With the P1 fix, worst-case Mermaid-heavy docs still approach 4–8 s. **Fix:** raise to ~30 s, `os.Logger` the timeout, and surface a `timedOut`/`partialRender` signal instead of silent success.

**Low**
- **P4 — 50 ms `querySelector` poll** adds up to one-interval latency and rescans the DOM each tick. The renderers already dispatch `md-preview-{math,mermaid,hljs}-rendered` events — listen for those and keep the poll only as a safety net (near-zero latency).
- **P5 — Concurrent/rapid repeat exports** each hold a ~6 MB WebView + inline vendor bundles; toolbar item isn't validated (Q7). Single-export lifetime is clean (`selfRetain`+`removeScriptMessageHandler` ordering correct, prompt teardown). **Fix:** guard against an in-flight export.

**Confirmed efficient:** KaTeX synchronous; Mermaid eager bypass correct; no leaked WebViews; `.inline` vendor mode right for export; `__mdPreviewRenderAll` injected before renderer scripts.

## Critical Issues for Phase 3 Context

- **Testing gap is the through-line:** P1 (a Critical silent correctness bug) and S1 survived a green build + 47 passing unit tests because **no test renders a representative document (code/math/mermaid/remote-image) through the export pipeline and inspects the output**. Phase 3 should weigh: an integration/headless test that drives `PDFExporter` (or at least asserts the readiness/`__mdPreviewRenderAll` contract and that each renderer has an offscreen-safe path), and tests for the locale/paper and CSS-injection units (already present). Pure units (`PaperSize`, `MarkdownExportAssets`) are well-covered; the WebKit integration is entirely manual-only.
- **Docs:** the 8 s timeout, the offscreen-rAF constraint, and the "export is best-effort/silent-on-timeout" contract are undocumented and directly caused the missed bug.
