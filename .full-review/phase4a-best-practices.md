# Phase 4a — Swift 6 & AppKit Best Practices Review

**Branch**: `feat/add-editing-support`  
**Base commit**: `7fc5aa2`  
**Reviewer role**: Swift 6 / AppKit best-practices specialist  
**Date**: 2026-06-28

---

## Scope

Files reviewed from `git diff 7fc5aa2..HEAD`:

| File | Status |
|---|---|
| `Info.plist` | Changed: `NSRole Viewer → Editor` |
| `md-preview/md-preview.entitlements` | Changed: read-only → read-write |
| `md-preview/MarkdownDocument.swift` | Changed: editable NSDocument |
| `md-preview/MainSplitViewController.swift` | Changed: 4th split pane |
| `md-preview/DocumentWindowController.swift` | Changed: toolbar, data flow |
| `md-preview/EditorViewController.swift` | New |
| `md-preview/MarkdownSyntaxHighlighter.swift` | New |

---

## Summary

| Severity | Count |
|---|---|
| Critical | 2 |
| High | 4 |
| Medium | 6 |
| Low | 5 |

---

## Critical Findings

---

### C-1 — Per-keystroke regex recompilation in `MarkdownSyntaxHighlighter`

**File**: `MarkdownSyntaxHighlighter.swift`  
**Location**: Both `applyPattern` overloads

**Current pattern**:

```swift
private func applyPattern(
    _ pattern: String,
    in textStorage: NSTextStorage,
    string: NSString,
    excluding protected: [NSRange],
    attributes: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    // ...
}
```

`applyHighlighting` makes 7 calls to `applyPattern`, each passing a pattern string literal. Every call compiles a new `NSRegularExpression` from scratch. Only `fenceOpenRegex` is `lazy`. NSRegularExpression compilation is not free: the NFA/DFA construction for complex patterns takes 1–4 ms per pattern. At 7 patterns per keystroke, the baseline overhead is 7–28 ms before any matching work begins. This directly feeds the 25–66 ms/keystroke frame budget violation noted in Phase 3.

**Recommended pattern**:

Cache every regex as a lazy instance property, mirroring the existing `fenceOpenRegex` approach:

```swift
final class MarkdownSyntaxHighlighter {

    // Compiled once, reused on every call
    private lazy var inlineCodeRegex = try? NSRegularExpression(pattern: "`[^`\\n]+`")
    private lazy var headingRegex    = try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$")
    private lazy var boldRegex       = try? NSRegularExpression(pattern: "(\\*\\*|__)(.+?)\\1")
    private lazy var italicRegex     = try? NSRegularExpression(pattern: "\\*[^*\\n]+\\*")
    private lazy var linkRegex       = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")
    private lazy var blockquoteRegex = try? NSRegularExpression(pattern: "(?m)^>\\s+.*$")
    private lazy var listRegex       = try? NSRegularExpression(pattern: "(?m)^[\\t ]*([-*+]|\\d+\\.)\\s")
    private lazy var hrRegex         = try? NSRegularExpression(pattern: "(?m)^[-*_]{3,}\\s*$")

    func applyHighlighting(to textStorage: NSTextStorage) {
        // ...
        applyPattern(inlineCodeRegex, in: textStorage, string: string,
                     excluding: fenceRanges) { _ in [...] }
        // etc.
    }

    private func applyPattern(
        _ regex: NSRegularExpression?,
        in textStorage: NSTextStorage,
        string: NSString,
        excluding protected: [NSRange],
        attributes: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]
    ) {
        guard let regex else { return }
        // ... same matching body
    }
}
```

Alternatively store them in a `static let` dictionary keyed on pattern string, which survives across instances and is safe because `NSRegularExpression` is thread-safe.

**Impact**: Eliminates 7–28 ms of wasted compilation per keystroke; resolves the dominant contributor to the 25–66 ms/keystroke budget overrun.

---

### C-2 — `applyHighlighting` runs synchronously on main thread — full document, every keystroke

**File**: `EditorViewController.swift` + `MarkdownSyntaxHighlighter.swift`  
**Location**: `EditorViewController.textDidChange(_:)` and `EditorViewController.setMarkdown(_:)`

**Current pattern**:

```swift
func textDidChange(_ notification: Notification) {
    guard !isSettingText else { return }
    highlighter.applyHighlighting(to: textView.textStorage!)   // full document, synchronous
    debounceWork?.cancel()
    // ...
}
```

`applyHighlighting` applies `setAttributes` over the full document range on every `textDidChange` call — not debounced, not incremental. For a 500-line document with 8 patterns each scanning O(N) characters, this is 8 × O(N) regex matches plus 8 × NSTextStorage attribute mutations per character typed. Even after fixing C-1, this is 20–60 ms on realistic files.

`NSTextStorage` attribute mutations inside `textDidChange` also re-trigger layout — the layout manager re-lays the entire document, which is O(N) glyph generation.

**Recommended pattern**:

1. Debounce highlighting with a short interval (50–80 ms); apply only to the edited paragraph range immediately, then re-highlight the full document after the debounce:

```swift
func textDidChange(_ notification: Notification) {
    guard !isSettingText else { return }

    // Immediate: re-highlight only the edited paragraph (cheap, keeps cursor consistent)
    if let editedRange = textView.textStorage?.editedRange {
        let paraRange = (textView.string as NSString).paragraphRange(for: editedRange)
        highlighter.applyHighlighting(to: textView.textStorage!, range: paraRange)
    }

    // Deferred: full re-highlight (catches cross-paragraph constructs like code fences)
    highlightWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.highlighter.applyHighlighting(to: self.textView.textStorage!)
    }
    highlightWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)

    // Propagate text change (separate debounce)
    debounceWork?.cancel()
    // ...
}
```

2. Add `applyHighlighting(to:range:)` that only scans and mutates within a paragraph or edited range.

**Impact**: Eliminates 20–60 ms/keystroke layout thrash; resolves the frame budget violation at normal typing speed.

---

## High Findings

---

### H-1 — `@concurrent` task closure attribute is non-idiomatic Swift 6

**File**: `DocumentWindowController.swift`  
**Locations**: `offerToBecomeDefaultHandlerIfNeeded()` (line ~215) and `loadFile(at:silentOnFailure:)` (line ~1717)

**Current pattern**:

```swift
// offerToBecomeDefaultHandlerIfNeeded
Task { @concurrent in
    try? await NSWorkspace.shared.setDefaultApplication(
        at: Bundle.main.bundleURL,
        toOpen: markdownType
    )
}

// loadFile
Task { @concurrent [weak self] in
    do {
        let text = try String(contentsOf: url, encoding: .utf8)
        await self?.applyLoadedMarkdown(text, fileURL: url)
    } catch { ... }
}
```

`@concurrent` on a task closure body is not in any ratified Swift Evolution proposal. It appears to be an Xcode-internal or pre-release attribute. On `@MainActor`-isolated types (NSWindowController subclasses are `@MainActor` by inference), the idiomatic Swift 6 way to run work off the main actor is `Task.detached { }` for fire-and-forget or a structured hop via `await withTaskGroup`.

In `loadFile`, the closure correctly uses `await self?.applyLoadedMarkdown(...)` to hop back to the main actor — that part is right. But the `@concurrent` attribute is doing the work that `Task.detached` is designed for.

**Recommended pattern**:

```swift
// Fire-and-forget background work
Task.detached {
    try? await NSWorkspace.shared.setDefaultApplication(
        at: Bundle.main.bundleURL,
        toOpen: markdownType
    )
}

// I/O with main-actor callback
Task.detached { [weak self] in
    do {
        let text = try String(contentsOf: url, encoding: .utf8)
        await self?.applyLoadedMarkdown(text, fileURL: url)
    } catch {
        let nsError = error as NSError
        await self?.applyLoadFailure(error: nsError, silentOnFailure: silentOnFailure)
    }
}
```

`Task.detached` is explicitly documented, stable, and clearly signals "this work is not bound to the calling actor."

**Severity rationale**: `@concurrent` may work today but is an undocumented attribute. A compiler update could silently stop recognizing it or change its semantics, causing `loadFile` to run `String(contentsOf:)` on the main actor — a latent blocking-main-thread bug.

---

### H-2 — Dual source of truth for document markdown text

**File**: `DocumentWindowController.swift` + `MarkdownDocument.swift`  
**Location**: `currentMarkdown` (DWC) vs `markdownStorage` (MD)

**Current pattern**:

The controller maintains `private var currentMarkdown: String?` in parallel with `MarkdownDocument.markdownStorage`. These can diverge:

1. `handleEditorTextChange` updates `currentMarkdown` first, then calls `markdownDocument?.setMarkdown(newText)` — they stay in sync here.
2. `applyLoadedMarkdown` updates `currentMarkdown = text` then `markdownDocument?.replaceContents(...)` — in sync.
3. `present(url:)` sets `currentMarkdown = nil` immediately — but the document still holds the old string until `applyLoadedMarkdown` fires.
4. `toggleEditorAction` reads `currentMarkdown` to seed the editor when opening the panel — if the 200 ms debounce hasn't flushed, this is stale.

The authoritative source should be `MarkdownDocument`, not a cached copy in the controller.

**Recommended pattern**:

Remove `currentMarkdown` from `DocumentWindowController`. Use `markdownDocument?.markdown` as the single source of truth:

```swift
// In toggleEditorAction:
if isVisible {
    let text = markdownDocument?.markdown ?? ""
    split.setEditorText(text)
}

// In items(for:pickerToolbarItem:):
guard let currentMarkdown = markdownDocument?.markdown else { return [] }
return [currentMarkdown]

// In handleRename(to:):
if let markdown = markdownDocument?.markdown, !markdown.isEmpty {
    split.openFileURLDidChange(newURL, markdown: markdown)
} else {
    loadFile(at: newURL, silentOnFailure: true)
}
```

This eliminates the entire class of stale-cache bugs and removes the dual-write on every text change.

---

### H-3 — `toggleEditorAction` seeds editor from potentially-stale `currentMarkdown`

**File**: `DocumentWindowController.swift`  
**Location**: `toggleEditorAction(_:)` (~line 1148)

**Current pattern**:

```swift
@objc private func toggleEditorAction(_ sender: Any) {
    let isVisible = ... .toggleEditor() ?? false
    setEditToggleSelected(isVisible)
    if isVisible, let markdown = currentMarkdown {
        ... .setEditorText(markdown)
    }
}
```

When the user types something then immediately closes the editor panel (within the 200 ms debounce window), `currentMarkdown` is still the pre-edit value. Reopening the panel calls `setEditorText(currentMarkdown)` — overwriting what the user typed. This is prior phase finding #4, but the root cause is this code and the fix belongs here.

**Recommended fix** (resolves with H-2 fix):

```swift
@objc private func toggleEditorAction(_ sender: Any) {
    guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
    let isVisible = split.toggleEditor()
    setEditToggleSelected(isVisible)
    if isVisible {
        // Flush any pending debounce first to preserve in-flight edits
        editorDebounceFlush()
        let text = markdownDocument?.markdown ?? ""
        split.setEditorText(text)
    }
}

private func editorDebounceFlush() {
    // Reach into the editor VC and flush the pending work item synchronously
    guard let split = documentWindow.contentViewController as? MainSplitViewController else { return }
    split.flushPendingEditorChange()
}
```

And in `MainSplitViewController`:

```swift
/// Immediately fires any pending editor text-change debounce.
func flushPendingEditorChange() {
    editorViewController?.flushPendingChange()
}
```

And in `EditorViewController`:

```swift
func flushPendingChange() {
    debounceWork?.cancel()
    debounceWork = nil
    onTextChange?(currentText)
}
```

---

### H-4 — `intersectsProtected` performs O(M×K) linear scan

**File**: `MarkdownSyntaxHighlighter.swift`  
**Location**: `intersectsProtected(_:protected:)` and callers

**Current pattern**:

```swift
private func intersectsProtected(_ range: NSRange, protected: [NSRange]) -> Bool {
    protected.contains { NSIntersectionRange($0, range).length > 0 }
}
```

For each of M regex matches, this does a linear scan over K protected fence-line ranges. A 200-line code fence creates 200 entries in `protectedRanges`. Combined with 7 regex patterns each potentially having O(N) matches, total work is O(7 × M × K).

**Recommended fix**:

Merge fence ranges into contiguous intervals at construction time (fence blocks are contiguous by definition), then use binary search:

```swift
/// Compacts overlapping or adjacent NSRange entries into sorted, non-overlapping intervals.
private func mergedIntervals(_ ranges: [NSRange]) -> [NSRange] {
    let sorted = ranges.sorted { $0.location < $1.location }
    var result: [NSRange] = []
    for r in sorted {
        if var last = result.last,
           r.location <= NSMaxRange(last) {
            result[result.count - 1] = NSUnionRange(last, r)
        } else {
            result.append(r)
        }
    }
    return result
}

private func intersectsProtected(_ range: NSRange, protected: [NSRange]) -> Bool {
    // Binary search: find leftmost interval whose maxRange > range.location
    var lo = 0, hi = protected.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if NSMaxRange(protected[mid]) <= range.location {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    guard lo < protected.count else { return false }
    return protected[lo].location < NSMaxRange(range)
}
```

Call `mergedIntervals` once on the result of `highlightCodeFences` before passing to each `applyPattern` call. This reduces per-match overhead from O(K) to O(log K).

---

## Medium Findings

---

### M-1 — Hardcoded split-item indices are fragile

**File**: `MainSplitViewController.swift`  
**Locations**: `isEditorVisible`, `toggleEditor`, `showEditor`, `viewDidAppear`, `contentViewController`

**Current pattern**:

```swift
var isEditorVisible: Bool {
    guard splitViewItems.count > 1 else { return false }
    return !splitViewItems[1].isCollapsed   // magic index
}

func toggleEditor() -> Bool {
    guard splitViewItems.count > 1 else { return false }
    let editorItem = splitViewItems[1]       // magic index
    ...
}

// viewDidAppear:
splitViewItems[1].isCollapsed = true        // magic index
```

`splitViewItems[1]` and `splitViewItems[2]` hardcode the order. If a new pane is inserted before the editor (e.g., a minimap, a breadcrumbs bar), every index silently shifts. `editorViewController` uses a type-safe cast via `dropFirst().first`, but the collapse/expand APIs don't.

**Recommended pattern**:

Find items by type, not position:

```swift
private var editorSplitItem: NSSplitViewItem? {
    splitViewItems.first { $0.viewController is EditorViewController }
}

var isEditorVisible: Bool {
    editorSplitItem?.isCollapsed == false
}

func toggleEditor() -> Bool {
    guard let item = editorSplitItem else { return false }
    let shouldShow = item.isCollapsed
    item.animator().isCollapsed = !shouldShow
    return shouldShow
}
```

Apply the same pattern to `contentViewController` (find first `ContentViewController`) and seed logic in `viewDidAppear`.

---

### M-2 — `MarkdownSyntaxHighlighter` not annotated `@MainActor` but mutates `NSTextStorage`

**File**: `MarkdownSyntaxHighlighter.swift`

**Current pattern**:

```swift
final class MarkdownSyntaxHighlighter {
    func applyHighlighting(to textStorage: NSTextStorage) {
        textStorage.beginEditing()
        textStorage.setAttributes(...)
        ...
        textStorage.endEditing()
    }
}
```

`NSTextStorage` is not thread-safe. Any mutation must occur on the main thread. `MarkdownSyntaxHighlighter` has no actor annotation, so Swift 6's actor checker cannot verify it's always called from `@MainActor` context. The callers happen to be on the main actor today, but the compiler won't catch a future off-actor call.

**Recommended fix**:

```swift
@MainActor
final class MarkdownSyntaxHighlighter {
    func applyHighlighting(to textStorage: NSTextStorage) { ... }
}
```

If the class needs to be instantiated off-actor (it doesn't), mark only `applyHighlighting` as `@MainActor`.

---

### M-3 — `isSettingText` flag is effectively dead code

**File**: `EditorViewController.swift`  
**Location**: `setMarkdown(_:)` and `textDidChange(_:)`

**Current pattern**:

```swift
func setMarkdown(_ text: String) {
    isSettingText = true
    textView.string = text     // <-- does NOT trigger textDidChange
    isSettingText = false
    highlighter.applyHighlighting(to: textView.textStorage!)
}

func textDidChange(_ notification: Notification) {
    guard !isSettingText else { return }   // unreachable guard
    ...
}
```

`NSTextView.string = value` sets the backing `NSTextStorage` text but does **not** fire `NSTextViewDelegate.textDidChange(_:)`. That delegate method is only called for user-initiated edits (keyboard input, paste, etc.) and programmatic edits via `insertText(_:replacementRange:)`. The guard `!isSettingText` in `textDidChange` can never be `true` when set via the `string` property.

This creates a false sense of safety. A future developer adding `textView.insertText(...)` in `setMarkdown` would break silently.

**Recommended fix**:

Replace the flag with the correct API boundary comment, or use `insertText` with an explicit guard:

```swift
func setMarkdown(_ text: String) {
    // NSTextView.string assignment does NOT trigger textDidChange; no guard needed.
    textView.string = text
    highlighter.applyHighlighting(to: textView.textStorage!)
}
```

Or if `insertText` is ever needed, use `NSTextView.shouldChangeText(in:replacementString:)` to intercept programmatic changes properly.

---

### M-4 — `becomeFirstResponder()` override: wrong responder chain assumption

**File**: `EditorViewController.swift`  
**Location**: `becomeFirstResponder()`

**Current pattern**:

```swift
override func becomeFirstResponder() -> Bool {
    view.window?.makeFirstResponder(textView)
    return true
}
```

`NSViewController` is an `NSResponder` subclass, so the override compiles. However, `NSViewController` instances are NOT normally part of the window's responder chain unless explicitly inserted. In the NSSplitViewController architecture used here, the VC's view is in the chain but the VC itself typically isn't sent `becomeFirstResponder` by AppKit.

The real effect desired (focus the text view when the panel opens) should be done in `viewDidAppear` or in response to the split item becoming un-collapsed:

```swift
override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(textView)
}
```

If focus-on-toggle is needed, the toggle caller (in `DocumentWindowController`) should explicitly call `makeFirstResponder(textView)` after un-collapsing the panel.

The current override also always returns `true` without checking whether the window accepts the redirect — if the textView rejects first responder (e.g., it's disabled), the function lies.

---

### M-5 — `replaceFileURL` bypasses NSDocument's change-coordination API

**File**: `MarkdownDocument.swift`  
**Location**: `replaceFileURL(_:)` and `replaceContents(markdown:fileURL:)`

**Current pattern**:

```swift
func replaceFileURL(_ fileURL: URL) {
    self.fileURL = fileURL
    updateChangeCount(.changeCleared)
}
```

Setting `self.fileURL` directly on `NSDocument` while autosave is enabled (`autosavesInPlace = true`) can race with an in-flight autosave that has captured the old URL. `NSDocument` uses NSFileCoordinator internally; bypassing it by direct property mutation can produce a write to a stale path.

The AppKit-correct approach for reloading document contents from an external change is to use the document's revert machinery:

```swift
// Preferred: use NSDocument's designed reload path
try? revert(toContentsOf: fileURL, ofType: fileType ?? "public.plain-text")
```

For the rename case (same content, new URL):

```swift
// Coordinate the URL change through FileCoordinator
NSFileCoordinator().coordinate(writingItemAt: fileURL, options: [], error: nil) { newURL in
    self.fileURL = newURL
}
updateChangeCount(.changeCleared)
```

If `revert(toContentsOf:)` is too heavy (it re-reads from disk), a lighter alternative is calling `move(to:completionHandler:)` which is the documented API for relocating an NSDocument.

---

### M-6 — `url.path` usage — deprecated in favor of `url.path(percentEncoded:)` on macOS 13+

**File**: `DocumentWindowController.swift`, `FileWatcher`  
**Locations**: Multiple; e.g., `FileWatcher.open()` and `DocumentWindowController.editorCandidates(for:)`

**Current pattern**:

```swift
let fd = Darwin.open(url.path, O_EVTONLY)
// ...
let icon = NSWorkspace.shared.icon(forFile: url.path)
```

`URL.path` (the `String`-returning property) was deprecated in macOS 13 in favor of `URL.path(percentEncoded:)`. For file-system paths that must survive round-trips through Darwin C APIs (`open(2)`, `fcntl`), the correct call is:

```swift
let fd = Darwin.open(url.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) } ?? url.path, O_EVTONLY)
```

Or more idiomatically:

```swift
url.withUnsafeFileSystemRepresentation { ptr in
    guard let ptr else { return }
    fileDescriptor = Darwin.open(ptr, O_EVTONLY)
}
```

`URL.withUnsafeFileSystemRepresentation` gives the correct file-system-encoded bytes directly, avoiding the String encoding detour entirely.

---

## Low Findings

---

### L-1 — `headingFont` and `boldFont` are identical — no visual heading hierarchy

**File**: `MarkdownSyntaxHighlighter.swift`

**Current pattern**:

```swift
private let headingFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
private let boldFont:    NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
```

Both fonts are the same object. Headings are distinguished only by color (`.systemBlue`), not size. Standard Markdown editors scale heading font size proportionally (e.g., H1 = 18 pt, H2 = 16 pt, H3 = 14 pt). With a monospaced editor font this is a design choice, but the identical constants are confusing and `headingFont` carries no meaning.

**Recommended fix**:

Either remove `headingFont` and use `boldFont` directly for headings, or differentiate by size:

```swift
private func headingFont(for level: Int) -> NSFont {
    let size: CGFloat = level == 1 ? 17 : level == 2 ? 15 : 13
    return .monospacedSystemFont(ofSize: size, weight: .bold)
}
```

---

### L-2 — `textView.textStorage!` force-unwrap

**File**: `EditorViewController.swift`  
**Locations**: `setMarkdown(_:)` and `textDidChange(_:)`

**Current pattern**:

```swift
highlighter.applyHighlighting(to: textView.textStorage!)
```

`NSTextView.textStorage` is declared as `NSTextStorage?` in the SDK. It is always non-nil after `loadView()` completes (the text view creates default storage in its initializer), but the force-unwrap bypasses the type system guarantee.

**Recommended fix**:

```swift
if let storage = textView.textStorage {
    highlighter.applyHighlighting(to: storage)
}
```

Or assert for debuggability:

```swift
guard let storage = textView.textStorage else {
    assertionFailure("NSTextView has no textStorage after loadView")
    return
}
highlighter.applyHighlighting(to: storage)
```

---

### L-3 — `scrollView.contentSize` read before layout in `loadView()`

**File**: `EditorViewController.swift`  
**Location**: `loadView()` (container size setup)

**Current pattern**:

```swift
textView.textContainer?.containerSize = NSSize(
    width: scrollView.contentSize.width,   // zero before layout
    height: CGFloat.greatestFiniteMagnitude
)
```

At `loadView()` time the scroll view has not been placed in a window or laid out. `scrollView.contentSize.width` is 0. This sets the container width to 0, then `widthTracksTextView = true` overrides it on the first layout pass — so the effect is benign. But it documents the intent incorrectly and could confuse a future reader.

**Recommended fix**:

Remove the explicit `containerSize` line; `widthTracksTextView = true` makes it redundant:

```swift
textView.textContainer?.widthTracksTextView = true
// containerSize does not need manual init when widthTracksTextView is true
```

---

### L-4 — Toolbar button wrapped in container view without semantic reason

**File**: `DocumentWindowController.swift`  
**Location**: `makeEditToggleItem()`

**Current pattern**:

```swift
let container = NSView()
container.translatesAutoresizingMaskIntoConstraints = false
container.addSubview(button)
NSLayoutConstraint.activate([
    button.heightAnchor.constraint(equalToConstant: 32),
    container.widthAnchor.constraint(equalToConstant: 36),
    container.heightAnchor.constraint(equalToConstant: 32)
])
item.view = container
```

The container exists solely to constrain width to 36 pt. Wrapping a button in a transparent `NSView` forces the toolbar layout engine to treat this as an opaque item of fixed size and prevents the system from applying native toolbar-item size animation or accessibility focus rings correctly.

Setting `item.view = button` directly and using `item.minSize`/`item.maxSize` is the documented NSToolbarItem API for size control:

```swift
item.view = button
item.minSize = NSSize(width: 32, height: 32)
item.maxSize = NSSize(width: 40, height: 32)
```

This preserves the native toolbar accessibility behavior (VoiceOver can focus the button directly) and removes the wrapper allocation.

---

### L-5 — Missing explicit `@MainActor` on new AppKit subclasses

**Files**: `EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift`

**Current pattern**:

Neither new class carries an explicit `@MainActor` annotation. They inherit it implicitly — `NSViewController` is `@MainActor`, and `MarkdownSyntaxHighlighter` is instantiated and called exclusively from `@MainActor` contexts.

In Swift 6, implicit `@MainActor` inference through protocol conformance is correct and documented, but explicit annotation at the class declaration communicates intent clearly and makes the compiler's isolation checks more precise:

```swift
@MainActor
final class EditorViewController: NSViewController, NSTextViewDelegate { ... }

@MainActor
final class MarkdownSyntaxHighlighter { ... }
```

This is especially important for `MarkdownSyntaxHighlighter`, which is not an AppKit subclass and has no automatic inference — its `@MainActor` requirement is only enforced by caller context, not by the type system.

---

## NSDocument Lifecycle Assessment

### Viewer → Editor Transition

| Requirement | Status | Notes |
|---|---|---|
| `NSRole` in `Info.plist` | ✅ `Editor` | Correct |
| Entitlement `read-write` | ✅ Added | Required for `autosavesInPlace` |
| `autosavesInPlace = true` | ✅ Added | Enables system save |
| `hasUndoManager = true` | ✅ Added | Allows undo registration |
| `data(ofType:)` implemented | ✅ | UTF-8 serialization correct |
| `read(from:ofType:)` (nonisolated) | ✅ | Mutex-protected; correct |
| `updateChangeCount(.changeDone)` on edit | ✅ | In `setMarkdown()` |
| Autosave / FileWatcher race handled | ⚠️ | `isDocumentEdited` check is racy (see prior phase C-1); no structural fix in this diff |
| `preservesVersions` override | ℹ️ | Not needed; defaults to `autosavesInPlace` value — correct |
| `writeSafely(to:ofType:for:)` override | ℹ️ | Not overridden; NSDocument's default calls `data(ofType:)` — correct |
| Undo manager wiring to NSTextView | ❌ | NSTextView creates its own undo manager; document's undo manager is disconnected (prior phase finding #6) |
| `revertToSaved` / `replaceFileURL` | ⚠️ | Direct `self.fileURL =` mutation bypasses file coordination (M-5 above) |

### Concurrency Safety in MarkdownDocument

The `Mutex<String>` / `Mutex<URL?>` pattern from `Synchronization` is the correct Swift 6 mechanism for `nonisolated` stored properties that are accessed from both background I/O threads (NSDocument read/write callbacks) and the main actor (UI). The pattern is correctly applied:

- `read(from:)` and `data(ofType:)` are `nonisolated` and call `withLock` — correct.
- `setMarkdown(_:)` is `@MainActor` (inherited from NSDocument) and also calls `withLock` — `Mutex` is safe from any thread, so this is correct even though the lock is uncontested at this call site.
- `markdown` computed property calls `withLock` — correct.

No issues with the `Mutex` usage.

---

## Memory Management Assessment

| Location | Pattern | Status |
|---|---|---|
| `EditorViewController.onTextChange` | `((String) -> Void)?` stored as non-weak value | ✅ Closure captures `[weak self]` at call site |
| `MainSplitViewController.onEditorTextChange` | Same | ✅ `[weak self]` at capture site |
| `textView.delegate = self` | `NSTextView.delegate` is `weak var` | ✅ No retain cycle |
| `editorVC.onTextChange = { [weak self] ... }` in `MainSplitViewController` | ✅ | Weak capture avoids cycle |
| `FileWatcher.onChange` stored as strong `() -> Void` | FileWatcher held as `var fileWatcher: FileWatcher?` by DWC | ✅ Closure uses `[weak self]`; when DWC is deallocated, `fileWatcher` is nilled and the `weak self` guard fires |
| `DispatchWorkItem` in EditorVC debounce | `[weak self]` in the work item | ✅ |
| Toolbar button weak references (`weak var editToggleButton`) | ✅ | Toolbar item retains the view; weak reference in DWC is correct |
| `NSSplitViewItem` → `EditorViewController` | Strong reference from splitViewItems array | ✅ Normal parent-owns-child hierarchy |

No retain cycles detected in the new code. Memory management is correct.

---

## Deprecated API Audit

| API | Status | Replacement |
|---|---|---|
| `url.path` (String-returning) | ⚠️ Deprecated macOS 13+ | `url.withUnsafeFileSystemRepresentation` or `url.path(percentEncoded: false)` |
| `NSWorkspace.urlForApplication(toOpen:)` | ✅ Not deprecated | — |
| `NSEvent.modifierFlags` (class property) | ✅ Not deprecated | — |
| `DispatchQueue.main.asyncAfter` | ℹ️ Not deprecated, but Swift Concurrency `Task.sleep` is preferred for new code | — |
| `NSTextView.string` setter | ✅ Not deprecated | — |
| `NSFont.monospacedSystemFont(ofSize:weight:)` | ✅ Not deprecated | — |

---

## Quick-Fix Checklist

| ID | File | Action |
|---|---|---|
| C-1 | `MarkdownSyntaxHighlighter.swift` | Cache all 8 regexes as `private lazy var` |
| C-2 | `EditorViewController.swift` | Add incremental highlighting + debounced full-highlight |
| H-1 | `DocumentWindowController.swift` | Replace `Task { @concurrent in }` with `Task.detached { }` |
| H-2 | `DocumentWindowController.swift` | Remove `currentMarkdown`; read from `markdownDocument?.markdown` |
| H-3 | `DocumentWindowController.swift` + `EditorViewController.swift` | Add `flushPendingChange()` API; call before seeding editor on toggle |
| H-4 | `MarkdownSyntaxHighlighter.swift` | Merge fence ranges; binary-search in `intersectsProtected` |
| M-1 | `MainSplitViewController.swift` | Replace index-based access with type-based discovery |
| M-2 | `MarkdownSyntaxHighlighter.swift` | Add `@MainActor` to the class |
| M-3 | `EditorViewController.swift` | Remove `isSettingText` flag and dead guard |
| M-4 | `EditorViewController.swift` | Move focus to `viewDidAppear`; remove `becomeFirstResponder` override |
| M-5 | `MarkdownDocument.swift` | Use `revert(toContentsOf:)` or `NSFileCoordinator` for URL mutation |
| M-6 | `DocumentWindowController.swift`, `FileWatcher` | Replace `url.path` with `withUnsafeFileSystemRepresentation` |
| L-1 | `MarkdownSyntaxHighlighter.swift` | Remove redundant `headingFont`; differentiate or alias |
| L-2 | `EditorViewController.swift` | Replace `textView.textStorage!` with guarded optional |
| L-3 | `EditorViewController.swift` | Remove redundant `containerSize` init in `loadView()` |
| L-4 | `DocumentWindowController.swift` | Remove toolbar container wrapper; use `item.minSize`/`maxSize` |
| L-5 | `EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift` | Add explicit `@MainActor` |
