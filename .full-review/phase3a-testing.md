# Phase 3a — Test Coverage Review: Editing Feature

**Branch:** `feat/add-editing-support`  
**Diff base:** `7fc5aa2`  
**Reviewer role:** Swift/XCTest coverage analyst  

---

## Executive Summary

**Zero test changes shipped with the editing feature.** The diff adds 482 lines of new production
code across five files — two entirely new (`EditorViewController`, `MarkdownSyntaxHighlighter`) and
three significantly changed — but `git diff 7fc5aa2..HEAD -- tests/` produces no output. Every
critical code path in the editing layer is completely uncovered. The existing SPM test harness
(`tests/swift-tests/`) only reaches pure-Foundation helpers symlinked from the app; AppKit-tier code
is structurally excluded from it and would require a separate Xcode unit-test target.

---

## Test Infrastructure Baseline

| Target | Files | What it tests | AppKit? |
|--------|-------|---------------|---------|
| `MarkdownHelpersTests` | `CodeFenceInfoTests`, `EscapingHTMLFormatterTests`, `MarkdownFrontmatterTests` | Pure string parsing | No |
| `QuickLookHelperTests` | `InlineLocalAssetsTests` | Asset inlining logic | No |

Existing tests are **behavior-oriented, mock-free, and correct in style** — they feed raw input and
assert observable output, never internal state. That discipline should be applied to the new code.

The SPM package compiles sources via symlinks (`Sources/<Target>/` → real app files). Adding an
AppKit-dependent target here would require macOS-only conditional compilation. The cleaner path is
a new **Xcode unit-test target** (`md-preview-tests`) that can `import` the main app module with
`@testable`.

---

## Findings

### F-01 — `MarkdownSyntaxHighlighter` is entirely untested

**Severity: Critical**

228 lines of new highlighting logic, zero tests. The highlighter fires on every keystroke; a subtle
correctness or safety bug (off-by-one in NSRange, fence scanner stuck in `inFence`, regex applied
inside a protected range) will corrupt user text silently in production. There is also no performance
baseline, meaning regressions in the 25–66 ms/keystroke range reported by prior phases will go
undetected.

**What is untested:**

| Code path | Risk |
|-----------|------|
| `applyHighlighting(to:)` baseline reset + 8 pattern applications | Full-document corrupt-on-edit |
| `highlightCodeFences(in:string:)` fence scanner state machine | Unterminated fence consumes rest of document |
| Fence with tilde delimiter (`~~~`) | Delimiter mismatch closes never |
| Nested inline code inside bold (`**a \`b\` c**`) | Highlight applied inside protected range |
| `intersectsProtected(_:protected:)` O(M×K) scan | No correctness test for the guard logic |
| Per-call `NSRegularExpression` construction in `applyPattern` | Compilation cost undetected |
| Empty document (`length == 0`) early-return | Guard branch never exercised |

**Recommended tests:**

```swift
// Tests/md-preview-tests/MarkdownSyntaxHighlighterTests.swift

import XCTest
@testable import md_preview

final class MarkdownSyntaxHighlighterTests: XCTestCase {

    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text)
    }

    private func highlight(_ text: String) -> NSTextStorage {
        let s = storage(text)
        MarkdownSyntaxHighlighter().applyHighlighting(to: s)
        return s
    }

    private func color(in s: NSTextStorage, at index: Int) -> NSColor? {
        var r = NSRange()
        return s.attribute(.foregroundColor, at: index, effectiveRange: &r) as? NSColor
    }

    // --- Baseline reset ---

    func testEmptyDocumentDoesNotCrash() {
        // Must not crash or throw; the guard-length-0 branch is the only path taken.
        XCTAssertNoThrow(highlight(""))
    }

    func testBaselineResetClearsExistingAttributes() {
        let s = storage("# Heading")
        s.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 9))
        MarkdownSyntaxHighlighter().applyHighlighting(to: s)
        // After reset+heading pass the color must be headingColor (.systemBlue), not .red.
        XCTAssertNotEqual(color(in: s, at: 0), NSColor.red)
    }

    // --- Headings ---

    func testHeadingColorApplied() {
        let s = highlight("# Hello World\n")
        XCTAssertEqual(color(in: s, at: 0), NSColor.systemBlue, "H1 must be blue")
    }

    func testH1ThroughH6AreAllHighlighted() {
        for n in 1...6 {
            let prefix = String(repeating: "#", count: n) + " Heading\n"
            let s = highlight(prefix)
            XCTAssertEqual(color(in: s, at: 0), NSColor.systemBlue, "H\(n) not highlighted")
        }
    }

    // --- Code fences: correctness ---

    func testBacktickFenceProtectsContents() {
        let md = "```\n**not bold**\ncode here\n```\n"
        let s = highlight(md)
        // "**not bold**" inside fence must NOT get bold color; it should be codeColor.
        let fenceContentOffset = 4 // first char after opening fence line
        XCTAssertEqual(color(in: s, at: fenceContentOffset), NSColor.systemGreen)
    }

    func testTildeFenceRecognized() {
        let md = "~~~\n**not bold**\n~~~\n"
        let s = highlight(md)
        XCTAssertEqual(color(in: s, at: 4), NSColor.systemGreen, "tilde fence not recognized")
    }

    func testUnterminatedFenceConsumesRemainingDocumentAsCode() {
        // Fence opened but never closed: everything after the opener must be code-colored.
        let md = "```\nsome code\nmore code\n"
        let s = highlight(md)
        XCTAssertEqual(color(in: s, at: 4), NSColor.systemGreen)
        XCTAssertEqual(color(in: s, at: 14), NSColor.systemGreen)
    }

    func testFenceCloserMustMatchOpenerLength() {
        // ````code```` opened with 4 backticks must not close on ``` (3 backticks).
        let md = "````\ncode\n```\nstill code\n````\n"
        let s = highlight(md)
        // "still code" must still be codeColor (not baseColor).
        let stillCodeOffset = md.distance(from: md.startIndex,
                                          to: md.range(of: "still code")!.lowerBound)
        XCTAssertEqual(color(in: s, at: stillCodeOffset), NSColor.systemGreen)
    }

    func testInlineCodeInsideFenceNotDoubleHighlighted() {
        // `backtick` pattern inside a fenced block must not override the code style.
        let md = "```\n`inline`\n```\n"
        let s = highlight(md)
        let inlineOffset = md.distance(from: md.startIndex,
                                       to: md.range(of: "`inline`")!.lowerBound)
        // Must still be systemGreen (code fence), not a different shade.
        XCTAssertEqual(color(in: s, at: inlineOffset), NSColor.systemGreen)
    }

    // --- Inline code ---

    func testInlineCodeGetsCodeColor() {
        let s = highlight("Use `foo` here\n")
        let offset = 4 // 'f' in `foo`
        XCTAssertEqual(color(in: s, at: offset), NSColor.systemGreen)
    }

    // --- Bold / italic ---

    func testBoldInnerRangeGetsBoldFont() {
        let s = highlight("**bold text**\n")
        var r = NSRange()
        let font = s.attribute(.font, at: 2, effectiveRange: &r) as? NSFont
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
    }

    func testItalicColorApplied() {
        let s = highlight("*italic text*\n")
        XCTAssertEqual(color(in: s, at: 1), NSColor.secondaryLabelColor)
    }

    // --- Links ---

    func testLinkGetsUnderlineAttribute() {
        let s = highlight("[label](https://example.com)\n")
        var r = NSRange()
        let underline = s.attribute(.underlineStyle, at: 1, effectiveRange: &r) as? Int
        XCTAssertNotNil(underline, "link must carry underlineStyle")
    }

    // --- Performance regression gate ---

    func testHighlightingLargeDocumentCompletesWithinFrameBudget() {
        // Generate a 10 000-line document (~600 KB) with varied syntax.
        var lines: [String] = []
        for i in 1...500 {
            lines += [
                "# Heading \(i)",
                "Paragraph with **bold** and *italic* and `code` and [link](http://x.com).",
                "> blockquote line",
                "```swift\nlet x = \(i)\n```",
                "- list item \(i)",
                "",
            ]
        }
        let md = lines.joined(separator: "\n")
        let s = storage(md)
        let highlighter = MarkdownSyntaxHighlighter()

        let start = Date()
        highlighter.applyHighlighting(to: s)
        let elapsed = Date().timeIntervalSince(start) * 1000

        // Budget: 16 ms per frame. A 600 KB doc exceeds what a single keystroke should
        // produce, but the highlighter should still finish under 100 ms to avoid
        // visible hangs even on large files.
        XCTAssertLessThan(elapsed, 100, "highlighting \(md.count) bytes took \(elapsed) ms")
    }
}
```

---

### F-02 — `EditorViewController` debounce contract is untested

**Severity: Critical**

The debounce/`isSettingText` interlock is the load-bearing mechanism that prevents render loops and
editor data-loss. Neither the guard (`isSettingText` suppresses callback) nor the 200 ms debounce
semantics are tested. Without a test:

- Any refactor that changes the flag name or timing breaks the loop prevention silently.
- The data-loss window (debounce in flight when `setMarkdown` overwrites `textView.string`) is
  invisible to CI.

**What is untested:**

| Code path | Risk |
|-----------|------|
| `setMarkdown(_:)` — `isSettingText` suppresses `onTextChange` | Render loop on file load |
| `textDidChange` → debounce fires → `onTextChange` called once, not per-keypress | Thrash |
| Rapid successive edits cancel prior work item | Multiple callbacks instead of one |
| `setMarkdown` called while debounce is in flight → text overwritten, callback never fires | Data loss |
| `currentText` when `textView` not yet loaded | Crash / empty-string contract |

**Recommended tests:**

```swift
// Tests/md-preview-tests/EditorViewControllerTests.swift
//
// NOTE: NSTextView requires a real NSWindow to process text changes.
// Host the VC in a borderless off-screen window.

import XCTest
@testable import md_preview

@MainActor
final class EditorViewControllerTests: XCTestCase {

    private func makeEditorInWindow() -> EditorViewController {
        let vc = EditorViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
        _ = vc.view // force loadView
        return vc
    }

    // setMarkdown must NOT fire onTextChange (prevents render loops on file load).
    func testSetMarkdownSuppressesCallback() {
        let vc = makeEditorInWindow()
        var callbackCount = 0
        vc.onTextChange = { _ in callbackCount += 1 }

        vc.setMarkdown("# Hello")

        // Give the run loop a tick; debounce delay is 0.2 s.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(callbackCount, 0,
                       "setMarkdown must not trigger onTextChange to prevent render loops")
    }

    // Programmatic text must be reflected in currentText immediately.
    func testSetMarkdownUpdatesCurrentText() {
        let vc = makeEditorInWindow()
        vc.setMarkdown("hello world")
        XCTAssertEqual(vc.currentText, "hello world")
    }

    // Debounce: rapid keystrokes produce exactly one callback after the delay.
    func testDebounceCoalescesRapidEdits() {
        let vc = makeEditorInWindow()
        var receivedTexts: [String] = []
        vc.onTextChange = { receivedTexts.append($0) }

        // Simulate 5 rapid keystrokes via textStorage editing.
        let storage = vc.view.subviews.compactMap { $0 as? NSScrollView }
                        .first?.documentView as? NSTextView
        guard let textView = storage else {
            XCTFail("NSTextView not found in EditorViewController hierarchy")
            return
        }

        for i in 1...5 {
            textView.string = "edit \(i)"
            // Manually fire the delegate to simulate typing.
            vc.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
        }

        // Wait for the debounce to fire (debounceDelay = 0.2 s → wait 0.4 s).
        let expectation = expectation(description: "debounce fires once")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(receivedTexts.count, 1,
                       "debounce must coalesce rapid edits into one callback, got \(receivedTexts)")
        XCTAssertEqual(receivedTexts.first, "edit 5")
    }

    // setMarkdown while debounce is in flight must not overwrite with stale text.
    // This reproduces the data-loss window noted in prior phase findings.
    func testSetMarkdownWhileDebounceInFlightDoesNotFireCallback() {
        let vc = makeEditorInWindow()
        var receivedTexts: [String] = []
        vc.onTextChange = { receivedTexts.append($0) }

        guard let textView = (vc.view as? NSScrollView)?.documentView as? NSTextView else {
            XCTFail("NSTextView not found"); return
        }

        // Simulate a user edit that starts the debounce timer.
        textView.string = "user typed this"
        vc.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))

        // Before the 0.2 s debounce fires, a file-reload calls setMarkdown.
        vc.setMarkdown("file content from disk")

        let exp = expectation(description: "wait past debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        // The cancelled debounce work item must not fire the callback.
        XCTAssertEqual(receivedTexts.count, 0,
                       "stale debounce callback fired after setMarkdown overwrite — data loss")
        XCTAssertEqual(vc.currentText, "file content from disk",
                       "setMarkdown must win; editor must show file content")
    }
}
```

---

### F-03 — `MarkdownDocument` data-layer changes are untested

**Severity: Critical**

The document went from read-only (write threw `.fileWriteNoPermission`) to writable. `data(ofType:)`
now encodes the mutex-protected string and is called by NSDocument's autosave machinery. Three
correctness invariants have no tests:

1. `setMarkdown` + `data(ofType:)` round-trip: what goes in comes back out as UTF-8.
2. `isDocumentEdited` transitions: `updateChangeCount(.changeDone)` after `setMarkdown` vs
   `.changeCleared` after `replaceFileURL`.
3. `read(from:data:ofType:)` rejects non-UTF-8 bytes with `.fileReadCorruptFile`.

**Recommended tests:**

```swift
// Tests/md-preview-tests/MarkdownDocumentTests.swift

import XCTest
@testable import md_preview

final class MarkdownDocumentTests: XCTestCase {

    // data(ofType:) must return the same bytes that were stored via setMarkdown.
    func testDataRoundTrip() throws {
        let doc = MarkdownDocument()
        let original = "# Hello\n\nParagraph with **bold**."
        doc.setMarkdown(original)
        let data = try doc.data(ofType: "net.daringfireball.markdown")
        let recovered = String(data: data, encoding: .utf8)
        XCTAssertEqual(recovered, original)
    }

    // data(ofType:) on a freshly-initialised document (empty string) must not throw.
    func testDataForEmptyDocumentDoesNotThrow() {
        let doc = MarkdownDocument()
        XCTAssertNoThrow(try doc.data(ofType: "net.daringfireball.markdown"))
    }

    // read(from:data:ofType:) rejects non-UTF-8 bytes.
    func testReadFromNonUTF8DataThrows() {
        let doc = MarkdownDocument()
        // 0xFF 0xFE is a UTF-16 BOM, invalid UTF-8 sequence.
        let bad = Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])
        XCTAssertThrowsError(try doc.read(from: bad, ofType: "net.daringfireball.markdown")) { error in
            let cocoaError = error as? CocoaError
            XCTAssertEqual(cocoaError?.code, .fileReadCorruptFile)
        }
    }

    // setMarkdown must mark the document as edited.
    func testSetMarkdownMarksDocumentEdited() {
        let doc = MarkdownDocument()
        // Baseline: freshly created document is not edited.
        XCTAssertFalse(doc.isDocumentEdited)
        doc.setMarkdown("some text")
        XCTAssertTrue(doc.isDocumentEdited,
                      "setMarkdown must call updateChangeCount(.changeDone)")
    }

    // replaceFileURL must clear the edited flag.
    func testReplaceFileURLClearsEditedFlag() {
        let doc = MarkdownDocument()
        doc.setMarkdown("edited")
        XCTAssertTrue(doc.isDocumentEdited)
        doc.replaceFileURL(URL(fileURLWithPath: "/tmp/test.md"))
        XCTAssertFalse(doc.isDocumentEdited,
                       "replaceFileURL must call updateChangeCount(.changeCleared)")
    }

    // replaceContents stores markdown and clears the edited flag atomically.
    func testReplaceContentsStoresTextAndClearsFlag() throws {
        let doc = MarkdownDocument()
        doc.setMarkdown("old text")
        doc.replaceContents(markdown: "new text", fileURL: URL(fileURLWithPath: "/tmp/new.md"))
        XCTAssertEqual(doc.markdown, "new text")
        XCTAssertFalse(doc.isDocumentEdited)
    }
}
```

> **Note:** `isDocumentEdited` is managed by NSDocument's `changeCount` machinery. These tests will
> require an Xcode test target (not the current SPM package) because `NSDocument` is AppKit-dependent.

---

### F-04 — FileWatcher / autosave race is untested

**Severity: Critical** (security + correctness)

`startWatching` now branches on `markdownDocument?.isDocumentEdited`. The autosave path sets
`isDocumentEdited` to `false` asynchronously after saving. If the FileWatcher event fires while
autosave is writing, `isDocumentEdited` may be `false` even though the user has unsaved changes —
the alert is skipped and the file reloads, silently discarding the edit.

No test exercises either branch of the new conditional.

**Recommended tests:**

```swift
// Tests/md-preview-tests/FileWatcherConflictTests.swift

import XCTest
@testable import md_preview

// These are integration-style tests. They require a DocumentWindowController
// backed by a real file in /tmp. The test creates the file, loads it into
// a controller, then overwrites the file on disk and verifies alert / reload behavior.
//
// Annotation: these tests are inherently timing-sensitive due to DispatchSource;
// use generous timeouts and XCTestExpectation.

@MainActor
final class FileWatcherConflictTests: XCTestCase {

    private var tmpURL: URL!

    override func setUp() async throws {
        tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-\(UUID().uuidString).md")
        try "# Initial content".write(to: tmpURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpURL!)
    }

    // When the document is unedited, external changes must trigger a silent reload.
    func testExternalChangeWhenUneditedReloadsFile() throws {
        // Load document, verify initial state.
        let doc = try MarkdownDocument(contentsOf: tmpURL, ofType: "net.daringfireball.markdown")
        XCTAssertFalse(doc.isDocumentEdited)

        // Simulate the FileWatcher callback path directly:
        // isDocumentEdited == false → must silently reload, NOT show alert.
        // We can test the guard directly without a running window.
        let shouldAlert = doc.isDocumentEdited
        XCTAssertFalse(shouldAlert, "unedited document must not trigger conflict alert")
    }

    // When the document has unsaved edits, external changes must trigger the alert.
    func testExternalChangeWhenEditedTriggersAlert() {
        let doc = MarkdownDocument()
        doc.setMarkdown("user typed this")
        XCTAssertTrue(doc.isDocumentEdited,
                      "edited document must trigger conflict alert branch")
    }

    // After "Keep My Changes" (dismiss), document text must be unchanged.
    // After "Reload from Disk" (accept), document text must reflect disk content.
    //
    // These require UI-level testing (NSAlert cannot be driven headlessly).
    // At minimum, unit-test showExternalChangeAlert's response-dispatch logic
    // by making it injectable:
    //
    //   func testKeepMyChangesPreservesText() { … }
    //   func testReloadFromDiskLoadsFileContent() { … }
    //
    // The current implementation inlines alert creation in the DWC — refactor
    // to accept a `conflictResolver: (DocumentConflictResponse) -> Void` closure
    // so the response can be injected in tests without a window.
}
```

> **Architectural note (testability gap):** `showExternalChangeAlert` is an untestable private
> method because it creates `NSAlert` directly and calls `beginSheetModal(for:)`. To make the alert
> path unit-testable, extract the decision logic:
>
> ```swift
> enum ConflictResolution { case keepChanges, reloadFromDisk }
> typealias ConflictResolver = (ConflictResolution) -> Void
>
> // Inject in tests; use the real NSAlert in production.
> var conflictResolverFactory: (@escaping ConflictResolver) -> Void = { handler in
>     // ... NSAlert.beginSheetModal ...
> }
> ```

---

### F-05 — Panel toggle / debounce data-loss window is untested

**Severity: High**

Prior phase analysis identified that toggling the editor panel off while a debounce is in flight,
then toggling it back on, causes `setEditorText` to overwrite the editor with `currentMarkdown`
(pre-edit). The 200 ms debounce window is the exact window of data loss. No test covers this
sequence.

**Recommended test:**

```swift
func testPanelToggleDuringDebounceDoesNotDiscardEdit() {
    // 1. Load document with "original text"
    // 2. User types "edited text" → debounce starts (0.2 s)
    // 3. Within 0.1 s: toggle editor off → toggle editor on
    //    → toggleEditorAction calls setEditorText(currentMarkdown)
    //    → currentMarkdown is still "original text" (debounce hasn't fired yet)
    // 4. After 0.3 s: assert editor shows "edited text", not "original text"
    //
    // Expected result: FAIL on current code (this is a known bug).
    // The test documents the regression until the race is fixed.
}
```

---

### F-06 — `MainSplitViewController` index-based pane access is fragile and untested

**Severity: High**

The refactor changed `contentViewController` from a type-cast-of-first to index `[2]`. The property
is now:

```swift
private var contentViewController: ContentViewController? {
    guard splitViewItems.count > 2 else { return nil }
    return splitViewItems[2].viewController as? ContentViewController
}
```

`editorViewController` is `splitViewItems.dropFirst().first`, which is index `[1]`. Both of these
silent-fail (`return nil`) if items are inserted in a different order. Since
`viewDidAppear` accesses `splitViewItems[1]` by raw index, a one-line reorder in `viewDidLoad`
silently breaks the entire content rendering path with no test catching it.

**Recommended tests:**

```swift
@MainActor
final class MainSplitViewControllerTests: XCTestCase {

    func testSplitItemCountAfterViewDidLoad() {
        let vc = MainSplitViewController()
        _ = vc.view // force viewDidLoad
        XCTAssertEqual(vc.splitViewItems.count, 4,
                       "sidebar + editor + content + inspector = 4 items")
    }

    func testContentViewControllerIsAtIndexTwo() {
        let vc = MainSplitViewController()
        _ = vc.view
        let item = vc.splitViewItems[2]
        XCTAssertTrue(item.viewController is ContentViewController,
                      "index 2 must be ContentViewController")
    }

    func testEditorViewControllerIsAtIndexOne() {
        let vc = MainSplitViewController()
        _ = vc.view
        let item = vc.splitViewItems[1]
        XCTAssertTrue(item.viewController is EditorViewController,
                      "index 1 must be EditorViewController")
    }

    func testEditorStartsCollapsed() {
        let vc = MainSplitViewController()
        _ = vc.view
        // Editor pane must start collapsed (Preview-mode default).
        XCTAssertTrue(vc.splitViewItems[1].isCollapsed,
                      "editor must start collapsed on first launch")
    }

    func testToggleEditorReturnsVisibilityState() {
        let vc = MainSplitViewController()
        _ = vc.view
        let wasVisible = !vc.splitViewItems[1].isCollapsed
        let result = vc.toggleEditor()
        XCTAssertEqual(result, !wasVisible, "toggleEditor must return new visibility state")
    }

    func testSetMarkdownDoesNotFireEditorCallback() {
        let vc = MainSplitViewController()
        _ = vc.view
        var callbackFired = false
        vc.onEditorTextChange = { _ in callbackFired = true }

        vc.display(markdown: "# Test", fileName: "test.md", url: nil, assetBaseURL: nil,
                   updateEditor: true)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(callbackFired, "display() must not fire onEditorTextChange")
    }
}
```

---

### F-07 — Existing tests: regression risk from viewer→editor transition

**Severity: Medium**

No existing test touches any of the changed files. The regression risk from the diff is therefore
not test breakage but **silent functional regression**:

| Changed code | Regression risk (no test catches it) |
|---|---|
| `MarkdownDocument.data(ofType:)` now returns bytes | Autosave writes empty file if `markdownStorage` is `""` at save time |
| `hasUndoManager = true` | NSDocument undo stack may record `read(from:data:)` as undoable, allowing Cmd+Z to clear the document to empty |
| `contentViewController` is now `splitViewItems[2]` | All display/render calls silently no-op if pane order shifts |
| `updateEditor: Bool = true` default in `display()` | Any call site that passes no `updateEditor:` argument now also sets editor text — this is new behavior |

**Specific regression test needed:**

```swift
// Verify that display() with updateEditor:false leaves the editor text unchanged.
func testDisplayWithUpdateEditorFalseDoesNotOverwriteEditor() {
    let vc = MainSplitViewController()
    _ = vc.view
    vc.setEditorText("user is editing this")

    // Render loop calls display with updateEditor: false.
    vc.display(markdown: "server-refreshed content", fileName: "f.md", url: nil,
               assetBaseURL: nil, updateEditor: false)

    XCTAssertEqual(vc.splitViewItems[1].viewController.map { ($0 as? EditorViewController)?.currentText },
                   .some(.some("user is editing this")),
                   "updateEditor:false must not overwrite in-progress editor text")
}
```

---

### F-08 — No performance benchmark gate

**Severity: High**

The performance reviewer identified 25–66 ms/keystroke for full-document highlighting and 1.2–3.6 ms
for per-call regex compilation. Neither figure has a corresponding XCTest performance test. Without a
benchmark gate, any optimization regression is invisible to CI.

**Recommended benchmark:**

```swift
func testHighlightingPerformanceSmallDoc() {
    let md = """
    # Heading
    Paragraph with **bold**, *italic*, `code`, and [link](http://x.com).
    > blockquote
    ```swift
    let x = 42
    ```
    - item one
    - item two
    """
    let s = NSTextStorage(string: String(repeating: md + "\n", count: 100))
    let highlighter = MarkdownSyntaxHighlighter()

    measure {
        highlighter.applyHighlighting(to: s)
    }
    // XCTest `measure` records mean time; assert via maxMetrics if needed.
}

func testHighlightingPerformanceLargeDoc() {
    // 50 000 characters — roughly a 1 000-line document.
    let md = String(repeating: "# Heading\n**bold** and `code`\n", count: 1_667)
    let s = NSTextStorage(string: md)
    let highlighter = MarkdownSyntaxHighlighter()

    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
        highlighter.applyHighlighting(to: s)
    }
}
```

---

### F-09 — Edge cases with empty/huge documents and rapid typing

**Severity: Medium**

| Edge case | Status |
|---|---|
| Empty document (`""`) passed to `setMarkdown` | `applyHighlighting` exits early (guard), but `textView.string = ""` is unchecked |
| 10 MB file loaded into editor | `textView.string = largeText` on main thread; no background loading; untested |
| Rapid typing (< 20 ms between keystrokes) | Debounce coalesces, but `applyHighlighting` fires synchronously per-keystroke regardless |
| Document that is all one fence (no closing backticks) | Fence scanner loops entire document; untested |
| Non-ASCII content (CJK, emoji, RTL text) | `NSRange` vs Swift `String.Index` mismatches in pattern matching are common failure points; untested |

**Recommended tests:**

```swift
func testSetMarkdownWithEmptyStringDoesNotCrash() {
    let vc = makeEditorInWindow()
    XCTAssertNoThrow(vc.setMarkdown(""))
    XCTAssertEqual(vc.currentText, "")
}

func testHighlightingWithEmojiDoesNotCorruptNSRange() {
    // NSString character semantics (UTF-16) vs Swift Unicode semantics (extended grapheme clusters).
    let md = "# 🎉 Heading\n**bold 🚀 text**\n"
    XCTAssertNoThrow(highlight(md))
    let s = highlight(md)
    // Heading color must start at index 0 (the '#'), not be misaligned by the emoji.
    XCTAssertEqual(color(in: s, at: 0), NSColor.systemBlue)
}

func testHighlightingWithRTLTextDoesNotCrash() {
    let md = "# عنوان\n**نص غامق**\n"
    XCTAssertNoThrow(highlight(md))
}
```

---

## Summary Table

| ID | Severity | Untested area | Primary fix |
|----|----------|---------------|-------------|
| F-01 | **Critical** | `MarkdownSyntaxHighlighter` — all 228 lines | Add `MarkdownSyntaxHighlighterTests` Xcode target |
| F-02 | **Critical** | `EditorViewController` debounce / `isSettingText` interlock | Add `EditorViewControllerTests` Xcode target |
| F-03 | **Critical** | `MarkdownDocument` writable data path, edit-flag transitions | Add `MarkdownDocumentTests` Xcode target |
| F-04 | **Critical** | FileWatcher / autosave race, alert branch logic | Add `FileWatcherConflictTests`, refactor alert to injectable |
| F-05 | **High** | Panel toggle during debounce → editor text overwritten | Confirm bug first, then add regression test |
| F-06 | **High** | `MainSplitViewController` index-based pane contract | Add `MainSplitViewControllerTests` |
| F-07 | **Medium** | Regression from viewer→editor transition (autosave write, undo) | Add targeted regression tests for `data(ofType:)` and index access |
| F-08 | **High** | No performance benchmark for highlighting | Add `measure {}` test; gate on 100 ms max for large docs |
| F-09 | **Medium** | Empty doc, emoji/CJK/RTL content, huge files | Add edge-case tests in `MarkdownSyntaxHighlighterTests` |

---

## Infrastructure Prerequisite

The current `tests/swift-tests` SPM package cannot host any of the above tests because it is
explicitly Foundation-only. All new tests require **AppKit** (`NSTextStorage`, `NSTextView`,
`NSDocument`, `NSSplitViewController`). The correct fix:

1. Add a new **Xcode unit-test target** `md-preview-tests` to `md-preview.xcodeproj`.
2. Link it against the main app target with `@testable import md_preview`.
3. Add a CI step: `xcodebuild test -scheme md-preview-tests -destination 'platform=macOS'`.
4. For performance assertions, add a `maxStandardDeviationPercent` or explicit threshold in
   `measure(metrics:)` to make the gate meaningful in CI rather than advisory.

None of the recommended tests require network access, filesystem side-effects outside `/tmp`, or
mocks — they operate on real AppKit types with programmatically created content.
