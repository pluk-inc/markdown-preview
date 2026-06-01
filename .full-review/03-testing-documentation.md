# Phase 3: Testing & Documentation Review

## Test Coverage Findings (by severity)

**Critical**
- **T1 — No test asserts highlight.js has an offscreen-safe/eager path** (the direct miss behind P1). The whole WebKit export pipeline (`PDFExporter`, `MarkdownHTML.highlightHead`/`mermaidScript`/`katexHead`) is unreachable from the SPM package, so a green CI run + 47 tests proved nothing about export rendering. **Fix:** extract the renderer JS contract (`highlightAllBody`, `mermaidInitWiring`) into a pure, symlinkable unit and assert "for each of math/mermaid/code, an offscreen-safe completion path exists" — a string assertion that fails until the P1 fix lands.

**High**
- **T2 — `readinessScript` only tested for all-true/all-false**; the other 6 renderer-flag permutations (cross-wiring risk) untested. Provided a permutation-sweep test.
- **T3 — Full `PDFExporter` pipeline never exercised**; silent `.success`-on-timeout undetectable. Recommend a new `md-previewTests` Xcode XCTest target driving `PDFExporter` to a temp PDF and asserting non-trivial size (a stalled render yields a tiny/blank file). Async `withCheckedContinuation` pattern given.

**Medium**
- **T4** — only 3 of 14 `letterRegions` verified (typo in a region code silently → A4); empty-string and portrait-orientation invariants unasserted.
- **T5** — `headInjection` tested for only 1 of 8 combinations; `__mdPreviewRenderAll` should be asserted present unconditionally.
- **T6** — flag-precedes-readiness ordering in `headInjection` unasserted.
- **T7** — done-marker name consistency only covered on the selector side (the setter side lives in non-SPM code; resolved by the T1 extraction).

**Low**
- **T8 — CI runs only `swift test`; no `xcodebuild test`.** Any Xcode XCTest target (T3) would be invisible to PR checks. Recommend adding an `xcodebuild test` job on the macOS-15 runner.
- **T9** — CSS substring assertions are brittle to reformatting / vendor prefixes; add prefix-tolerant variants and `message:` args.

**Well-covered:** `PaperSize` happy paths and `MarkdownExportAssets` core string contracts are tested in the right place (pure SPM units); behavior-oriented, not implementation-coupled (mostly).

## Documentation Findings (by severity)

**Critical**
- **D1 — `CHANGELOG.md` entry is missing.** `release.sh` validates a changelog entry for the version and hard-stops without it — this blocks release. Must be authored via the `changelog-maintenance` skill (Added: PDF export, ⌥⌘P + toolbar item, offscreen light render, locale-aware paper, new `read-write` entitlement).

**High**
- **D2 — `PDFExporter` class comment misstates the lifetime mechanism** (claims `selfRetain` is it; the `WKUserContentController` strong-ref cycle is the real anchor, released by `removeScriptMessageHandler` in `finish()`). Misleads anyone refactoring `finish()`. Provided corrected comment + callsite note (overlaps Q4).

**Medium**
- **D3 — 8 s timeout has no documented rationale**; **D4 — offscreen-rAF constraint on `highlightAllBody` undocumented** (the `afterPaint` helper documents the same constraint 350 lines earlier; `highlightAllBody` doesn't); **D5 — best-effort/silent-on-timeout contract** only a one-liner. All three directly enabled the missed P1 bug. Concrete comments provided.

**Low**
- **D6** — `.aqua` appearance: explain it's *required* (drives Mermaid `matchMedia`), not just CSS.
- **D7** — `membershipExceptions` undocumented; the plan's "never edit project.pbxproj" claim was wrong for files shared into quick-look — add an inline comment + fix the plan's background note.
- **D8** — CLAUDE.md project facts don't note the new `read-write` entitlement.
- **D9** — design-doc drift: `runOperation()` vs `operation.run()`; design-doc status still "pending implementation plan."
- **D10** — README Features list omits Export as PDF.
- **D11** — `readinessScript` doc comment should document the `data-*-done` marker contract per renderer.

**Accurate as written:** `.aqua`/light claim, `headInjection` ordering claim, "forced light, vendor inline" class comment.

## Notes for Phases 4-5

- The testing and documentation gaps share one root cause with the Critical/High code findings: **the export render path has no automated coverage and its non-obvious constraints (offscreen rAF, best-effort timeout) aren't written down.** The single highest-leverage remediation is the T1 extraction (makes the renderer-contract testable) + the D-series inline docs.
- Release readiness is gated on D1 (changelog) regardless of the code fixes.
