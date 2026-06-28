# Agent Brief: Integration (MainSplitViewController + DocumentWindowController)

## Context

You are working on a macOS AppKit app called "Markdown Preview" (bundle id: `doc.md-preview`,
min macOS 15.0). We have just added editing support in the foundation layer:

- `MarkdownDocument` now supports saving (`data(ofType:)` returns UTF-8 data), undo
  (`hasUndoManager = true`), autosaves in place, and has a `setMarkdown(_ newText: String)`
  method that updates the markdown and marks the document dirty.
- Two new files exist:
  - `md-preview/EditorViewController.swift` — an NSViewController wrapping NSScrollView+NSTextView
    for Markdown source editing. It has:
    - `var onTextChange: ((String) -> Void)?` — debounced callback when user edits
    - `func setMarkdown(_ text: String)` — programmatic text set (doesn't fire onTextChange)
    - `var currentText: String` — read-only computed property for current text
  - `md-preview/MarkdownSyntaxHighlighter.swift` — regex-based syntax highlighting

Your task is to wire the editor pane into the app by modifying TWO existing files:
1. `md-preview/MainSplitViewController.swift`
2. `md-preview/DocumentWindowController.swift`

## File 1: `md-preview/MainSplitViewController.swift`

### Current structure (3 panes)
The split view currently has 3 items: [sidebar, content, inspector].

### Required changes

Add the editor as a 4th pane, inserted between sidebar and content. The pane starts COLLAPSED.

#### In `viewDidLoad()`:

After creating the sidebar item and before creating the content item, add:

```swift
let editorVC = EditorViewController()
editorVC.onTextChange = { [weak self] newText in
    self?.editorTextDidChange(newText)
}
let editor = NSSplitViewItem(viewController: editorVC)
editor.minimumThickness = 300
editor.maximumThickness = 800
editor.canCollapse = true
editor.canCollapseFromWindowResize = false
```

Insert the editor pane at index 1 (after sidebar, before content):

The order of `addSplitViewItem` should be: sidebar, editor, content, inspector.
Start the editor collapsed: in `viewDidAppear()`, add `splitViewItems[1].isCollapsed = true`
(but only on first launch, same pattern as the existing sidebar seed).

#### Update accessor properties:

The existing private computed properties index into `splitViewItems`:
- `sidebarViewController` — stays at `.first`
- `contentViewController` — was `dropFirst().first`, now needs to account for the editor. Use index 2.
- `inspectorViewController` — stays at `.last`

Add a new accessor:
```swift
private var editorViewController: EditorViewController? {
    splitViewItems.dropFirst().first?.viewController as? EditorViewController
}
```

And update:
```swift
private var contentViewController: ContentViewController? {
    guard splitViewItems.count > 2 else { return nil }
    return splitViewItems[2].viewController as? ContentViewController
}
```

#### Add editor-specific methods:

```swift
/// Called by the editor when the user edits text.
private func editorTextDidChange(_ newText: String) {
    // This is called from EditorViewController's debounced onTextChange.
    // Propagate to the window controller via a new callback.
    onEditorTextChange?(newText)
}

/// Callback to propagate editor text changes to the window controller.
var onEditorTextChange: ((String) -> Void)?
```

Add toggle and display methods:

```swift
var isEditorVisible: Bool {
    guard splitViewItems.count > 1 else { return false }
    return !splitViewItems[1].isCollapsed
}

@discardableResult
func toggleEditor() -> Bool {
    guard splitViewItems.count > 1 else { return false }
    let editorItem = splitViewItems[1]
    let shouldShow = editorItem.isCollapsed
    editorItem.animator().isCollapsed = !shouldShow
    return shouldShow
}

func showEditor() {
    guard splitViewItems.count > 1, splitViewItems[1].isCollapsed else { return }
    splitViewItems[1].animator().isCollapsed = false
}

/// Set the editor's text without triggering onTextChange (for file loads / external reloads).
func setEditorText(_ text: String) {
    editorViewController?.setMarkdown(text)
}
```

#### Update `display(markdown:fileName:url:assetBaseURL:)`:

After the existing lines that update content and sidebar, also update the editor if it's visible:
```swift
editorViewController?.setMarkdown(markdown)
```

## File 2: `md-preview/DocumentWindowController.swift`

### Required changes

#### A) Add editor toolbar item identifier

Add to the `NSToolbarItem.Identifier` extension at the top of the file:
```swift
static let editToggle = NSToolbarItem.Identifier("EditToggle")
```

#### B) Wire editor data flow in `setupWindow()`

After setting `split.onSelectFile`, add the editor text change callback:
```swift
split.onEditorTextChange = { [weak self] newText in
    self?.handleEditorTextChange(newText)
}
```

#### C) Add `handleEditorTextChange(_:)` method

```swift
private func handleEditorTextChange(_ newText: String) {
    currentMarkdown = newText
    markdownDocument?.setMarkdown(newText)
    // Re-render the preview with the new text
    if let fileURL = currentFileURL {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .contentViewController is not accessible (it's private). Instead, have the
            MainSplitViewController expose a method for this.
    }
    renderCurrentDocument(text: newText, fileURL: currentFileURL
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Untitled.md"))
}
```

Wait, let me correct that. The `renderCurrentDocument` method already exists. And `contentViewController` on MainSplitVC is private. So the correct approach is:

```swift
private func handleEditorTextChange(_ newText: String) {
    currentMarkdown = newText
    markdownDocument?.setMarkdown(newText)
    if let fileURL = currentFileURL {
        renderCurrentDocument(text: newText, fileURL: fileURL)
    }
}
```

This reuses the existing `renderCurrentDocument(text:fileURL:)` method which calls
`MainSplitViewController.display(markdown:fileName:url:assetBaseURL:)`.

**IMPORTANT**: In the `display(markdown:fileURL:)` method and `loadFile` flow, also set the
editor text. Modify `applyLoadedMarkdown(_:fileURL:)` to also update the editor:

After the existing `renderCurrentDocument` call, add:
```swift
(documentWindow.contentViewController as? MainSplitViewController)?.setEditorText(text)
```

And in `display(markdown:fileURL:)`, after the existing `renderCurrentDocument` call:
```swift
(documentWindow.contentViewController as? MainSplitViewController)?.setEditorText(markdown)
```

#### D) Add toolbar item for edit toggle

Add `.editToggle` to `toolbarDefaultItemIdentifiers`:
Insert it after `.openActions` and before `.space`:
```swift
.openActions,
.editToggle,
.space,
```

Add `.editToggle` to `toolbarAllowedItemIdentifiers` as well.

Add the case in `toolbar(_:itemForItemIdentifier:willBeInsertedIntoToolbar:)`:
```swift
case .editToggle: return makeEditToggleItem()
```

Create the edit toggle toolbar item:
```swift
private weak var editToggleButton: NSButton?

private func makeEditToggleItem() -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: .editToggle)
    item.label = "Edit"
    item.paletteLabel = "Edit"
    item.toolTip = "Toggle source editor (⌘E)"

    let image = NSImage(systemSymbolName: "pencil.line",
                        accessibilityDescription: "Edit") ?? NSImage()
    image.isTemplate = true

    let button = NSButton(image: image,
                          target: self,
                          action: #selector(toggleEditorAction(_:)))
    button.setButtonType(.pushOnPushOff)
    button.bezelStyle = .toolbar
    button.toolTip = item.toolTip
    button.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(button)
    NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
        button.topAnchor.constraint(equalTo: container.topAnchor),
        button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
        button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        button.heightAnchor.constraint(equalToConstant: 32),
        container.widthAnchor.constraint(equalToConstant: 36),
        container.heightAnchor.constraint(equalToConstant: 32)
    ])

    item.view = container
    editToggleButton = button
    refreshEditToggleItem()
    return item
}

@objc private func toggleEditorAction(_ sender: Any) {
    let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
        .toggleEditor() ?? false
    setEditToggleSelected(isVisible)
    // If showing editor, populate it with current markdown
    if isVisible, let markdown = currentMarkdown {
        (documentWindow.contentViewController as? MainSplitViewController)?
            .setEditorText(markdown)
    }
}

private func refreshEditToggleItem() {
    let isVisible = (documentWindow.contentViewController as? MainSplitViewController)?
        .isEditorVisible ?? false
    setEditToggleSelected(isVisible)
}

private func setEditToggleSelected(_ isSelected: Bool) {
    editToggleButton?.state = isSelected ? .on : .off
}
```

#### E) Add ⌘E keyboard shortcut

In the AppDelegate (but actually, since we're not modifying AppDelegate, handle this in
DocumentWindowController). Override `keyDown(with:)` or better, add a menu item with ⌘E.

Actually, the cleanest approach: Add a menu item via the app's main menu for "Toggle Editor"
with ⌘E. But since we're not modifying AppDelegate's menu setup... The alternative is to
handle it in `performKeyEquivalent` on the window controller.

Simpler approach: Don't add the keyboard shortcut in this phase. The toolbar button is sufficient.
The shortcut can be added in a follow-up by adding a View menu item in AppDelegate.

#### F) FileWatcher conflict handling

In the existing `startWatching(_:)` method, the `FileWatcher` callback currently calls
`self.loadFile(at: url, silentOnFailure: true)` unconditionally. Modify this to check if the
document has unsaved changes:

Change the watcher callback in `startWatching(_:)` from:
```swift
let watcher = FileWatcher(url: url) { [weak self] in
    guard let self, self.currentFileURL == url else { return }
    self.loadFile(at: url, silentOnFailure: true)
}
```

To:
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

Add the alert method:
```swift
private func showExternalChangeAlert(fileURL: URL) {
    let alert = NSAlert()
    alert.messageText = "File Modified Externally"
    alert.informativeText = "\"\(fileURL.lastPathComponent)\" has been modified by another application. Do you want to keep your changes or reload from disk?"
    alert.addButton(withTitle: "Keep My Changes")
    alert.addButton(withTitle: "Reload from Disk")
    alert.alertStyle = .warning
    alert.beginSheetModal(for: documentWindow) { [weak self] response in
        if response == .alertSecondButtonReturn {
            self?.loadFile(at: fileURL, silentOnFailure: true)
        }
    }
}
```

## IMPORTANT constraints

- Modify ONLY `md-preview/MainSplitViewController.swift` and `md-preview/DocumentWindowController.swift`
- Do NOT modify any other files
- The EditorViewController class already exists (created by another agent) — just reference it
- The MarkdownDocument.setMarkdown(_:) method already exists (created by another agent)
- Match existing code style: use `// MARK: -` sections, `@objc` for selectors, `weak` references
  for toolbar items, same constraint patterns as existing toolbar items
- Target macOS 15.0+, Swift 6.x compatible
- The existing `renderCurrentDocument(text:fileURL:)` method in DocumentWindowController is the
  right hook for re-rendering — use it

## Verification

After making changes, verify:
1. All existing methods still exist and function (don't accidentally delete anything)
2. The new editor pane is added at index 1 in the split view
3. The toolbar has the edit toggle button
4. Data flows: editor text change → document dirty + preview re-render
5. File load → editor text set (without triggering re-render loop)
6. FileWatcher shows conflict alert when document has unsaved changes

When done, write RESULT.json at the repo root:
```json
{"status":"ok","files":["md-preview/MainSplitViewController.swift","md-preview/DocumentWindowController.swift"],"notes":"Integration complete: editor pane added to split view at index 1 (starts collapsed), edit toggle toolbar button with pencil.line icon, data flow wired (editor→document→preview, file load→editor), FileWatcher conflict handling added."}
```
