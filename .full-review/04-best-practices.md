# Phase 4: Best Practices & Standards

## Framework & Language Findings (17 findings: 2 Critical, 4 High, 6 Medium, 5 Low)

### Critical
- **BP1: Per-keystroke regex recompilation (confirmed from best-practices angle).** Both `applyPattern` overloads accept a `String` pattern and compile fresh each call. Standard practice: compile once as `private let` or `lazy var`. Matches Phase 1 C-2 and Phase 2 P1.
- **BP2: Full-document synchronous highlighting on every `textDidChange`.** No debounce on the highlighting path — only the WKWebView render is debounced. AppKit best practice: `NSTextStorageDelegate.textStorage(_:willProcessEditing:range:changeInLength:)` for incremental, or debounce highlighting separately.

### High
- **BP3: `@concurrent` task closure attribute should be `Task.detached` or `nonisolated`.** `@concurrent` on a `Task {}` closure is a non-standard pattern. In Swift 6, `Task {}` inherits the caller's actor context. The `MarkdownWebView.display()` renders on a concurrent task correctly via `Task { @concurrent ... }` but this is a newer annotation — verify it matches the project's Swift tools version.
- **BP4: Dual source of truth (`currentMarkdown` vs `markdownStorage`).** AppKit best practice for NSDocument: the document model is the single source of truth. The window controller's `currentMarkdown` shadow copy creates divergence risk. Fix: make it a computed property.
- **BP5: `isSettingText` guard may be dead code.** `NSTextView.string = newValue` does NOT trigger `textDidChange` via the delegate — AppKit only fires `textDidChange` for user-initiated edits. The `isSettingText` flag is technically unnecessary but harmless as a defensive guard. Verify empirically.
- **BP6: O(M×K) intersection test.** Standard approach: sorted ranges + binary search, or NSIndexSet. Confirmed from prior phases.

### Medium
- **BP7: Hardcoded `splitViewItems[1]`/`[2]` indices.** AppKit best practice: store the `NSSplitViewItem` reference or use type-based discovery. Fragile if pane order changes.
- **BP8: MarkdownSyntaxHighlighter lacks `@MainActor`.** It mutates `NSTextStorage` which is main-thread-only. The class should be annotated `@MainActor` for Swift 6 strict concurrency.
- **BP9: `becomeFirstResponder()` override is wrong approach.** `NSViewController.becomeFirstResponder()` is rarely called. Use `viewDidAppear` + `makeFirstResponder` instead for initial focus, or override `acceptsFirstResponder` on the NSTextView subclass.
- **BP10: Direct `self.fileURL` mutation in `replaceFileURL`.** NSDocument manages `fileURL` internally; setting it directly bypasses `NSFileCoordinator`. Safe in practice because `replaceFileURL` is only called from code paths that already own the file, but not idiomatic.
- **BP11: `url.path` is deprecated in macOS 13+.** Use `url.path(percentEncoded: false)` for the non-deprecated path. Affects existing code, not just new code.
- **BP12: Two `applyPattern` overloads duplicate logic.** Consolidate into one generic method with a closure returning `(NSRange, [Key: Any])`.

### Low
- BP13-BP17: Missing `@MainActor` annotations on EditorViewController and MarkdownSyntaxHighlighter, `image.isTemplate` mutation of shared system symbol, minor naming conventions.

## CI/CD & DevOps Findings (8 findings: 2 Critical, 2 High, 3 Medium, 1 Low)

### Critical
- **CI1: No build or test coverage for 482 lines of new editing code.** `swift-tests.yml` only compiles 3 symlinked helpers via SPM. The Xcode project is never built in CI. Compiler errors in new files are invisible. Fix: add `xcodebuild build CODE_SIGNING_REQUIRED=NO` step.
- **CI2: Three prior-phase critical bugs are unblocked for release.** Data-loss defect (editor text overwrite), autosave/FileWatcher race, per-keystroke regex compilation — `release.sh` has no known-issue gate, only changelog validation.

### High
- **CI3: Entitlement escalation requires explicit checklist.** `user-selected.read-write` is standard for Developer ID but: (a) users updating via Sparkle may see an OS permission prompt not mentioned in release notes; (b) amore's cached notarization config may be stale.
- **CI4: Pre-existing SUFeedURL mismatch blocks Sparkle rollback.** `Info.plist` SUFeedURL points to `/appcast.xml` but Amore publishes to `/v1/apps/.../appcast.xml`. Installed users polling the wrong URL never receive rollback signals. **This is a ship-blocker for any release with the editing feature.**

### Medium
- CI5: Rollback is server-side unpublish only — does not auto-downgrade installed users. GitHub release DMG deleted by default rollback, removing manual recovery path. Use `--keep-github`.
- CI6: No Xcode build step in CI workflow — compiler errors in AppKit code invisible.
- CI7: No integration tests for editing behavior (typing, save, toggle, external-change alert).

### Low
- CI8: Homebrew cask bump sed-failure in `release.sh` is non-fatal but silently corrupts the cask.

### Ship Blockers Identified
1. **SUFeedURL mismatch** (pre-existing, in AGENTS.md Known Issues) — must fix before any release
2. **Data-loss on editor toggle** (Phase 1 C1) — must remove the `setEditorText` call in `toggleEditorAction`
3. **Autosave/FileWatcher false-alert race** (Phase 1 C-1) — must add `isSaving` guard
4. **No xcodebuild in CI** — compiler errors in new files invisible
