# Phase 3b — Documentation Review
**Branch**: `feat/add-editing-support` (diff base: `7fc5aa2`)  
**Reviewer**: Documentation  
**Date**: 2026-06-28

---

## Summary

The editing feature ships with zero documentation updates. Every external-facing artifact — `CLAUDE.md`, `AGENTS.md`, `README.md`, `CHANGELOG.md` — still describes a read-only viewer. Inline documentation is sparse across all four new/changed source files: public and semi-public APIs lack doc comments, threading contracts are unspecified, and the tricky `updateEditor` parameter that prevents data loss during debounce is invisible to callers. Six critical or high-severity gaps are likely to cause correctness or maintenance problems on first contribution.

---

## Findings

### 1. CLAUDE.md / AGENTS.md — App description no longer accurate
**Severity: High**

Both files open with the same sentence:
> "A macOS app for **previewing** Markdown files."

The `Info.plist` role field changed from `Viewer` to `Editor` in this branch. The entitlements changed from `user-selected.read-only` to `user-selected.read-write`. The app can now write to disk via NSDocument autosave. A contributor following CLAUDE.md's "project facts" table will have a wrong mental model from the first paragraph.

**Recommendation**: Update the opening description in both files to:
> "A macOS app for **reading and editing** Markdown files."

Additionally, add a row to the Project facts table:
```
| Editing | Inline source editor (NSTextView) with syntax highlighting; autosaves via NSDocument |
```

AGENTS.md also lacks the "Known Issues" section present in CLAUDE.md. The autosave + FileWatcher race (Finding 10 below) should be documented there.

---

### 2. README.md — App identity mismatch
**Severity: High**

Three separate locations describe a read-only tool:

1. **Subtitle** (line 8): `"A fast, native macOS app for reading Markdown files."`
2. **Tagline** (line 16): `"Drop a .md on the icon... and get a clean, scrollable preview"` — no mention of editing.
3. **Features list** (lines 49–62): 14 bullets; zero mention of the editor pane, syntax highlighting, or the toolbar Edit toggle.

A user reading the README has no way to know the app can edit files.

**Recommendation**:
- Change subtitle to: `"A fast, native macOS app for reading and editing Markdown files."`
- Add an **Editing** bullet to the features list, e.g.:
  > **Inline source editor** — Toggle an NSTextView editor pane from the toolbar (`pencil.line` button or ⌘E). Syntax highlighting covers headings, bold/italic, code spans, code fences, links, blockquotes, and list markers, with live preview updates debounced at 200 ms.
- Update the tagline to acknowledge editing.
- Add new files to the Project layout section (`EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift`).

---

### 3. CHANGELOG.md — No entry for the editing feature
**Severity: High**

The changelog's most recent entry is `[0.0.28]` (2026-06-12), which predates this branch. There is no `[Unreleased]` section or any mention of editing, autosave enablement, the new toolbar item, FileWatcher conflict detection, or the two new source files.

This is a feature branch, so a release entry is not expected yet. However, the CLAUDE.md workflow requires that a changelog entry exists **before `release.sh` runs**, and the script validates this. An agent following that workflow on this branch would fail the validation step with no guidance.

**Recommendation**: Add an `[Unreleased]` section at the top of `CHANGELOG.md` now, documenting the editing feature at the bullet level, so the release process can proceed without a scramble. Invoke the `changelog-maintenance` skill per CLAUDE.md instructions. Minimum content:

```md
## [Unreleased]

Markdown Preview now includes an inline source editor with syntax highlighting and live preview.

### Added

- **Inline Markdown editor.** A toggleable editor pane (toolbar Edit button, ⌘E) displays a syntax-highlighted NSTextView alongside the preview. Edits are debounced 200 ms before updating the preview.
- **Markdown syntax highlighting.** Headings, bold, italic, inline code, fenced code blocks, links, blockquotes, and list markers are colored in real time as you type.
- **Autosave.** NSDocument autosave is now enabled; the app writes changes back to disk automatically.
- **External-edit detection.** If the file is modified by another application while unsaved edits exist in the editor, the app prompts to keep local changes or reload from disk.

### Changed

- **Sandbox entitlement upgraded from read-only to read-write** to permit saving edited files.
- **NSDocument role changed from Viewer to Editor** in Info.plist.
```

---

### 4. `EditorViewController.setMarkdown(_:)` — No doc comment; threading contract missing
**Severity: High**

```swift
func setMarkdown(_ text: String) {
    isSettingText = true
    textView.string = text
    isSettingText = false
    highlighter.applyHighlighting(to: textView.textStorage!)
}
```

This is the primary API for loading content into the editor. It has no doc comment. Callers cannot infer from the signature:
- It must be called on the **main thread** (`textView.string` is an AppKit main-thread-only operation).
- It **suppresses `onTextChange`** (the `isSettingText` guard); a caller passing text from a background completion handler expecting the callback to fire will be silently ignored.
- It does **not** register the text change with the undo manager (undo is disconnected from programmatic sets).
- It **forces a full syntax highlighting pass** immediately (synchronous, potentially expensive on large files — prior performance analysis clocked this at 25–66 ms for a 10 k-line document).

**Recommendation**:
```swift
/// Loads `text` into the editor programmatically.
///
/// - The `onTextChange` callback is **not** fired; this is intended for
///   initial file loads and external-reload paths.
/// - Does not create an undo action; the undo manager stays clean.
/// - Triggers a full synchronous syntax-highlighting pass — avoid calling
///   on every keystroke; use `textDidChange` for that path.
///
/// - Important: Must be called on the main thread.
func setMarkdown(_ text: String) {
```

---

### 5. `MarkdownSyntaxHighlighter.applyHighlighting(to:)` — No doc comment; threading and performance undocumented
**Severity: High**

```swift
func applyHighlighting(to textStorage: NSTextStorage) {
```

This is the only public method on `MarkdownSyntaxHighlighter`. It:
- Must run on the **main thread** (`NSTextStorage.beginEditing`/`endEditing` are not thread-safe).
- Performs a **full-document rewrite** on every call — it resets all attributes to base style then applies 8+ pattern passes. Prior performance analysis identified this as taking 25–66 ms per keystroke on a 10 k-line document, well over a 16 ms frame budget.
- Compiles 8 inline regex patterns on every invocation (the `fenceOpenRegex` is lazy and cached, but the 8 patterns inside `applyPattern` calls are not).

There is no class-level doc comment on `MarkdownSyntaxHighlighter` either.

**Recommendation**:
```swift
/// Applies Markdown syntax highlighting to a text storage.
///
/// The highlighter rewrites the full document on every call — color and font
/// attributes are reset to the base style, then heading, bold/italic, code,
/// link, blockquote, and list-marker patterns are applied in sequence.
///
/// - Warning: Regex patterns are compiled on every call. On large documents
///   (>5 k lines) this can exceed one frame budget. Callers should debounce
///   or restrict the call to changed ranges when possible.
/// - Important: Must be called on the main thread.
func applyHighlighting(to textStorage: NSTextStorage) {
```

---

### 6. `MarkdownDocument.setMarkdown(_:)` — No doc comment; dirty-flag contract invisible
**Severity: High**

```swift
func setMarkdown(_ newText: String) {
    markdownStorage.withLock { $0 = newText }
    updateChangeCount(.changeDone)
}
```

This method marks the document dirty (`.changeDone`) and is the bridge between the editor and NSDocument's autosave machinery. Its contract is completely undocumented:
- Callers must not call this on background threads (`updateChangeCount` requires main thread).
- It differs from `replaceContents(markdown:fileURL:)` which calls `.changeCleared` — the distinction between "user edit" and "external reload" is invisible.

**Recommendation**:
```swift
/// Records a user-originated edit to the document's in-memory content.
///
/// Marks the document as edited (`.changeDone`) so NSDocument's autosave
/// machinery will write the change to disk. Call this only from the main
/// thread and only for edits that should be undoable / saved.
///
/// - Parameter newText: The full document text after the edit.
/// - SeeAlso: `replaceContents(markdown:fileURL:)` for external-reload paths
///   that clear the dirty flag instead.
func setMarkdown(_ newText: String) {
```

---

### 7. `MainSplitViewController.display(markdown:fileName:url:assetBaseURL:updateEditor:)` — `updateEditor` parameter undocumented
**Severity: Medium**

```swift
func display(markdown: String, fileName: String, url: URL?, assetBaseURL: URL?,
             updateEditor: Bool = true) {
```

The `updateEditor` parameter defaults to `true` but is passed as `false` in `handleEditorTextChange` — the only path where passing `true` would cause data loss (overwriting the user's live in-progress text with the already-debounced snapshot). A caller who misunderstands this flag will silently lose keystrokes in the debounce window.

This is the mechanism that prevents Finding 4 in the prior critical findings ("Editor text overwritten on panel toggle").

**Recommendation**: Document the parameter explicitly:
```swift
/// - Parameter updateEditor: Pass `false` when the display call originates
///   *from* the editor's own text-change callback. Passing `true` in that
///   case would overwrite the editor's live text with the debounced snapshot,
///   discarding keystrokes typed during the debounce window.
```

---

### 8. `MainSplitViewController.toggleEditor()` — Return value contract not documented
**Severity: Medium**

```swift
@discardableResult
func toggleEditor() -> Bool {
```

The `@discardableResult` annotation acknowledges that callers may ignore the return value, but what the `Bool` means is not stated. It returns `true` when the editor becomes *visible* (i.e., was previously collapsed) and `false` when it becomes hidden. This is the inverse of what a caller might intuit from the function name.

`toggleInspector()` and `toggleSidebar()` have the same pattern with the same undocumented semantics.

**Recommendation**: Add a consistent doc comment to all three toggle methods:
```swift
/// Toggles the editor pane's collapsed state.
/// - Returns: `true` if the editor is now **visible**; `false` if it is now collapsed.
@discardableResult
func toggleEditor() -> Bool {
```

---

### 9. `EditorViewController` — No class-level doc comment
**Severity: Medium**

`EditorViewController` has no class-level documentation. Key architectural decisions are invisible:
- It is initialized and retained by `MainSplitViewController` (not from a XIB/storyboard).
- Communication is exclusively through the `onTextChange` closure; there is no delegate protocol.
- The 200 ms debounce is a hardcoded constant (`debounceDelay`), not configurable.
- `loadView()` builds the entire view hierarchy programmatically.

**Recommendation**:
```swift
/// A split-pane editor for the raw Markdown source.
///
/// Wraps a monospaced `NSTextView` with live syntax highlighting.
/// Communication is through the `onTextChange` closure, which fires on the
/// main thread with the full document text after a 200 ms debounce.
///
/// This view controller is managed entirely by `MainSplitViewController`;
/// do not instantiate it independently.
final class EditorViewController: NSViewController, NSTextViewDelegate {
```

---

### 10. FileWatcher + autosave race — No inline comment explaining the `isDocumentEdited` guard
**Severity: Medium**

```swift
let watcher = FileWatcher(url: url) { [weak self] in
    guard let self, self.currentFileURL == url else { return }
    if self.markdownDocument?.isDocumentEdited == true {
        self.showExternalChangeAlert(fileURL: url)
    } else {
        self.loadFile(at: url, silentOnFailure: true)
    }
}
```

The prior security/performance review (phase2) identified the autosave + FileWatcher race: NSDocument's autosave writes the file, which triggers the FileWatcher, which then sees `isDocumentEdited == false` (autosave cleared it) and silently reloads, potentially overwriting in-progress edits that arrived after the autosave snapshot but before the reload. There is no comment here explaining the intent, the known limitation, or why a time-window approach (e.g., suppressing FileWatcher events for N seconds after an autosave) was not chosen.

**Recommendation**: Add an inline comment:
```swift
// If the document has unsaved changes, prompt rather than silently reload.
// Known limitation: if autosave fires first it clears isDocumentEdited,
// so a subsequent external change within the autosave debounce window will
// reload silently even if the user typed in the gap. Tracked as a known
// issue. A robust fix requires a version-stamp or suppression window.
```

---

### 11. `MarkdownDocument.replaceContents(markdown:fileURL:)` and `replaceFileURL(_:)` — Undocumented
**Severity: Medium**

```swift
func replaceContents(markdown: String, fileURL: URL) { … }
func replaceFileURL(_ fileURL: URL) { … }
```

Both methods are called from `DocumentWindowController` in response to file-navigation events. Neither has a doc comment. `replaceContents` calls `.changeCleared` (unlike `setMarkdown` which calls `.changeDone`) and is the correct path for external-reload scenarios. The distinction is undocumented, making it easy to call the wrong method.

**Recommendation**: Add minimal doc comments:
```swift
/// Replaces in-memory content and file URL after an external reload.
/// Calls `.changeCleared`; the document is marked clean.
func replaceContents(markdown: String, fileURL: URL) {

/// Updates the document's file URL without changing content or dirty state.
/// Used after a Finder rename while the content stays valid.
func replaceFileURL(_ fileURL: URL) {
```

---

### 12. Dual source of truth (`currentMarkdown` vs `markdownStorage`) — No comment
**Severity: Medium**

`DocumentWindowController` has `private var currentMarkdown: String?` and `MarkdownDocument` has `private nonisolated let markdownStorage = Mutex("")`. Both hold the current Markdown text. No comment explains the ownership boundary:
- `currentMarkdown` is the window controller's working copy (used for preview rendering, sharing, rename events).
- `markdownStorage` is the document model's copy (used for `data(ofType:)` serialization).
- They can diverge in the debounce window between a keystroke and the `handleEditorTextChange` write.

**Recommendation**: Add a comment on the property declaration:
```swift
// Working copy of the current Markdown text, kept in sync with
// markdownDocument.markdownStorage via handleEditorTextChange. May lag
// the editor's live text by up to the debounce delay (200 ms). Nil before
// the first file is loaded.
private var currentMarkdown: String?
```

---

### 13. No tests for new editing-layer components
**Severity: Medium**

The `tests/swift-tests` package covers `QuickLookHelpers` and `MarkdownHelpers` (the parser layer). No test target covers:
- `MarkdownSyntaxHighlighter` — the regex patterns, fence scanner, and protected-range exclusion logic can be tested without AppKit (by constructing an `NSTextStorage` directly).
- `EditorViewController` — the `isSettingText` guard, debounce cancel/fire logic, and the `onTextChange` closure contract.
- `MarkdownDocument.setMarkdown` / `replaceContents` dirty-flag transitions.

The Contributing section of README.md still says "there's no UI test suite yet" — now especially relevant because the editing path has no automated coverage at any layer.

**Recommendation**: Add a `MarkdownSyntaxHighlighterTests` target to `tests/swift-tests` covering at least: empty input guard, fence open/close pairing, nested fence protection (inline code inside a fence should stay `codeColor`), and the `intersectsProtected` helper. Document this gap in the AGENTS.md Known Issues section so future agents know to add tests with new highlighting rules.

---

### 14. `EditorViewController.insertMarkdownSnippet(_:)` — Undocumented
**Severity: Low**

```swift
func insertMarkdownSnippet(_ snippet: String) {
    textView.insertText(snippet, replacementRange: textView.selectedRange())
}
```

No doc comment. Callers cannot infer whether this fires `onTextChange` (it does, via `textDidChange`), registers with the undo manager (it does, via `NSTextView`'s native undo), or requires main-thread dispatch (it does).

**Recommendation**: Add a one-line doc comment:
```swift
/// Inserts `snippet` at the current selection, firing `onTextChange` and registering an undo action.
/// Must be called on the main thread.
func insertMarkdownSnippet(_ snippet: String) {
```

---

### 15. `EditorViewController.currentText` — Undocumented
**Severity: Low**

```swift
var currentText: String {
    textView?.string ?? ""
}
```

No doc comment. Returns empty string before the view is loaded (when `textView` is nil). Callers building on this computed property for save validation could be surprised.

**Recommendation**:
```swift
/// The editor's current raw text. Returns an empty string if the view has not yet loaded.
var currentText: String {
```

---

### 16. README.md — Project layout outdated
**Severity: Low**

The Project layout section lists:
```
md-preview/         Main app target (AppKit, WKWebView)
```

Two significant new files (`EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift`) are not mentioned. No note that the app now also uses `NSTextView` alongside `WKWebView`.

**Recommendation**: Update the project layout prose to reflect the dual-view architecture (WKWebView for preview, NSTextView for editing).

---

### 17. Info.plist and entitlements changes not documented anywhere
**Severity: Low**

The `NSDocument` role was changed from `Viewer` to `Editor` in `Info.plist`, and the sandbox entitlement was upgraded from `user-selected.read-only` to `user-selected.read-write`. These are security-significant changes (the app can now write to any file the user opened). Neither change is mentioned in any documentation artifact.

**Recommendation**: Add a note to CLAUDE.md's Project facts table and to the changelog's Changed section (see Finding 3).

---

## Summary Table

| # | File / Location | Severity | Issue |
|---|---|---|---|
| 1 | CLAUDE.md / AGENTS.md | High | App described as "previewing" only; no editing facts |
| 2 | README.md | High | "reading Markdown files" tagline; no editing feature in feature list |
| 3 | CHANGELOG.md | High | No entry for editing feature; release.sh will fail validation |
| 4 | `EditorViewController.setMarkdown(_:)` | High | No doc; threading, onTextChange suppression, highlighting cost undocumented |
| 5 | `MarkdownSyntaxHighlighter.applyHighlighting(to:)` | High | No doc; threading, full-document rewrite, regex compilation cost undocumented |
| 6 | `MarkdownDocument.setMarkdown(_:)` | High | No doc; dirty-flag contract and threading requirement undocumented |
| 7 | `MainSplitViewController.display(…updateEditor:)` | Medium | `updateEditor` parameter semantics undocumented; wrong value causes data loss |
| 8 | `MainSplitViewController.toggleEditor()` | Medium | Return value (true = now visible) not documented |
| 9 | `EditorViewController` class | Medium | No class-level doc comment |
| 10 | `DocumentWindowController.startWatching` | Medium | FileWatcher+autosave race not explained inline |
| 11 | `MarkdownDocument.replaceContents/replaceFileURL` | Medium | Undocumented; `.changeCleared` vs `.changeDone` distinction invisible |
| 12 | `currentMarkdown` vs `markdownStorage` | Medium | Dual source of truth ownership not explained |
| 13 | `tests/swift-tests` | Medium | No tests for MarkdownSyntaxHighlighter, EditorViewController, or MarkdownDocument |
| 14 | `EditorViewController.insertMarkdownSnippet(_:)` | Low | No doc comment |
| 15 | `EditorViewController.currentText` | Low | No doc comment; nil-before-load behavior invisible |
| 16 | README.md project layout | Low | New files missing from layout section |
| 17 | Info.plist / entitlements | Low | Role and sandbox changes not documented |
