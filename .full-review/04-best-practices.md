# Phase 4: Best Practices & Standards

## Framework & Language (Swift 6 / AppKit / WebKit) Findings

**Medium**
- **BP1 — Completion closure should be `@MainActor`-annotated.** `completion: @escaping (Result<URL, Error>) -> Void` is created and invoked only on `@MainActor`, but under Swift 6 strict isolation an escaping closure crossing isolation should be `@MainActor` (the codebase already uses `@MainActor @Sendable` for `decidePolicyFor`). Sound today (same-actor), but annotate to document the contract and future-proof. (`Result<URL, Error>` non-Sendable is fine for the same reason.)
- **BP2 — `NSPrintInfo(dictionary:)` diverges from the house `NSPrintInfo.shared.copy()` pattern** (`MarkdownWebView.printDocument`). Defensible here (export wants a clean slate, not the user's printer defaults) and the `.jobDisposition`/`.jobSavingURL` keys are non-deprecated — but add a one-line comment explaining the deliberate divergence.
- **BP3 — Direct `self` registration with `WKUserContentController`** instead of the established `HostBridge` weak-proxy idiom (overlaps Q4). Safe via `selfRetain`+`removeScriptMessageHandler`, but opaque vs the project's own answer.

**Low**
- **BP4** — `validateMenuItem` covers only the menu item; adopt `NSUserInterfaceValidations.validateUserInterfaceItem` (as `MarkdownDocument` does) to cover the toolbar item too (overlaps Q7).
- **BP5** — `MainActor.assumeIsolated` in the `scheduleTimeout` closure is unnecessary (the `DispatchQueue.main.asyncAfter` block already runs on main); the rest of the codebase uses a plain `DispatchQueue.main.async { self?... }`.
- **BP6** — `"mdPreviewHost"` duplicated as two independent literals (overlaps A1); extract a shared constant.

**Verified correct / idiomatic (no action):** `@MainActor` on `PDFExporter`; `nonisolated` on `PaperSize`/`MarkdownExportAssets`; `Locale.current.region` (modern, replaces deprecated `regionCode`); `NSSavePanel.allowedContentTypes` (modern); toolbar/`systemSymbolName` construction; `loadHTMLString(baseURL:nil)`; `NSAppearance(named:.aqua)`; **`printOperation` over `createPDF` confirmed correct for paginated output via Context7 Apple docs**; offscreen `WKWebView` construction.

## CI/CD & DevOps Findings

**Critical**
- **CI3 — Missing CHANGELOG entry is a hard release stop** (= D1). Confirmed in `scripts/release.sh`: `grep -q "^## \[$VERSION\]"` → `exit 1` under `set -euo pipefail`, before any version bump / amore / tag. Latest entry is `## [0.0.26]`; `Version.xcconfig` at 0.0.26 (30). Author next entry via `changelog-maintenance` skill on the release branch.

**High**
- **CI1 — CI never compiles the app target.** `swift-tests.yml` runs only `swift test` on the SPM helpers; `PDFExporter`/`MarkdownExportAssets`/`PDFPageSize`/`DocumentWindowController`/entitlements are never built in CI — so the concurrency-warning regression we hit earlier would pass CI green, and the Phase-3 integration test (T3) would be invisible. **Fix:** add an `xcodebuild build` job with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` (YAML provided), plus an `xcodebuild test` job gated for when the `md-previewTests` target lands. Make them required checks.

**Medium**
- **CI2 — New `read-write` entitlement: no notarization/signing blocker** (Apple-sanctioned for save-panel writes; Amore/Sparkle/EdDSA unaffected), but validate it's embedded in the signed app once via `codesign -d --entitlements` before the first release; remove the redundant `read-only` key (= S2).
- **CI4 — No `os.Logger` on the timeout / navigation-failure / print-result paths.** A field "blank PDF" report would be undiagnosable. The codebase already has `Logger.perf` (subsystem `doc.md-preview`). Add a `.warning` on timeout and `.error` on nav-failure (overlaps D3/D5).

**Low**
- **CI5 — Release path:** merge `feat/add-pdf-export` → `main`, then cut `release/0.0.27`, add changelog, run `release.sh` locally (needs Keychain/notary/EdDSA/Developer ID — not CI). `release.sh` doesn't enforce the branch name; it's a CLAUDE.md convention.

**N/A (noted):** blue-green/canary, IaC, k8s, dashboards, DB migrations — not applicable to a notarized Sparkle/Amore-distributed Mac app.
