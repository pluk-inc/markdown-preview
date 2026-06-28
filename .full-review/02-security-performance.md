# Phase 2: Security & Performance Review

## Security Findings (7 findings: 0 Critical, 1 High, 4 Medium, 1 Low, 1 Info)

### High
- **S1: Entitlement over-breadth — `/` read-only + user-selected read-write.** The `/` absolute-path read exception (pre-existing) combined with the new write entitlement expands blast radius. A compromised code path could overwrite the user's currently-open file via autosave. Fix: scope read-only exception to `~/` or specific dirs.

### Medium
- **S2: Symlink following in MarkdownAssetScheme.resolve().** `standardizedFileURL` does not resolve symlinks. A symlink inside the document directory can escape the containment check, making arbitrary filesystem content available to WKWebView JavaScript via the CORS-open `md-asset://` responses. Fix: add `resolvingSymlinksInPath()` physical containment check.
- **S3: No duplicate-sheet guard on showExternalChangeAlert.** FileWatcher can fire multiple times (write + rename from atomic save), stacking modal sheets. Fix: track `externalChangeAlertIsVisible` flag.
- **S4: Filename Unicode injection in alert text.** RTL override characters (U+202E) in filenames can make the alert display a misleading filename. Fix: sanitize directional/invisible formatting chars.
- **S5: No document-size guard before applyHighlighting.** Opening a multi-MB markdown file causes sustained main-thread lock (CWE-400). Fix: skip highlighting above threshold.
- **S6: Per-keystroke regex recompilation (CWE-400).** Already identified in Phase 1 as C-2.

### Low
- **S7: Access-Control-Allow-Origin: * on md-asset:// responses.** Enables JS fetch of arbitrary document-dir files from any origin. Fix: use `null` or omit header.

### Cleared
- WKWebView XSS pipeline: DOMPurify correctly fail-closed, host bridge exposes no write primitives
- NSTextView input handling: null bytes dropped by UTF-8 decode, no additional vulns

## Performance Findings (11 findings: 2 Critical, 5 High, 3 Medium, 1 Low)

### Critical
- **P1: Per-keystroke regex compilation (8 patterns).** 1.2–3.6ms wasted per keystroke compiling DFA from string literals. Fix: cache as private let/lazy var.
- **P2: Full-document synchronous attribute reset + layout flush.** Total main-thread cost: 25–66ms per keystroke on a 50KB document. Exceeds 16.7ms frame budget always. Debounce only protects the WKWebView render, not the highlighting. Fix: two-stage architecture (incremental dirty-range, async full pass).

### High
- **P3: O(M×K) intersection test.** 915,000 `NSIntersectionRange` calls on a 50KB tutorial. 3–8ms per pass. Fix: binary search on sorted ranges (~100× speedup).
- **P4: Fence scanner allocation storm.** 4 heap allocations × 2000 lines = 8000 allocs per highlight pass. Fix: stay in NSString, use range arithmetic.
- **P5: `textView.string` value-copy per keystroke.** Swift String bridging from NSTextView copies the entire buffer. Fix: capture only when needed (inside the debounce callback).
- **P6: Sidebar + Inspector synchronous parse on every debounce tick.** `display()` calls `SidebarViewController.display()` (runs `MarkdownTOC.parse()`, O(n) line scan) and `InspectorViewController.display()` (runs `DocumentMetadata.make()`, word/line/heading/link counts). 5–20ms additional per debounce. Fix: debounce sidebar/inspector updates separately or skip when unchanged.
- **P7: glyph-run fragmentation from 8+ addAttributes calls.** Each `addAttributes` fragments glyph runs; NSLayoutManager must merge/split on every call. For 500 matches this creates 1000+ glyph runs, making `endEditing` layout expensive. Fix: batch attributes into a single pass.

### Medium
- **P8: Competing NSScrollView layout passes.** Two independent scrollable panes (editor + preview) trigger independent Auto Layout passes. Minor but additive.
- **P9: No dirty-range tracking.** The full-document highlight runs even when the user typed a single character. Fix: track `editedRange` from NSTextStorage and highlight only affected paragraphs.
- **P10: Debounce (200ms) is correctly tuned for the render pipeline but provides zero protection for the synchronous highlighting path.**

### Low
- **P11: WKWebView total keystroke-to-preview latency 285–496ms.** This is a combination of debounce (200ms), render (20–80ms), and JS evaluation (65–216ms). Acceptable for a preview but could be improved with incremental rendering.

## Critical Issues for Phase 3 Context

1. **Synchronous highlighting exceeds frame budget** (P2) — testing should verify UI responsiveness on large files
2. **Autosave + FileWatcher race** produces false alerts — test the save-then-external-change scenario
3. **Symlink following** in asset scheme — security test needed
4. **No test coverage** exists for any of the new editing code paths
