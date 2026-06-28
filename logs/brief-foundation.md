# Agent Brief: Foundation (Entitlements + Info.plist + MarkdownDocument)

## Context

You are working on a macOS AppKit app called "Markdown Preview" (bundle id: `doc.md-preview`).
It currently is a **read-only viewer** for Markdown files. We are adding editing support.

Your task is to modify three files to transform the document model from "viewer" to "editor".

## Repo layout
- `md-preview/md-preview.entitlements` — sandbox entitlements
- `Info.plist` — app metadata, document types, UTI declarations
- `md-preview/MarkdownDocument.swift` — NSDocument subclass (the document model)

## Files you MUST modify (and ONLY these files)

### 1. `md-preview/md-preview.entitlements`

Change the file-access entitlement from read-only to read-write:

Replace this key:
```xml
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

With:
```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

Leave ALL other entitlements unchanged (sandbox, apple-events, network.client, print, temporary-exception for read-only filesystem, mach-lookup for Sparkle).

### 2. `Info.plist`

Change CFBundleTypeRole from "Viewer" to "Editor":

Find this line:
```xml
<string>Viewer</string>
```
(It's inside the CFBundleDocumentTypes → first dict → CFBundleTypeRole)

Change it to:
```xml
<string>Editor</string>
```

Leave ALL other Info.plist content unchanged.

### 3. `md-preview/MarkdownDocument.swift`

This is the most substantial change. The current file is a read-only NSDocument subclass.
You need to transform it into an editable document model.

Here is the CURRENT content of MarkdownDocument.swift:

```swift
//
//  MarkdownDocument.swift
//  md-preview
//

import Cocoa
import Synchronization

final class MarkdownDocument: NSDocument {

    private nonisolated let markdownStorage = Mutex("")
    private nonisolated let folderStorage = Mutex<URL?>(nil)

    var markdown: String {
        markdownStorage.withLock { $0 }
    }

    private var folderURL: URL? {
        folderStorage.withLock { $0 }
    }

    override init() {
        super.init()
        hasUndoManager = false
    }

    override nonisolated class var autosavesInPlace: Bool {
        false
    }

    override var isDocumentEdited: Bool {
        false
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        if let folderURL {
            controller.display(markdown: "", fileURL: nil)
            controller.openFolder(folderURL)
            return
        }
        controller.display(markdown: markdown, fileURL: fileURL)
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        if url.isExistingDirectory {
            folderStorage.withLock { $0 = url.standardizedFileURL }
            markdownStorage.withLock { $0 = "" }
            return
        }

        let data = try Data(contentsOf: url)
        try read(from: data, ofType: typeName)
    }

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        folderStorage.withLock { $0 = nil }
        markdownStorage.withLock { $0 = text }
    }

    override nonisolated func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.fileWriteNoPermission)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(save(_:)),
             #selector(saveAs(_:)),
             #selector(saveTo(_:)),
             #selector(revertToSaved(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    func replaceContents(markdown: String, fileURL: URL) {
        markdownStorage.withLock { $0 = markdown }
        replaceFileURL(fileURL)
    }

    func replaceFileURL(_ fileURL: URL) {
        self.fileURL = fileURL
        updateChangeCount(.changeCleared)
    }
}
```

Here is what the NEW MarkdownDocument.swift should do:

1. **Enable undo**: Change `hasUndoManager = false` to `hasUndoManager = true`

2. **Remove hardcoded `isDocumentEdited`**: Delete the override that always returns `false`. Let NSDocument's default change-tracking work.

3. **Enable save**: Replace `data(ofType:)` so it returns the markdown encoded as UTF-8 data instead of throwing:
```swift
override nonisolated func data(ofType typeName: String) throws -> Data {
    let text = markdownStorage.withLock { $0 }
    guard let data = text.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}
```

4. **Enable autosaves in place**: Change `autosavesInPlace` to return `true` for modern macOS behavior.

5. **Remove save-blocking validation**: Remove the `validateUserInterfaceItem` override that disables Save/SaveAs/Revert. Delete the entire method.

6. **Add `setMarkdown(_:)` method**: Add a new method that the editor pane will call when text changes. It updates the stored markdown and marks the document as dirty:
```swift
func setMarkdown(_ newText: String) {
    markdownStorage.withLock { $0 = newText }
    updateChangeCount(.changeDone)
}
```

7. **Keep everything else**: The `read(from:)` methods, `makeWindowControllers()`, `replaceContents(markdown:fileURL:)`, `replaceFileURL(_:)`, the `markdown` computed property, `folderURL`, `folderStorage`, `markdownStorage` — all stay as-is.

## IMPORTANT: Do NOT modify any other files. Only touch the three files listed above.

## Verification

After making changes, verify the entitlements file is valid XML and MarkdownDocument.swift compiles conceptually (no syntax errors, proper Swift syntax).

When done, write RESULT.json at the repo root:
```json
{"status":"ok","files":["md-preview/md-preview.entitlements","Info.plist","md-preview/MarkdownDocument.swift"],"notes":"Foundation changes complete: entitlements upgraded to read-write, Info.plist role changed to Editor, MarkdownDocument transformed to support editing with undo, save, and setMarkdown."}
```
