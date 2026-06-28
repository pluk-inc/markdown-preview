# Phase 3: Testing & Documentation Review

## Test Coverage Findings (9 findings: 4 Critical, 3 High, 2 Medium)

### Critical
- **T1: MarkdownSyntaxHighlighter entirely untested.** 228 lines of regex-based highlighting logic that fires on every keystroke — no correctness or performance tests. Fence scanner stuck-state, off-by-one NSRange, regex-inside-protected-range bugs are all invisible.
- **T2: EditorViewController debounce/isSettingText interlock untested.** The anti-render-loop contract (isSettingText guard) and the data-loss window (200ms debounce) have no test coverage. CI cannot detect if the interlock breaks.
- **T3: MarkdownDocument writable data path untested.** `data(ofType:)` changed from throwing `fileWriteNoPermission` to encoding UTF-8. No round-trip test (read → edit → save → re-read) or error-path test (non-UTF-8 content).
- **T4: FileWatcher/autosave race condition untested.** The `startWatching` branch on `isDocumentEdited` and both alert response paths (keep changes / reload) are completely untested.

### High
- **T5: No performance benchmark gate.** The 25–66ms per-keystroke highlighting cost has no baseline. Future regressions are undetectable.
- **T6: Panel-toggle/debounce data-loss scenario untested.** Toggling editor closed within the 200ms debounce window, then reopening — Phase 1 identified this as a data-loss path.
- **T7: Index-based pane contract in MainSplitViewController fragile with no structural tests.** `splitViewItems[1]` and `splitViewItems[2]` are assumed but never verified.

### Medium
- **T8: No Xcode unit-test target exists.** The SPM test harness is Foundation-only. AppKit-dependent tests need a new Xcode test target.
- **T9: Existing tests are good style (behavior-oriented, mock-free) — should be replicated for new code.**

### Infrastructure Note
Existing test style is correct: feed raw input, assert observable output, no mocks. A new Xcode unit-test target (`md-preview-tests`) with `@testable import` is the prerequisite for testing the new editing layer.

## Documentation Findings (17 findings: 0 Critical, 6 High, 7 Medium, 4 Low)

### High
- **D1: CLAUDE.md and AGENTS.md describe a read-only viewer.** Opening sentence says "previewing Markdown files" — now incorrect. Project facts table lacks editing row.
- **D2: README.md omits editing entirely.** Subtitle, tagline, and all 14 feature bullets describe a viewer. No mention of editor pane, syntax highlighting, or toolbar toggle.
- **D3: CHANGELOG.md has no entry for the editing feature.** `release.sh` validates changelog presence — it will fail at release time.
- **D4: EditorViewController.setMarkdown lacks doc comment.** Threading contract (must be main thread), onTextChange suppression behavior, and highlighting cost are invisible.
- **D5: MarkdownSyntaxHighlighter.applyHighlighting lacks doc comment.** Threading, full-document cost, and per-keystroke invocation pattern undocumented.
- **D6: MarkdownDocument.setMarkdown lacks doc comment.** Dirty-flag side effect and threading (nonisolated Mutex) contract invisible.

### Medium
- D7: `updateEditor` parameter on `display()` is data-loss-adjacent but undocumented
- D8: `toggleEditor()` return value semantics undocumented
- D9: No class-level doc comments on EditorViewController or MarkdownSyntaxHighlighter
- D10: FileWatcher + autosave race guard not documented in known issues
- D11: `replaceContents` vs `setMarkdown` vs `.changeCleared` distinction undocumented
- D12: Dual source of truth ownership not documented
- D13: No test coverage documented for new editing layer

### Low
- D14-D17: Info.plist/entitlements changes undocumented, missing file headers, minor formatting
