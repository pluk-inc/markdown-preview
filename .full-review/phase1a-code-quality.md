# Phase 1-A: Code Quality Review
**Branch:** `feat/add-editing-support`  
**Diff base:** `7fc5aa2` (Release 0.0.28 — viewer-only)  
**Files reviewed:** `MarkdownDocument.swift`, `MainSplitViewController.swift`, `DocumentWindowController.swift`, `EditorViewController.swift` (new), `MarkdownSyntaxHighlighter.swift` (new), `Info.plist`, `md-preview.entitlements`

---

## Critical

---

### C-1 — Autosave triggers spurious "File Modified Externally" alert
**Files:** `MarkdownDocument.swift:24,27-29` · `DocumentWindowController.swift:165-169`

`autosavesInPlace` is now `true`. NSDocument's autosave pipeline writes to disk (step A) and only clears `isDocumentEdited` afterward (step B). The `FileWatcher` watches `[.write, .extend, .delete, .rename, .revoke]` with an 80 ms debounce. Because atomic in-place saves trigger a rename event, the FileWatcher re-opens and fires `onChange()`. If the debounce resolves between step A and step B, `isDocumentEdited` is still `true` and the alert fires on the user's _own_ autosave — an unrecoverable UX break.

The 80 ms debounce does not reliably save you: NSDocument autosaves are async and the window can exceed that.

**Fix:** Introduce a flag that suppresses the FileWatcher callback during saves. Hook into NSDocument's save pipeline:

```swift
// MarkdownDocument.swift
var isSaving = false

override func writeSafely(to url: URL, ofType typeName: String, for op: NSDocument.SaveOperationType) throws {
    isSaving = true
    defer { isSaving = false }
    try super.writeSafely(to: url, ofType: typeName, for: op)
}

// DocumentWindowController.swift — startWatching closure
guard let self, self.currentFileURL == url else { return }
guard self.markdownDocument?.isSaving != true else { return }
if self.markdownDocument?.isDocumentEdited == true {
    self.showExternalChangeAlert(fileURL: url)
} else {
    self.loadFile(at: url, silentOnFailure: true)
}
```

---

### C-2 — Regex patterns compiled on every keystroke
**File:** `MarkdownSyntaxHighlighter.swift:201, 218`

Both `applyPattern` overloads contain:

```swift
guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
```

`NSRegularExpression` compilation is expensive (DFA construction). There are seven call sites in `applyHighlighting`, each passing a constant string literal — patterns never change at runtime. Compiling them fresh on every keystroke adds O(7 × compile-cost) of unnecessary work on the main thread before every layout pass. Only `fenceOpenRegex` is cached as a `lazy var`.

**Fix:** Cache all patterns as lazy stored properties alongside `fenceOpenRegex`, or use a private static `patternCache: [String: NSRegularExpression]` keyed by pattern string:

```swift
private static var patternCache: [String: NSRegularExpression] = [:]

private func regex(for pattern: String) -> NSRegularExpression? {
    if let cached = Self.patternCache[pattern] { return cached }
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    Self.patternCache[pattern] = re
    return re
}
```

Replace both `try? NSRegularExpression(pattern: pattern)` calls with `regex(for: pattern)`.

---

## High

---

### H-1 — Force-unwrap of `textView.textStorage!` — crash path
**File:** `EditorViewController.swift:68, 83`

```swift
highlighter.applyHighlighting(to: textView.textStorage!)
```

This appears in both `setMarkdown` (called programmatically before the view is guaranteed on-screen) and `textDidChange` (called by AppKit). `NSTextView.textStorage` is `Optional<NSTextStorage>`. While it is almost never `nil` for a fully constructed `NSTextView`, a force-unwrap here crashes the process with no diagnostic. `textView` itself is also `!`-typed.

**Fix:**

```swift
// Both call sites — guard instead of force-unwrap
guard let storage = textView?.textStorage else { return }
highlighter.applyHighlighting(to: storage)
```

---

### H-2 — Full-document attribute reset on every keystroke
**File:** `MarkdownSyntaxHighlighter.swift:37-40`

```swift
textStorage.setAttributes(
    [.font: baseFont, .foregroundColor: NSColor.labelColor],
    range: fullRange
)
```

`setAttributes(_:range:)` replaces all attributes in `fullRange` on every call to `applyHighlighting`. For a 5,000-line document this is O(n) work — rebuilding every glyph run — before any pattern matching starts. Combined with the 7 regex passes, every keystroke forces a full relayout of the entire text container.

**Fix (incremental approach):** Track the edited range from `NSTextStorageDelegate.textStorage(_:willProcessEditing:range:changeInLength:)` and only reset + re-highlight the affected paragraph range (expanded to cover any multi-line constructs):

```swift
// EditorViewController — add delegate
textView.textStorage?.delegate = highlighter

// MarkdownSyntaxHighlighter — implement NSTextStorageDelegate
func textStorage(_ ts: NSTextStorage,
                 willProcessEditing mask: NSTextStorageEditActions,
                 range editedRange: NSRange,
                 changeInLength delta: Int) {
    guard mask.contains(.editedCharacters) else { return }
    // expand to paragraph boundaries, then highlight only that range
}
```

As a minimal-effort stop-gap: at least skip the full reset if the text length is above a threshold (e.g., 10,000 characters) and fall back to no highlighting to keep the editor responsive.

---

### H-3 — Magic index `splitViewItems[1]` without bounds-check in `viewDidAppear`
**File:** `MainSplitViewController.swift:223`

```swift
splitViewItems.first?.isCollapsed = true
splitViewItems[1].isCollapsed = true     // no guard
```

The first line uses optional chaining; the second subscripts directly. If `splitViewItems` has fewer than 2 items at this point (e.g., `viewDidLoad` threw silently, or order is changed in future), this will crash at launch on first run.

Contrast with every other new accessor (`isEditorVisible`, `toggleEditor`, `showEditor`) which all guard `splitViewItems.count > 1`. The inconsistency is the danger — it signals that the guard is not always remembered.

**Fix:**

```swift
if splitViewItems.count > 1 {
    splitViewItems[1].isCollapsed = true
}
```

Or, since `editorViewController` is already a safe computed property, prefer:

```swift
// Add a method to EditorSplitViewItem
private var editorSplitViewItem: NSSplitViewItem? {
    splitViewItems.count > 1 ? splitViewItems[1] : nil
}
// Then use editorSplitViewItem?.isCollapsed = true everywhere
```

---

## Medium

---

### M-1 — NSDocument undo state diverges from NSTextView undo
**Files:** `MarkdownDocument.swift:24, 71` · `EditorViewController.swift:38`

`hasUndoManager = true` is set on the document, and `textView.allowsUndo = true` is set on the text view. These are two separate undo managers. The NSTextView records per-keystroke undo operations through its own undo stack. `setMarkdown` calls `updateChangeCount(.changeDone)`, which informs NSDocument that the document is dirty.

The problem: when the user undoes all their edits via Cmd+Z (clearing the NSTextView's undo stack back to original), the NSDocument still considers itself edited (its `isDocumentEdited` remains `true` because no `.changeCleared` was issued). The document's dirty indicator (dot in the close button) stays on, and autosave keeps running even though the content is back to saved state.

**Fix:** Override `NSDocument.undoManager` to vend the NSTextView's undo manager, or observe `NSUndoManagerCheckpointNotification` to reconcile state. The simplest safe option is to disable the undo manager on the document (`hasUndoManager = false`) and let the NSTextView own all undo, while manually tracking dirty state via `replaceContents` vs `setMarkdown`:

```swift
// When textView's undo manager signals it's at the save point:
NotificationCenter.default.addObserver(
    forName: .NSUndoManagerCheckpoint,
    object: textView.undoManager, queue: .main
) { [weak self] _ in
    if self?.textView.undoManager?.isUndoing == false,
       self?.textView.undoManager?.canUndo == false {
        self?.document?.updateChangeCount(.changeCleared)
    }
}
```

---

### M-2 — `toggleEditorAction` double-casts and applies redundant text update
**File:** `DocumentWindowController.swift:1148-1155`

```swift
@objc private func toggleEditorAction(_ sender: Any) {
    let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
        .toggleEditor() ?? false
    setEditToggleSelected(isVisible)
    if isVisible, let markdown = currentMarkdown {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .setEditorText(markdown)
    }
}
```

Two issues:

1. **Redundant cast:** The split view controller is cast twice in the same function. This is a pre-existing pattern in the file, but the new code adds two more instances. The correct approach is a computed property (which already exists for `markdownDocument`):

```swift
private var splitViewController: MainSplitViewController? {
    documentWindow.contentViewController as? MainSplitViewController
}
```

2. **Redundant `setEditorText` on reveal:** `display(markdown:..., updateEditor: true)` (called on every file load and file-watcher reload) already calls `editorViewController?.setMarkdown(markdown)`. Since `NSSplitViewItem.isCollapsed = true` does not unload the view controller, the text view retains its content. Calling `setEditorText` on reveal resets the editor's scroll position and selection — it is a no-op for content but has UX side-effects for large files. Remove the `if isVisible` block.

---

### M-3 — ⌘E shortcut advertised but not wired
**File:** `DocumentWindowController.swift:1115`

```swift
item.toolTip = "Toggle source editor (⌘E)"
```

The tooltip documents a keyboard shortcut that doesn't exist in the changed code. There is no `NSMenuItem` with `keyEquivalent = "e"` and `keyEquivalentModifierMask = .command` wired to `toggleEditorAction`. Users who read the tooltip and press ⌘E will get unexpected behavior (likely triggers something else in the responder chain, e.g. an `edit:` action).

**Fix:** Add to the Edit menu (or View menu) in the app's main menu nib/storyboard, or wire it programmatically:

```swift
// In the app delegate or main menu setup
let item = NSMenuItem(
    title: "Toggle Editor",
    action: #selector(DocumentWindowController.toggleEditorAction),
    keyEquivalent: "e"
)
item.keyEquivalentModifierMask = .command
```

Until then, remove the shortcut hint from the tooltip.

---

### M-4 — Editor preview silently skips render when `currentFileURL` is nil
**File:** `DocumentWindowController.swift:1171-1173`

```swift
private func handleEditorTextChange(_ newText: String) {
    currentMarkdown = newText
    markdownDocument?.setMarkdown(newText)
    if let fileURL = currentFileURL {
        renderCurrentDocument(text: newText, fileURL: fileURL, updateEditor: false)
    }
}
```

If `currentFileURL` is nil (untitled document or document opened before a file URL is assigned), the editor accepts input, the document is marked dirty, but the preview never updates. The user sees their markdown source but a stale or blank preview — no error, no feedback.

**Fix:** Either disable the editor when no URL is set, or support rendering without a file URL by using a nil `assetBaseURL`:

```swift
if let fileURL = currentFileURL {
    renderCurrentDocument(text: newText, fileURL: fileURL, updateEditor: false)
} else {
    // Render without asset resolution
    (documentWindow.contentViewController as? MainSplitViewController)?
        .display(markdown: newText, fileName: "Untitled",
                 url: nil, assetBaseURL: nil, updateEditor: false)
}
```

---

### M-5 — `intersectsProtected` is O(n) per regex match
**File:** `MarkdownSyntaxHighlighter.swift:190-192`

```swift
private func intersectsProtected(_ range: NSRange, protected: [NSRange]) -> Bool {
    protected.contains { NSIntersectionRange($0, range).length > 0 }
}
```

For every regex match in every `applyPattern` call, this does a linear scan of all protected (fence) ranges. A document with 20 code fences and 500 inline-code spans would call this 500 × 20 = 10,000 times per keystroke, just for the inline-code pass.

**Fix:** Convert `protected` to `NSIndexSet` (which has O(log n) range intersection):

```swift
private func buildProtectedSet(from ranges: [NSRange]) -> NSIndexSet {
    let set = NSMutableIndexSet()
    ranges.forEach { set.add(in: $0) }
    return set
}

private func intersectsProtected(_ range: NSRange, protectedSet: NSIndexSet) -> Bool {
    protectedSet.intersects(in: range)
}
```

Pass the `NSIndexSet` through `applyPattern` instead of `[NSRange]`.

---

### M-6 — Two `applyPattern` overloads duplicate regex compile and enumerate logic
**File:** `MarkdownSyntaxHighlighter.swift:194-227`

The two overloads differ only in whether their closure returns `[NSAttributedString.Key: Any]` or a `(range:, attributes:)` tuple (allowing a capture-group sub-range). The bodies are structurally identical. This duplication means any future bug fix (e.g., thread safety, performance guard) must be applied twice.

**Fix:** Unify by making the first overload a convenience wrapper of the second:

```swift
private func applyPattern(
    _ pattern: String,
    in textStorage: NSTextStorage,
    string: NSString,
    excluding protected: [NSRange],
    attributes: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
) {
    applyPattern(pattern, in: textStorage, string: string, excluding: protected) { match in
        (range: match.range, attributes: attributes(match))
    }
}
```

---

## Low

---

### L-1 — Dead code: `insertMarkdownSnippet` is never called
**File:** `EditorViewController.swift:71-73`

```swift
func insertMarkdownSnippet(_ snippet: String) {
    textView.insertText(snippet, replacementRange: textView.selectedRange())
}
```

This public method has no callers anywhere in the diff or existing codebase. Uncalled public APIs become technical debt — they must be maintained, they appear in autocomplete, and they imply a contract that doesn't exist yet.

**Fix:** Remove it now; re-introduce when a real caller is added.

---

### L-2 — `setEditorText` creates a confusing parallel path alongside `display(updateEditor:)`
**File:** `MainSplitViewController.swift:76-78`

```swift
func setEditorText(_ text: String) {
    editorViewController?.setMarkdown(text)
}
```

The public API now has two ways to set the editor's content: `display(markdown:..., updateEditor: true)` and `setEditorText(_:)`. Both call `editorViewController?.setMarkdown`. The doc comment says `setEditorText` is "without triggering onTextChange" — but this is equally true of `display(updateEditor: true)`. The distinction has no behavioral difference.

**Fix:** Remove `setEditorText` and have callers use `display(markdown:..., updateEditor: true/false)` exclusively. The `toggleEditorAction` call site (which is the only caller in the new code) should be removed per M-2.

---

### L-3 — `becomeFirstResponder` override unusual — potential for re-entrant calls
**File:** `EditorViewController.swift:75-78`

```swift
override func becomeFirstResponder() -> Bool {
    view.window?.makeFirstResponder(textView)
    return true
}
```

`NSViewController.becomeFirstResponder()` is not an `NSResponder` method; it's a UIKit-style lifecycle hook in AppKit. Calling `window?.makeFirstResponder(textView)` inside it triggers the NSWindow's responder-chain machinery, which may cause unexpected delegate callbacks or re-entrant calls if anything in the responder chain ends up calling `becomeFirstResponder()` again. The standard AppKit pattern is to override `viewDidLoad` and have the view controller not itself claim first-responder status — instead expose a `focusEditor()` method that callers invoke explicitly.

**Fix:**

```swift
// Remove the override; add an explicit method
func focusEditor() {
    view.window?.makeFirstResponder(textView)
}
```

Call `splitVC.editorViewController?.focusEditor()` from `showEditor()` or `toggleEditor()` if focus-on-reveal is desired.

---

### L-4 — Magic numeric index coupling across all editor-pane accessors
**File:** `MainSplitViewController.swift:160-176, 196, 223`

The editor pane sits at index 1 in `splitViewItems`. This is correct given the insertion order (`sidebar=0, editor=1, content=2, inspector=3`), but it is encoded as bare integer literals at six separate sites:

- `isEditorVisible`: `splitViewItems[1]`
- `toggleEditor()`: `splitViewItems[1]` (×2)
- `showEditor()`: `splitViewItems[1]` (×2)
- `viewDidAppear`: `splitViewItems[1]`

While `editorViewController` uses the safe `dropFirst().first` idiom, none of the structural methods do. If a future pane is inserted before the editor, all six sites silently target the wrong pane.

**Fix:** Centralize the item lookup using the already-correct computed property:

```swift
private var editorSplitViewItem: NSSplitViewItem? {
    // Safe: follows the view controller, not an index
    splitViewItems.first { $0.viewController is EditorViewController }
}
```

Replace all `splitViewItems[1]` accesses with `editorSplitViewItem?`.

---

### L-5 — `image.isTemplate = true` mutates a potentially shared system symbol
**File:** `DocumentWindowController.swift:1117-1119`

```swift
let image = NSImage(systemSymbolName: "pencil.line",
                    accessibilityDescription: "Edit") ?? NSImage()
image.isTemplate = true
```

`NSImage` from `systemSymbolName:` may return a shared internal instance. Mutating `isTemplate` on it could affect other uses of the same symbol elsewhere. SF Symbols are already template images by default, making this mutation both dangerous and redundant.

**Fix:** Remove `image.isTemplate = true`. If a non-symbol fallback image is ever needed, copy it before mutating:

```swift
let image: NSImage
if let symbol = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Edit") {
    image = symbol  // already a template; no mutation needed
} else {
    image = NSImage(named: "pencil-fallback") ?? NSImage()
    // only mutate your own copy
}
```

---

## Summary Table

| ID  | Severity | File | Issue |
|-----|----------|------|-------|
| C-1 | Critical | `DocumentWindowController.swift`, `MarkdownDocument.swift` | Autosave fires FileWatcher → spurious "File Modified Externally" alert |
| C-2 | Critical | `MarkdownSyntaxHighlighter.swift:201,218` | 7 regex patterns compiled fresh on every keystroke |
| H-1 | High     | `EditorViewController.swift:68,83` | `textView.textStorage!` force-unwrap crash path |
| H-2 | High     | `MarkdownSyntaxHighlighter.swift:37-40` | Full-document O(n) attribute reset on every keystroke |
| H-3 | High     | `MainSplitViewController.swift:223` | `splitViewItems[1]` without guard in `viewDidAppear` |
| M-1 | Medium   | `MarkdownDocument.swift:24`, `EditorViewController.swift:38` | NSDocument and NSTextView undo managers are disconnected |
| M-2 | Medium   | `DocumentWindowController.swift:1148-1155` | `toggleEditorAction` double-casts + redundant `setEditorText` call |
| M-3 | Medium   | `DocumentWindowController.swift:1115` | ⌘E shortcut claimed in tooltip but not wired |
| M-4 | Medium   | `DocumentWindowController.swift:1171-1173` | Preview silently skips update when `currentFileURL` is nil |
| M-5 | Medium   | `MarkdownSyntaxHighlighter.swift:190-192` | `intersectsProtected` O(n) linear scan per match |
| M-6 | Medium   | `MarkdownSyntaxHighlighter.swift:194-227` | Duplicate regex compile + enumerate logic in two `applyPattern` overloads |
| L-1 | Low      | `EditorViewController.swift:71-73` | `insertMarkdownSnippet` dead code |
| L-2 | Low      | `MainSplitViewController.swift:76-78` | `setEditorText` parallel path redundant with `display(updateEditor:)` |
| L-3 | Low      | `EditorViewController.swift:75-78` | `becomeFirstResponder` override uses `makeFirstResponder` unsafely |
| L-4 | Low      | `MainSplitViewController.swift:160-176,223` | Six bare `splitViewItems[1]` literals instead of a typed accessor |
| L-5 | Low      | `DocumentWindowController.swift:1117-1119` | `image.isTemplate = true` mutates shared system symbol |
