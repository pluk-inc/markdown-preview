# Comprehensive Code Review Report — Export as PDF

## Review Target

All code implementing the **Export as PDF** feature on `feat/add-pdf-export`
(commits `ac5879a..93e1f0a`): offscreen-`WKWebView` render → readiness wait →
silent `NSPrintOperation` to file. 8 source/config files + 4 test/symlink files +
a `pbxproj` membership edit. Reviewed across 8 dimensions by parallel agents.

## Executive Summary

The feature is **well-architected and idiomatic** — the three-layer decomposition
(pure `PaperSize`/`MarkdownExportAssets` → WebKit `PDFExporter`), the reuse of
`MarkdownHTML.render(forExport:)`, forced-light via `NSAppearance`, and the
`printOperation`-for-pagination choice are all correct (the last confirmed against
Apple docs). It compiles clean and 47 unit tests pass. **But two issues are
release-relevant**, and both slipped past the green build precisely because the
WebKit export path has zero automated coverage: a **Critical silent-rendering bug**
(code-heavy docs export un-highlighted) and a **Critical release blocker** (no
CHANGELOG entry). One **High security** issue (silent network fetch during export)
and several robustness/observability gaps round out the must-fix set.

## Findings by Priority

### Critical (P0 — Must Fix Before Release)

- **C1 — highlight.js stalls in the offscreen export WebView → silent un-highlighted PDFs.**
  (Perf P1 / Quality Q2 / Testing T1) WebKit throttles `requestAnimationFrame` for
  unparented web views — the repo's own `afterPaint` comment documents this. `highlightAll()`
  uses rAF with no eager fallback (Mermaid got `__mdPreviewRenderAll`; hljs didn't), so
  code-heavy docs never set `data-hljs-done`, hit the 8 s timeout, and export with plain code
  as a silent `.success`. **Fix:** synchronous highlight loop gated on `window.__mdPreviewRenderAll`
  in `MarkdownHTML.highlightAllBody` (mirror Mermaid). Add the T1 contract test.
- **C2 — Missing `CHANGELOG.md` entry blocks release.** (Docs D1 / DevOps CI3) `release.sh`
  `grep`s for `## [VERSION]` and `exit 1`s before any release action. **Fix:** author the next
  entry (Added: PDF export, ⌥⌘P + toolbar, light render, locale paper, `read-write` entitlement)
  via the `changelog-maintenance` skill on the release branch.

### High (P1 — Fix Before Merge / Next Release)

- **H1 — Silent network exfiltration during export.** (Security S1) `network.client` is app-wide
  and the export WebView does no sub-resource filtering, so a remote `![](https://…)` (DOMPurify
  permits `<img>`/`https:`) phones home during the silent render. **Fix:** add a `WKContentRuleList`
  restricting the export config to the `md-asset://` scheme.
- **H2 — `timeoutWork` not cancelled on navigation-failure path.** (Quality Q1) `finish()` doesn't
  cancel the pending timeout; safe only by accident today. **Fix:** move `timeoutWork?.cancel()` into `finish()`.
- **H3 — `NSPrintOperation.run()` blocks the main thread with no progress UI.** (Perf P2 / Arch A3)
  App appears frozen 0.5–15 s. **Fix:** `operation.showsProgressPanel = true` (v1) and/or a progress sheet.
- **H4 — `PDFExporter` class comment misstates the lifetime mechanism.** (Docs D2) Claims `selfRetain`;
  the `WKUserContentController` strong-ref cycle is the real anchor. Misleads `finish()` refactors.
- **H5 — No automated coverage of the export pipeline.** (Testing T2/T3) Add the readiness-flag
  permutation test and a `md-previewTests` XCTest target driving `PDFExporter` to a temp PDF (asserts
  non-trivial size → catches stalled renders).
- **H6 — CI never compiles the app target.** (DevOps CI1) Only `swift test` runs; the earlier
  concurrency-warning regression would pass CI. **Fix:** `xcodebuild build` job with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.

### Medium (P2 — Plan for Next Sprint)

- **M1** (Q3/P3) — timeout returns silent `.success` for partial renders; raise to ~30 s, add a `timedOut`/`partialRender` signal.
- **M2** (Q4/BP3) — adopt the `HostBridge` weak-proxy so `selfRetain` is the sole, truthful lifetime mechanism.
- **M3** (A1/BP6) — extract the duplicated `"mdPreviewHost"` name into one shared constant.
- **M4** (A2/D11) — standardize the `data-*-done` marker convention across KaTeX/hljs/Mermaid; document it.
- **M5** (BP1) — annotate the completion closure `@MainActor`.
- **M6** (BP2) — comment the deliberate `NSPrintInfo(dictionary:)` (clean-slate) divergence.
- **M7** (D3/D4/D5/CI4) — document the 8 s timeout rationale, the offscreen-rAF constraint on `highlightAllBody`, and the best-effort/silent contract; add `os.Logger` `.warning`/`.error` on timeout & nav-failure.
- **M8** (T4/T5/T6/T7) — exhaustive `letterRegions` + empty-string + portrait tests; `headInjection` permutations + flag-ordering; marker-name consistency.
- **M9** (CI2) — validate the embedded entitlement via `codesign -d` before first release.

### Low (P3 — Backlog)

- **L1** (Q5/A5/S2) remove the now-redundant `user-selected.read-only` entitlement.
- **L2** (Q6) rename `PDFPageSize.swift` → `PaperSize.swift` (or rename the type).
- **L3** (Q7/BP4) adopt `NSUserInterfaceValidations` so the toolbar item validates like the menu item.
- **L4** (A4) comment why `exportMarkdownAsPDF` uses an explicit toolbar `target` vs the print item's nil-target.
- **L5** (BP5) drop the unnecessary `MainActor.assumeIsolated` in `scheduleTimeout`.
- **L6** (P4) make readiness event-driven (`md-preview-*-rendered`) with the poll as a safety net.
- **L7** (P5) guard against concurrent/rapid repeat exports.
- **L8** (T8/T9) add `xcodebuild test` to CI; de-brittle the CSS substring assertions.
- **L9** (D6–D10) doc polish: `.aqua` rationale, `membershipExceptions` comment + plan-note fix, CLAUDE.md entitlement note, design-doc `run()`/status drift, README feature bullet.
- **L10** (CI5) follow the `main` → `release/X.Y.Z` path for shipping.

## Findings by Category

- **Code Quality:** 7 (—C / 1H / 2M / 3L; +1 Critical shared with Performance)
- **Architecture:** 5 (—C / 1H / 2M / 2L)
- **Security:** 2 (—C / 1H / — / 1L)
- **Performance:** 5 (1C / 1H / 1M / 2L)
- **Testing:** 9 (1C shared / 2H / 4M / 2L)
- **Documentation:** 11 (1C / 1H / 3M / 6L)
- **Best Practices:** 6 (—C / — / 3M / 3L)
- **CI/CD & DevOps:** 5 (1C shared with Docs / 1H / 2M / 1L)

Distinct issues: **2 Critical**, **6 High**, **9 Medium**, **10 Low** (overlapping
findings across dimensions collapsed; e.g. P1/Q2/T1 = C1, D1/CI3 = C2).

## Recommended Action Plan

1. **Before anything ships (small):** C1 hljs eager path + its T1 test; C2 CHANGELOG entry.
2. **Before merge to main (small–medium):** H1 `WKContentRuleList`; H2 cancel timeout in `finish()`; H4 fix class comment; H6 add `xcodebuild build` CI gate with warnings-as-errors.
3. **Same PR or fast follow (medium):** H3 progress panel; H5 export integration test + permutation tests; M1 timeout result signal + raise to 30 s; M7 inline docs + `os.Logger`.
4. **Next sprint (medium):** M2–M6, M8, M9.
5. **Backlog (low):** L1–L10 (quick wins: L1 entitlement cleanup, L2 file rename, L5 drop `assumeIsolated`).

Group naturally: the C1 + H3 + M1 + M7 cluster all live in the render/timeout path
and are best fixed together; H6 + L8 are one CI change; L1 + L9(CLAUDE.md) + C2 are
all release-prep.

## Review Metadata

- Review date: 2026-06-01
- Phases completed: 1 (Quality+Architecture), 2 (Security+Performance), 3 (Testing+Documentation), 4 (Best Practices+CI/CD), 5 (Consolidation)
- Method: parallel subagents per dimension; findings written to `.full-review/0X-*.md`
- Flags: none (`--strict-mode` off); framework auto-detected = Swift 6 / AppKit / WebKit
- Verification note: all findings cite real files/lines; the C1 bug is corroborated by the codebase's own `afterPaint` comment; the C2 blocker confirmed by reading `release.sh`.
