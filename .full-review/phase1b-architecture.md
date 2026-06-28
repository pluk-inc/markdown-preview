# Phase 1b — Architecture Review
**Branch:** `feat/add-editing-support`  
**Base:** `7fc5aa2` (Release 0.0.28, viewer-only)  
**Scope:** Component boundaries, data flow, API design, data model, design patterns, architectural consistency

---

## Summary

The editing feature is structurally sound and follows the project's existing patterns closely. The unidirectional data flow (editor → document → preview) is correctly designed, the callback chain avoids circular dependencies, and the NSDocument lifecycle integration is competent. The major risks are in the *state management seams* between the view controller and document layers, and in performance regressions that appear on every keystroke.

---

## Critical

### C1 — `toggleEditorAction` unconditionally overwrites editor text on every open

**File:** `DocumentWindowController.swift:1148–1155`

```swift
@objc private func toggleEditorAction(_ sender: Any?) {
    let isVisible = ...toggleEditor() ?? false
    setEditToggleSelected(isVisible)
    if isVisible, let markdown = currentMarkdown {
        ...setEditorText(markdown)         // ← fires every time editor becomes visible
    }
}
```

Every time the editor panel is opened, the NSTextView content is blown away and replaced with `currentMarkdown`. This is architecturally wrong for two reasons:

1. **Stale-text overwrite.** `currentMarkdown` is updated only after the 200 ms debounce in `EditorViewController.textDidChange`. If the user typed, then toggled the editor closed (within that debounce window), `currentMarkdown` holds the pre-edit text. Reopening the editor then silently discards whatever the NSTextView held.

2. **The call is already redundant.** `renderCurrentDocument` calls `display(markdown:..., updateEditor: true)` on every file load, which invokes `editorViewController?.setMarkdown(text)` whether or not the editor panel is currently visible. The NSTextView is populated correctly before the user ever opens the panel. The extra `setEditorText` in `toggleEditorAction` adds no value for the common case and introduces the destructive race for the typing case.

**Impact:** Data loss of in-progress edits on panel re-open; corrupts the "editor is the source of truth while open" invariant.

**Recommendation:** Remove the `if isVisible { setEditorText(...) }` block entirely. Trust that file-load paths already populate the editor. If a bootstrap guard is truly needed (e.g., for future lazy-VC init), gate on whether the editor text is currently empty:

```swift
if isVisible, editorVC.currentText.isEmpty, let markdown = currentMarkdown {
    editorVC.setEditorText(markdown)
}
```

---

## High

### H1 — Dual source of truth for markdown content

**Files:** `DocumentWindowController.swift` (`currentMarkdown`), `MarkdownDocument.swift` (`markdownStorage`)

The document text lives in two independently maintained stores:
- `MarkdownDocument.markdownStorage` (the canonical NSDocument model, `Mutex<String>`)
- `DocumentWindowController.currentMarkdown` (an `Optional<String>` shadow copy)

Both are updated together in `handleEditorTextChange` and `applyLoadedMarkdown`, but this coupling is implicit and brittle. Any call path that updates one but misses the other silently creates a divergence. For example, `handleRename(to:)` calls `loadFile` only as a fallback — if `currentMarkdown` is non-nil, the markdown model is NOT re-read from disk, so a rename that also changes file content (e.g., an external editor's save-as) would leave `currentMarkdown` stale while `markdownStorage` holds whatever was last written.

**Impact:** Medium-term maintenance hazard; any new code path that touches file content must update both stores or risk stale previews or wrong autosave content.

**Recommendation:** Make `DocumentWindowController.currentMarkdown` a computed property that reads from `markdownDocument?.markdown`:

```swift
private var currentMarkdown: String? {
    markdownDocument?.markdown
}
```

Remove the stored `currentMarkdown` property and all manual assignments to it. The single source of truth is then `MarkdownDocument.markdownStorage`. The only consumer that currently needs a local copy outside the document (e.g., the sharing service picker, `items(for:)`) can read from `markdownDocument?.markdown` directly.

---

### H2 — NSTextView undo manager disconnected from NSDocument undo manager

**Files:** `MarkdownDocument.swift:24`, `EditorViewController.swift:38`

`MarkdownDocument.init()` enables the document's undo manager (`hasUndoManager = true`), which activates AppKit's autosave-with-undo machinery. But `EditorViewController.textView` creates and manages its *own* internal undo stack (`allowsUndo = true`). No bridge is established between the two.

Consequences:

- **Cmd+Z behavior is split by focus.** When the NSTextView is first responder, its undo manager intercepts Cmd+Z and correctly undoes text changes. When anything else is focused (the preview, toolbar, inspector), the menu routes Cmd+Z to the document's undo manager, which has no registered operations and silently no-ops.
- **Autosave checkpoint drift.** AppKit uses the document's undo manager to determine autosave checkpoints. Since no operations are ever registered on it, autosave checkpoints are driven solely by `updateChangeCount` calls — which is functional, but means document-level undo/redo is permanently broken for users who expect it to work.

**Impact:** User-visible bug: Cmd+Z sometimes does nothing depending on which pane has focus.

**Recommendation:** Either (a) share the document's undo manager with the text view so they form one stack:

```swift
// in EditorViewController.loadView(), after the document is available
textView.undoManager = /* passed-in document undo manager */
```

Or (b) keep undo scoped to the text view by reverting to `hasUndoManager = false` on the document and relying solely on `updateChangeCount` for dirty tracking. Option (b) is simpler and sufficient for the current feature scope; option (a) requires threading the undo manager into `EditorViewController`.

---

### H3 — NSRegularExpression compiled on every keystroke

**File:** `MarkdownSyntaxHighlighter.swift:194–227`

Eight of the nine regex patterns in `applyHighlighting` are compiled fresh on every invocation of `applyPattern`:

```swift
private func applyPattern(_ pattern: String, ...) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    // ...
}
```

`applyHighlighting` is called on every text change (after a 200 ms debounce), so at sustained typing speed this fires 5 times/second. `NSRegularExpression` compilation is non-trivial — it parses the pattern, builds an NFA, and compiles it. Only `fenceOpenRegex` uses the correct `lazy var` caching pattern.

For a large file, this also means the full re-highlight pass (O(n) for each of 8 patterns over the document text) runs after every debounce. This will cause visible lag on documents >~10 000 characters.

**Impact:** UI performance regression proportional to file size; unnecessary CPU burn on every keystroke.

**Recommendation:** Promote all eight regex patterns to `private lazy var` properties on `MarkdownSyntaxHighlighter`, matching the existing `fenceOpenRegex` pattern:

```swift
private lazy var headingRegex: NSRegularExpression? =
    try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$")
// ... etc.
```

Then pass the pre-compiled regex directly rather than the pattern string to avoid any re-compilation.

---

### H4 — `private var contentViewController` shadows `NSSplitViewController.contentViewController`

**File:** `MainSplitViewController.swift:199–202`

```swift
private var contentViewController: ContentViewController? {
    guard splitViewItems.count > 2 else { return nil }
    return splitViewItems[2].viewController as? ContentViewController
}
```

`NSSplitViewController` inherits `contentViewController: NSViewController?` from `NSViewController`. The new private computed property of the same name but different type (`ContentViewController?`) silently shadows the superclass property within this class. Swift resolves access correctly (the private property wins inside the class), but:

- It makes the code deceptive: any reader who knows `NSSplitViewController.contentViewController` exists will momentarily assume the superclass property is in play.
- If Apple ever adds a `contentViewController` override to `NSSplitViewController` itself, there could be a conflict or subtle behavioral change.
- The previous code (pre-edit) had the same issue at the old index, but it was at index 1 for a 3-pane layout — now it's index 2, and the name collision is more confusing now that "content" also describes the editor panel visually.

**Impact:** Maintenance confusion; low risk of runtime breakage under Swift's name-resolution rules.

**Recommendation:** Rename to `previewViewController` or `markdownPreviewViewController` to align with its role:

```swift
private var previewViewController: ContentViewController? { ... }
```

Update all call sites inside `MainSplitViewController` (9 references).

---

## Medium

### M1 — Hardcoded integer index `[1]` for editor pane operations

**File:** `MainSplitViewController.swift:161–177, 223`

Three public accessors and the seed path use `splitViewItems[1]` to address the editor pane:

```swift
var isEditorVisible: Bool { return !splitViewItems[1].isCollapsed }
func toggleEditor() -> Bool { let editorItem = splitViewItems[1]; ... }
func showEditor() { splitViewItems[1].animator().isCollapsed = false }
// viewDidAppear:
splitViewItems[1].isCollapsed = true
```

The private `editorViewController` accessor correctly uses a type-checked path (`splitViewItems.dropFirst().first?.viewController as? EditorViewController`), but the collapse/expand operations bypass it. If the split order were ever changed (or if the sidebar collapses into a different position on macOS 15+ via `NSSplitViewItem.behavior` changes), these would silently target the wrong pane without a crash.

**Impact:** Fragile; produces subtle silent bugs if pane order changes.

**Recommendation:** Either store the `NSSplitViewItem` for the editor as a property:

```swift
private var editorSplitItem: NSSplitViewItem?
```

and reference it in `viewDidLoad` after `addSplitViewItem(editor)`, or derive the item via the already-type-safe `editorViewController` accessor:

```swift
var isEditorVisible: Bool {
    guard let vc = editorViewController,
          let item = splitViewItems.first(where: { $0.viewController === vc })
    else { return false }
    return !item.isCollapsed
}
```

---

### M2 — `updateEditor: Bool` flag parameter on `display()` is a control-flow flag

**File:** `MainSplitViewController.swift:65–73`

```swift
func display(markdown: String, fileName: String, url: URL?, assetBaseURL: URL?,
             updateEditor: Bool = true) {
```

Boolean flag parameters that change the behavioral branch taken by a function are a recognised API design smell. The flag exists because the editor-triggered re-render path (`handleEditorTextChange` → `renderCurrentDocument(..., updateEditor: false)`) must not feed text back into the editor. However:

- Every call site must reason about whether to pass `false` to avoid the feedback loop — invisible at the call site.
- `MainSplitViewController.setEditorText()` already exists as a separate method. The `updateEditor` flag duplicates its contract in a worse way.

**Impact:** API clarity; new contributors are likely to miss the `false` requirement on the render path and introduce a feedback loop.

**Recommendation:** Remove `updateEditor` from `display()`. In `DocumentWindowController.renderCurrentDocument`, call the preview-only path directly:

```swift
private func renderCurrentDocumentPreviewOnly(text: String, fileURL: URL) {
    let split = documentWindow.contentViewController as? MainSplitViewController
    split?.displayPreviewOnly(markdown: text, fileName: fileURL.lastPathComponent,
                               url: fileURL, assetBaseURL: fileURL.deletingLastPathComponent())
}
```

Where `displayPreviewOnly` on `MainSplitViewController` calls `contentViewController`, `sidebarViewController`, and `inspectorViewController` but not `editorViewController`.

---

### M3 — FileWatcher can trigger spurious "external change" alert after the app's own autosave

**File:** `DocumentWindowController.swift:163–175`

`MarkdownDocument.autosavesInPlace` is `true`. When AppKit autosaves, it calls `data(ofType:)`, writes the file, then calls `updateChangeCount(.changeAutosaved)`. The FileWatcher's `scheduleChange` debounce is 80 ms. If the debounce fires before `updateChangeCount(.changeAutosaved)` has completed (e.g., on a slow disk), `isDocumentEdited` is still `true`, and the condition:

```swift
if self.markdownDocument?.isDocumentEdited == true {
    self.showExternalChangeAlert(fileURL: url)
}
```

shows an "external change" alert after the app wrote the file itself. This is a false positive. There is also no guard against stacking multiple alerts if the FileWatcher fires multiple times before the user dismisses one.

**Impact:** User-visible incorrect alert; alarm fatigue if it becomes reproducible.

**Recommendation:** Track whether the app itself triggered the last write. One approach: set a `private var isSaving = false` flag around the `data(ofType:)` path (NSDocument calls it from `saveToURL:ofType:forSaveOperation:completionHandler:`, which can be overridden), and check it in the FileWatcher callback:

```swift
if !isSaving && markdownDocument?.isDocumentEdited == true {
    showExternalChangeAlert(fileURL: url)
}
```

Also add a guard against modal stacking: `guard presentedViewControllers?.isEmpty ?? true else { return }`.

---

### M4 — ⌘E keyboard shortcut advertised in tooltip but never registered

**File:** `DocumentWindowController.swift:1115`

```swift
item.toolTip = "Toggle source editor (⌘E)"
```

There is no corresponding `NSMenuItem` with `keyEquivalent = "e"` and `keyEquivalentModifierMask = .command`, and no `validateMenuItem` override or `keyDown` intercept. The shortcut is inert — pressing ⌘E does nothing.

**Impact:** User confusion; advertises a capability that doesn't exist.

**Recommendation:** Add a menu item in the View menu (matching the pattern of sidebar/inspector toggles) and wire it to `#selector(toggleEditorAction(_:))` via the responder chain. Then remove the ⌘E annotation from the tooltip (or keep it once the binding is live).

---

## Low

### L1 — `becomeFirstResponder()` override always returns `true` regardless of outcome

**File:** `EditorViewController.swift:75–78`

```swift
override func becomeFirstResponder() -> Bool {
    view.window?.makeFirstResponder(textView)
    return true
}
```

`makeFirstResponder(_:)` returns a `Bool` indicating whether the focus transfer succeeded. The override ignores this result and always claims success. If `textView` refuses first responder (e.g., it is disabled or the window is not yet on screen), callers receive a false confirmation.

**Recommendation:** Propagate the result:

```swift
override func becomeFirstResponder() -> Bool {
    view.window?.makeFirstResponder(textView) ?? false
}
```

---

### L2 — `editorTextDidChange` in `MainSplitViewController` is a zero-value passthrough

**File:** `MainSplitViewController.swift:208–211`

```swift
private func editorTextDidChange(_ newText: String) {
    onEditorTextChange?(newText)
}
```

This private method adds a layer of indirection with no transformation, context enrichment, or filtering. The closure wired in `viewDidLoad` could call `onEditorTextChange?` directly:

```swift
editorVC.onTextChange = { [weak self] newText in
    self?.onEditorTextChange?(newText)
}
```

The `editorTextDidChange` method can then be deleted.

**Recommendation:** Inline and remove the passthrough method.

---

### L3 — Force-unwrap `textView.textStorage!` in `setMarkdown`

**File:** `EditorViewController.swift:68`

```swift
highlighter.applyHighlighting(to: textView.textStorage!)
```

`NSTextView.textStorage` is typed as `NSTextStorage?`. In practice it is never nil for a standard `NSTextView`, but the force-unwrap is inconsistent with the otherwise careful code style (no other force-unwraps in the new code).

**Recommendation:**

```swift
if let storage = textView.textStorage {
    highlighter.applyHighlighting(to: storage)
}
```

---

### L4 — Italic regex overlaps bold syntax and overrides bold coloring

**File:** `MarkdownSyntaxHighlighter.swift:75–82`

The italic pattern is:

```
\*[^*\n]+\*
```

This matches `*text*` but also matches `**bold**` — specifically, `*bold*` inside the outer `**`. The bold pattern is applied first (lines 62–73) and correctly targets only the inner range via capture group. But the italic pattern then runs over the full string and re-colors the same characters with `italicColor` (`.secondaryLabelColor`), overriding the bold blue.

Example: `**word**` → bold pass colors `word` blue → italic pass then colors `word` gray because `*word*` matches.

The `applyCodeStyle` inside code fences correctly excludes overlap via `protectedRanges`. The inline patterns don't have equivalent mutual exclusion.

**Impact:** Incorrect syntax highlighting for bold text; bold text renders gray instead of blue.

**Recommendation:** Apply highlights in precedence order and track consumed ranges, or tighten the italic regex to require exactly one `*` on each side:

```
(?<!\*)\*(?!\*)[^*\n]+(?<!\*)\*(?!\*)
```

This uses lookahead/lookbehind to exclude positions adjacent to `**`. Alternatively, collect all bold match ranges as "protected" and pass them as an exclusion set to the italic pattern.

---

## Architectural Consistency Assessment

The new code integrates cleanly with existing patterns:

| Pattern | New code adherence |
|---|---|
| `weak var` for delegate/callback closures | ✓ Consistent throughout |
| `[weak self]` in all closures capturing self | ✓ No retain cycles observed |
| `DispatchWorkItem` debounce idiom | ✓ Matches find-bar and other debounce sites |
| `private` extension for toolbar item identifiers | ✓ Follows existing `NSToolbarItem.Identifier` extension |
| `NSScrollView + NSTextView` layout idiom | ✓ Matches established pattern |
| `nonisolated` + `Mutex` for concurrency-safe document storage | ✓ Unchanged, correct |
| `@discardableResult` on toggle methods | ✓ Consistent with `toggleSidebar`, `toggleInspector` |
| Immediate `viewDidLoad` composition (no storyboard) | ✓ Correct |
| `NSSplitViewItem(viewController:)` for middle pane | ✓ Correct (inspector uses `inspectorWithViewController:`, sidebar uses `sidebarWithViewController:`) |

The structural decisions — a separate `EditorViewController` with a single `onTextChange` callback, routing through `MainSplitViewController` to `DocumentWindowController`, with `MarkdownDocument` as the persistence layer — are sound and follow AppKit MVC norms. The issues identified are implementation-level defects within an otherwise well-reasoned design.
