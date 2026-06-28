# Agent Brief: EditorViewController + Syntax Highlighter

## Context

You are working on a macOS AppKit app called "Markdown Preview" (bundle id: `doc.md-preview`,
min macOS 15.0). It currently previews Markdown files in a WKWebView. We are adding a
side-by-side source editor pane.

Your task is to create TWO new Swift files from scratch. You will NOT modify any existing files.

## Files you MUST create (and ONLY these files)

### 1. `md-preview/EditorViewController.swift`

A new `NSViewController` subclass that wraps an `NSScrollView` containing an `NSTextView`
for editing Markdown source code.

Requirements:

```swift
import Cocoa

final class EditorViewController: NSViewController, NSTextViewDelegate {

    /// Called (debounced) whenever the user edits text. The String is the full document text.
    var onTextChange: ((String) -> Void)?

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var highlighter: MarkdownSyntaxHighlighter!
    private var debounceWork: DispatchWorkItem?
    private static let debounceDelay: TimeInterval = 0.20

    /// Whether we're programmatically setting text (suppresses onTextChange callback)
    private var isSettingText = false
```

**Key behaviors:**

a) **`loadView()`**: Create an `NSScrollView` with an `NSTextView` inside it. The text view should:
   - Use `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)` as the default font
   - Have a text container that tracks the scroll view width (horizontal wrapping, no horizontal scroll)
   - Set `isRichText = false`, `isAutomaticQuoteSubstitutionEnabled = false`,
     `isAutomaticDashSubstitutionEnabled = false`, `isAutomaticTextReplacementEnabled = false`
   - Enable undo: `allowsUndo = true`
   - Use `usesFindBar = true` for inline find
   - Set text color to `NSColor.labelColor` and background to `NSColor.textBackgroundColor`
   - Set the text container inset to `NSSize(width: 16, height: 16)` for comfortable padding
   - Set self as the delegate (`textView.delegate = self`)
   - Create a `MarkdownSyntaxHighlighter` and store it in `self.highlighter`

b) **`setMarkdown(_ text: String)`**: Set the text view's string programmatically (e.g. when a file
   is opened or reloaded from disk). This MUST set `isSettingText = true` before changing the string,
   and `false` after, so the `onTextChange` callback is NOT fired. After setting the string, call
   `highlighter.applyHighlighting(to: textView.textStorage!)`.

c) **`textDidChange(_ notification: Notification)`** (NSTextViewDelegate): Called on every edit.
   - If `isSettingText`, return immediately
   - Apply syntax highlighting: `highlighter.applyHighlighting(to: textView.textStorage!)`
   - Cancel any pending debounce work
   - Create a new `DispatchWorkItem` that captures `textView.string` and calls `onTextChange`
   - Schedule it with `DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, ...)`

d) **`var currentText: String`**: Read-only computed property returning `textView?.string ?? ""`

e) **Focus support**: Override `becomeFirstResponder()` to make the text view the first responder
   via `view.window?.makeFirstResponder(textView)`.

f) **`insertMarkdownSnippet(_ snippet: String)`**: Insert text at the current cursor position.
   Uses `textView.insertText(snippet, replacementRange: textView.selectedRange())`.

### 2. `md-preview/MarkdownSyntaxHighlighter.swift`

A lightweight Markdown syntax highlighter that operates on `NSTextStorage`.
It applies colored attributes to Markdown constructs.

Requirements:

```swift
import Cocoa

final class MarkdownSyntaxHighlighter {
    // Theme colors — adapts to light/dark mode via semantic colors
    private let headingColor: NSColor = .systemBlue
    private let boldColor: NSColor = .labelColor
    private let italicColor: NSColor = .secondaryLabelColor
    private let codeColor: NSColor = .systemGreen
    private let linkColor: NSColor = .systemIndigo
    private let blockquoteColor: NSColor = .systemOrange
    private let listMarkerColor: NSColor = .systemPurple
    private let commentColor: NSColor = .tertiaryLabelColor

    private let baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private let headingFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
    private let boldFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .bold)
```

**Key behaviors:**

a) **`func applyHighlighting(to textStorage: NSTextStorage)`**:
   - Call `textStorage.beginEditing()`
   - Reset all attributes on the full range to base font + `NSColor.labelColor`
   - Apply highlighting rules in order (patterns below)
   - Call `textStorage.endEditing()`

b) **Highlighting rules** (use `NSRegularExpression` for patterns). Process the full text as
   `NSString` for range operations. Each rule finds matches and applies `NSAttributedString` attributes:

   1. **Code fences** (` ```...``` ` blocks): Match with pattern `(?m)^(`{3,}|~{3,}).*\n([\s\S]*?\n)\1\s*$`
      — apply `codeColor` + base font to the entire block. Process these FIRST so inner patterns don't
      override fence content.

   2. **Inline code** (`` `...` ``): Pattern `` `[^`\n]+` `` — apply `codeColor` + base font.

   3. **Headings** (`# ...`): Pattern `(?m)^#{1,6}\s+.*$` — apply `headingColor` + `headingFont`.

   4. **Bold** (`**...**` or `__...__`): Pattern `(\*\*|__)(.+?)\1` — apply `boldFont` to the
      inner text range (not the markers).

   5. **Italic** (`*...*` or `_..._`, but not inside bold): Pattern `(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)`
      — apply italic trait. Note: NSRegularExpression doesn't support lookbehind, so use a simpler
      approach: pattern `(?:^|[^*])\*([^*]+)\*(?:[^*]|$)` or just match `\*[^*\n]+\*` and apply
      `italicColor`. Keep it simple — exact italic detection is complex and a stretch goal.

   6. **Links** (`[text](url)`): Pattern `\[([^\]]+)\]\(([^)]+)\)` — apply `linkColor` with underline.

   7. **Blockquotes** (`> ...`): Pattern `(?m)^>\s+.*$` — apply `blockquoteColor`.

   8. **List markers** (`- `, `* `, `1. `): Pattern `(?m)^[\t ]*(?:[-*+]|\d+\.)\s` — apply
      `listMarkerColor` to just the marker.

   9. **Horizontal rules** (`---`, `***`, `___`): Pattern `(?m)^[-*_]{3,}\s*$` — apply `commentColor`.

   **IMPORTANT**: The regex patterns must be valid for `NSRegularExpression` (ICU regex). ICU regex
   does NOT support `\s\S` inside character classes as "match anything including newlines" — use
   `[\s\S]` or use the `.dotMatchesLineSeparators` option with `.`. Be careful with multiline code
   fence matching.

   **Simplification advice**: If a complex regex fails, use a simpler line-by-line approach for
   code fences: scan lines, track `inFence` state, and apply attributes to fence lines. This is
   more robust than a multiline regex.

c) The highlighter should be **performant on large files**. The approach of "reset all, then apply
   rules" is O(n) per rule × number of rules — acceptable for documents up to ~50KB. For larger
   files, a future optimization would be incremental highlighting, but that's out of scope.

## IMPORTANT constraints

- Target macOS 15.0+. Use modern Swift (6.x compatible).
- Do NOT modify any existing files. Only create the two new files above.
- Both files go in the `md-preview/` directory.
- Use `import Cocoa` (not AppKit) to match the project's convention.
- No SwiftUI — these are pure AppKit view controllers (matching the project's pattern).
- No external dependencies — only Foundation/Cocoa/AppKit.
- Match the code style of existing files: file header comment with `//  FileName.swift\n//  md-preview\n//`, `final class`, explicit access control only where needed.

## Verification

After creating both files, verify there are no obvious syntax errors (balanced braces, valid
Swift syntax, all types used are from Cocoa/Foundation).

When done, write RESULT.json at the repo root:
```json
{"status":"ok","files":["md-preview/EditorViewController.swift","md-preview/MarkdownSyntaxHighlighter.swift"],"notes":"Created EditorViewController with debounced text change callbacks and MarkdownSyntaxHighlighter with regex-based highlighting for headings, bold, italic, code, links, blockquotes, and list markers."}
```
