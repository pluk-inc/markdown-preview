# Phase 1: Code Quality & Architecture Review

## Code Quality Findings (16 findings: 2 Critical, 3 High, 6 Medium, 5 Low)

### Critical
- **C-1: Autosave triggers spurious "File Modified Externally" alert.** `autosavesInPlace=true` means NSDocument writes to disk, but FileWatcher fires before `isDocumentEdited` is cleared. The user's own autosave shows as "another application modified the file." Fix: add `isSaving` flag around save pipeline.
- **C-2: 7/9 regex patterns compiled fresh on every keystroke.** Only `fenceOpenRegex` is cached. `NSRegularExpression` compilation builds DFA each time. At 5 invocations/sec for sustained typing, this is significant CPU waste. Fix: cache as lazy vars.

### High
- **H-1: Force-unwrap `textView.textStorage!` in EditorViewController.** Lines 68 and 83. Crash path if textStorage is ever nil. Fix: guard-let.
- **H-2: Full-document `setAttributes` reset on every keystroke.** O(n) attribute reset over entire document before 7 regex passes. Visible lag on files >10K chars. Fix: incremental highlighting via `NSTextStorageDelegate`.
- **H-3: `splitViewItems[1]` without bounds-check in `viewDidAppear`.** All other editor accessors guard count, but this one doesn't. Fix: add guard.

### Medium
- **M-1: NSDocument undo manager disconnected from NSTextView undo.** Cmd+Z works in the editor but no-ops when another pane has focus. Dirty indicator stays on after full undo.
- **M-2: `toggleEditorAction` double-casts and redundantly calls `setEditorText`.** Resets scroll position and selection unnecessarily.
- **M-3: ⌘E shortcut advertised in tooltip but never wired.** No NSMenuItem or keyEquivalent registered.
- **M-4: `handleEditorTextChange` silently skips preview when `currentFileURL` is nil.** Editor accepts input but preview stays blank.
- **M-5: `intersectsProtected` is O(n) linear scan per regex match.** Use NSIndexSet for O(log n).
- **M-6: Two `applyPattern` overloads duplicate regex compile and enumerate logic.** Consolidate into one generic method.

### Low
- L-1: `becomeFirstResponder()` ignores `makeFirstResponder` return value
- L-2: `editorTextDidChange` is zero-value passthrough (should inline)
- L-3: `textView.textStorage!` force-unwrap inconsistent with project style
- L-4: Italic regex `*[^*]+*` matches inside bold `**text**` and overrides coloring
- L-5: `image.isTemplate = true` mutates shared system symbol image

## Architecture Findings (13 findings: 1 Critical, 4 High, 4 Medium, 4 Low)

### Critical
- **C1: `toggleEditorAction` unconditionally overwrites editor text on every panel open.** `currentMarkdown` lags behind the editor by up to 200ms debounce. Reopening the editor after closing it within the debounce window silently discards in-progress edits. Fix: remove the `setEditorText` call — file-load paths already populate the editor.

### High
- **H1: Dual source of truth — `currentMarkdown` in DWC shadows `MarkdownDocument.markdownStorage`.** Any code path that updates one but not the other silently diverges. Fix: make `currentMarkdown` a computed property reading from `markdownDocument?.markdown`.
- **H2: NSTextView undo manager disconnected from NSDocument undo manager.** Cmd+Z behavior is split by focus. Autosave checkpoints are driven only by `updateChangeCount`. Fix: share the document's undo manager or disable document-level undo.
- **H3: NSRegularExpression compiled on every keystroke** (duplicate of code quality C-2). Fix: cache as lazy vars.
- **H4: `contentViewController` shadows `NSSplitViewController.contentViewController`.** Name collision with superclass property. Fix: rename to `previewViewController`.

### Medium
- **M1: Hardcoded `splitViewItems[1]` for editor operations.** Fragile if pane order changes. Fix: store editor split item as a property.
- **M2: `updateEditor: Bool` flag parameter is a control-flow smell.** Hidden invariant that the editor-triggered path must pass `false`. Fix: split into `displayPreviewOnly()`.
- **M3: FileWatcher spurious alert after app's own autosave** (related to code quality C-1). Race between save and debounce. Fix: `isSaving` flag.
- **M4: ⌘E shortcut not registered** (duplicate of code quality M-3).

### Low
- L1: `becomeFirstResponder` always returns true
- L2: `editorTextDidChange` is zero-value passthrough
- L3: Force-unwrap `textStorage!` inconsistent with project style
- L4: Italic regex matches inside bold markers

## Critical Issues for Phase 2 Context

1. **Autosave + FileWatcher race** (C-1/M3) — affects file integrity and data flow
2. **Editor text overwrite on panel toggle** (C1) — potential data loss
3. **Per-keystroke regex compilation + full-document attribute reset** (C-2/H-2) — performance regression
4. **Dual source of truth** (H1) — maintainability risk, potential stale data on save
5. **Undo manager disconnect** (M-1/H2) — user-facing functional bug
