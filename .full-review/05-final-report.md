# Comprehensive Code Review Report

## Review Target

**Feature:** Editing support (Option A: Side-by-Side Editor + Live Preview)
**Branch:** `feat/add-editing-support`
**Base:** `7fc5aa2` (Release 0.0.28, viewer-only)
**Scope:** 7 source files, 481 lines added, 24 removed
**App:** Markdown Preview — macOS AppKit, sandboxed, NSDocument architecture

## Executive Summary

The editing feature is **architecturally sound** — the unidirectional data flow (editor → document → preview), the callback chain through MainSplitViewController, and the separation of concerns between EditorViewController, MarkdownDocument, and the existing preview pipeline are all correct and follow the project's established AppKit patterns.

However, the implementation has **three ship-blocking defects** (data loss on panel toggle, autosave/FileWatcher race producing false alerts, and a pre-existing SUFeedURL mismatch), **significant performance regressions** (per-keystroke regex compilation and full-document attribute reset that exceed the 16.7ms frame budget), and **zero test coverage** across all 482 lines of new code. The documentation is entirely unchanged and still describes a read-only viewer.

The fixes are well-scoped — the architecture does not need redesign; the issues are implementation-level defects within a well-reasoned structure.

---

## Findings by Priority

### Critical Issues (P0 — Must Fix Before Merge)

| # | Finding | Source | Files | Fix Effort |
|---|---------|--------|-------|------------|
| 1 | **Editor text overwritten on panel toggle** — `toggleEditorAction` calls `setEditorText(currentMarkdown)` on every open, but `currentMarkdown` lags by up to 200ms. Reopening within the debounce window silently discards in-progress edits. | Phase 1 C1 | `DocumentWindowController.swift:1148-1155` | Small — remove the `if isVisible { setEditorText }` block |
| 2 | **Autosave triggers false "File Modified Externally" alert** — `autosavesInPlace=true` means the app writes to disk, but FileWatcher fires before `isDocumentEdited` is cleared, showing the alert for the app's own save. | Phase 1 C-1, Phase 2 M3 | `MarkdownDocument.swift`, `DocumentWindowController.swift:163-175` | Small — add `isSaving` flag around save pipeline |
| 3 | **Per-keystroke regex compilation (8 patterns)** — 1.2–3.6ms of DFA compilation wasted per keystroke. Only `fenceOpenRegex` is cached. | Phase 1 C-2, Phase 2 P1 | `MarkdownSyntaxHighlighter.swift:194-227` | Small — cache as `private let` properties |
| 4 | **Full-document synchronous highlighting exceeds frame budget** — 25–66ms per keystroke on 50KB documents. `setAttributes` full-range reset + 8 regex passes + `endEditing` layout flush, all synchronous on main thread. Debounce only protects WKWebView, not highlighting. | Phase 2 P2 | `MarkdownSyntaxHighlighter.swift:28-129`, `EditorViewController.swift:80-92` | Medium — incremental dirty-range highlighting or debounced full pass |
| 5 | **No build step in CI for editing code** — `swift-tests.yml` only compiles 3 SPM helpers. Compiler errors in all 5 changed/new AppKit files are invisible to CI. | Phase 4 CI1 | `.github/workflows/swift-tests.yml` | Small — add `xcodebuild build` step |
| 6 | **SUFeedURL mismatch (pre-existing)** — Info.plist SUFeedURL doesn't match Amore's actual appcast path. Installed users never receive updates or rollback signals. Must fix before ANY release. | Phase 4 CI4 | `Info.plist` | Small — already documented in AGENTS.md Known Issues |

### High Priority (P1 — Fix Before Release)

| # | Finding | Source | Files | Fix Effort |
|---|---------|--------|-------|------------|
| 7 | **Dual source of truth** — `currentMarkdown` in DocumentWindowController shadows `MarkdownDocument.markdownStorage`. Any missed update silently diverges. | Phase 1 H1 | `DocumentWindowController.swift` | Medium — make `currentMarkdown` a computed property |
| 8 | **Undo manager disconnect** — NSTextView has its own undo stack; NSDocument has another. Cmd+Z no-ops when non-editor pane has focus. Dirty indicator stays on after full undo. | Phase 1 H2, M-1 | `MarkdownDocument.swift`, `EditorViewController.swift` | Medium — either share undo manager or disable document-level undo |
| 9 | **Force-unwrap `textView.textStorage!`** — crash path in EditorViewController lines 68, 83. | Phase 1 H-1 | `EditorViewController.swift` | Small — guard-let |
| 10 | **O(M×K) intersection test** — 915,000 `NSIntersectionRange` calls per highlight pass on tutorial docs. 3–8ms. | Phase 2 P3 | `MarkdownSyntaxHighlighter.swift:190-192` | Small — binary search on sorted ranges |
| 11 | **Fence scanner allocation storm** — 8,000 heap allocations per highlight pass (4 allocs × 2,000 lines). | Phase 2 P4 | `MarkdownSyntaxHighlighter.swift:133-179` | Medium — stay in NSString, use range arithmetic |
| 12 | **Entitlement over-breadth** — `/` read-only + `user-selected.read-write`. Expanded blast radius if code is compromised. | Phase 2 S1 | `md-preview.entitlements` | Medium — scope `/` to `~/` (may affect project navigator) |
| 13 | **Symlink following in MarkdownAssetScheme** — `standardizedFileURL` doesn't resolve symlinks. Symlink escape + CORS wildcard enables JS exfiltration. | Phase 2 S2 | `MarkdownAssetSchemeHandler.swift` (unchanged file, pre-existing) | Small — add `resolvingSymlinksInPath()` check |
| 14 | **Zero test coverage for 482 lines of new code** — No test changes shipped with the feature. Critical paths (highlighting, debounce interlock, save round-trip, FileWatcher conflict) untested. | Phase 3 T1-T4 | `tests/` | Large — new Xcode test target needed |
| 15 | **Documentation completely unchanged** — CLAUDE.md, AGENTS.md, README.md all describe a viewer. CHANGELOG.md has no entry (release.sh will fail). | Phase 3 D1-D3 | `CLAUDE.md`, `AGENTS.md`, `README.md`, `CHANGELOG.md` | Medium |

### Medium Priority (P2 — Plan for Next Sprint)

| # | Finding | Source |
|---|---------|--------|
| 16 | `splitViewItems[1]` hardcoded without bounds-check in `viewDidAppear` | Phase 1 H-3 |
| 17 | `contentViewController` shadows `NSSplitViewController.contentViewController` | Phase 1 H4 |
| 18 | `updateEditor: Bool` flag parameter is control-flow smell | Phase 1 M2 |
| 19 | ⌘E shortcut advertised in tooltip but never wired | Phase 1 M-3 |
| 20 | `handleEditorTextChange` silently skips preview when `currentFileURL` is nil | Phase 1 M-4 |
| 21 | `intersectsProtected` O(n) scan — use NSIndexSet | Phase 1 M-5 |
| 22 | Two `applyPattern` overloads duplicate logic | Phase 1 M-6 |
| 23 | No duplicate-sheet guard on `showExternalChangeAlert` | Phase 2 S3 |
| 24 | Filename Unicode injection in alert text | Phase 2 S4 |
| 25 | No document-size guard before `applyHighlighting` (CPU DoS on large files) | Phase 2 S5 |
| 26 | Sidebar/inspector synchronous parse on every debounce tick (5–20ms) | Phase 2 P6 |
| 27 | `MarkdownSyntaxHighlighter` lacks `@MainActor` | Phase 4 BP8 |
| 28 | `isSettingText` may be dead code (verify empirically) | Phase 4 BP5 |
| 29 | `url.path` deprecated in macOS 13+ | Phase 4 BP11 |
| 30 | Missing doc comments on all new public/semi-public APIs | Phase 3 D4-D6 |

### Low Priority (P3 — Track in Backlog)

| # | Finding | Source |
|---|---------|--------|
| 31 | `becomeFirstResponder()` ignores `makeFirstResponder` result | Phase 1 L1 |
| 32 | `editorTextDidChange` is zero-value passthrough | Phase 1 L2 |
| 33 | Italic regex matches inside bold markers | Phase 1 L4 |
| 34 | `Access-Control-Allow-Origin: *` on md-asset:// responses | Phase 2 S7 |
| 35 | `image.isTemplate = true` mutates shared system symbol | Phase 1 L-5 |
| 36 | Homebrew cask bump sed-failure non-fatal but silently corrupts | Phase 4 CI8 |

---

## Findings by Category

| Category | Total | Critical | High | Medium | Low |
|----------|-------|----------|------|--------|-----|
| Code Quality | 16 | 2 | 3 | 6 | 5 |
| Architecture | 13 | 1 | 4 | 4 | 4 |
| Security | 7 | 0 | 1 | 5 | 1 |
| Performance | 11 | 2 | 5 | 3 | 1 |
| Testing | 9 | 4 | 3 | 2 | 0 |
| Documentation | 17 | 0 | 6 | 7 | 4 |
| Best Practices | 17 | 2 | 4 | 6 | 5 |
| CI/CD | 8 | 2 | 2 | 3 | 1 |
| **Deduplicated Total** | **36** | **6** | **9** | **15** | **6** |

*Note: Many findings are identified across multiple review dimensions. The deduplicated total counts each unique issue once at its highest severity.*

---

## Recommended Action Plan

### Before Merge (P0 — hours)

1. **Remove `setEditorText` on panel toggle** — delete the `if isVisible` block in `toggleEditorAction`. [Small, 5 lines]
2. **Add `isSaving` flag** — override `writeSafely(to:ofType:for:)` in MarkdownDocument, check in FileWatcher callback. [Small, 15 lines]
3. **Cache regex patterns** — promote 8 string-literal patterns to `private let` compiled properties. [Small, 20 lines]
4. **Add `xcodebuild build` CI step** — add to `swift-tests.yml`. [Small, 10 lines YAML]
5. **Fix SUFeedURL** — align Info.plist with Amore's actual appcast path. [Small, 1 line — already known]

### Before Release (P1 — days)

6. **Debounce or incrementalize highlighting** — either debounce the `applyHighlighting` call (separate from render debounce) or implement dirty-range incremental highlighting. [Medium, ~100 lines]
7. **Eliminate dual source of truth** — make `currentMarkdown` computed from `markdownDocument?.markdown`. [Medium, ~30 lines net]
8. **Resolve undo manager disconnect** — either share the document's undo manager with the text view, or set `hasUndoManager = false` and rely on `updateChangeCount`. [Medium, ~20 lines]
9. **Guard force-unwraps** — replace `textView.textStorage!` with guard-let. [Small, 4 lines]
10. **Add symlink containment check** in `MarkdownAssetScheme.resolve()`. [Small, 5 lines]
11. **Write tests** — create Xcode test target, add tests for highlighter, document save round-trip, FileWatcher conflict. [Large, ~300-500 lines]
12. **Update documentation** — CLAUDE.md, AGENTS.md, README.md, CHANGELOG.md. [Medium]

### Post-Release (P2/P3 — sprint)

13. Refactor `splitViewItems[1]` to type-safe accessor
14. Wire ⌘E keyboard shortcut
15. Add `@MainActor` annotations
16. Handle `currentFileURL == nil` in `handleEditorTextChange`
17. Add duplicate-sheet guard on external-change alert
18. Sanitize filename Unicode in alert text
19. Add document-size guard for highlighting
20. Optimize fence scanner allocations and intersection test

---

## Review Metadata

- **Review date:** 2026-06-28
- **Phases completed:** 1 (Code Quality & Architecture), 2 (Security & Performance), 3 (Testing & Documentation), 4 (Best Practices & Standards), 5 (Consolidated Report)
- **Flags applied:** Framework: AppKit/macOS
- **Review agents used:** 8 parallel agents across 4 phases
- **Detailed findings available in:**
  - `.full-review/phase1a-code-quality.md` (451 lines)
  - `.full-review/phase1b-architecture.md` (385 lines)
  - `.full-review/phase2a-security.md` (497 lines)
  - `.full-review/phase2b-performance.md` (702 lines)
  - `.full-review/phase3a-testing.md` (795 lines, includes compilable XCTest examples)
  - `.full-review/phase3b-documentation.md` (414 lines)
  - `.full-review/phase4a-best-practices.md` (836 lines)
  - `.full-review/phase4b-cicd.md` (425 lines)
