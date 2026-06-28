# Phase 2a — Security Audit: `feat/add-editing-support`

Scope: `git diff 7fc5aa2..HEAD`. Reviewed files: `md-preview.entitlements`, `Info.plist`,
`MarkdownDocument.swift`, `DocumentWindowController.swift`, `MainSplitViewController.swift`,
`EditorViewController.swift`, `MarkdownSyntaxHighlighter.swift`, `MarkdownAssetSchemeHandler.swift`,
`MarkdownWebView.swift`, `MarkdownHTML.swift`.

---

## Finding 1 — Entitlement Over-Breadth: Filesystem Read + Write Blast Radius

**Severity:** High  
**CWE:** CWE-732 (Incorrect Permission Assignment for Critical Resource)

### Background

The entitlements file now contains two entitlements that individually are defensible, but in
combination create a broader attack surface than is necessary:

```xml
<!-- read ANY file on the filesystem without Powerbox -->
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array><string>/</string></array>

<!-- write ANY file the user has ever selected through Powerbox -->
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
```

The `read-only /` exception was present before this PR. Upgrading from `read-only` to `read-write`
for user-selected files extends the impact of any future privilege escalation.

### How `files.user-selected.read-write` is scoped

`user-selected.read-write` does **not** grant free-range write access. Write capability applies only
to files and directories the user explicitly selects through an `NSOpenPanel` or `NSSavePanel`, and
only for the lifetime of the security-scoped bookmark that PowerBox creates. NSDocument's write
pipeline (`writeSafely(to:ofType:for:originalContentsURL:)`) respects this and will not write to
arbitrary paths — only to the file most recently opened/saved by the user. This correctly limits the
write surface.

### Why the combination still elevates risk

Before this PR: the app could read any path (`/`) and write nowhere outside the explicit scope. A
compromised render path (XSS, logic bug) could leak data but could not persist changes.

After this PR: read-any + write-user-selected means a compromised code path can also overwrite the
file the user currently has open — without any additional OS dialog. If the attacker also controls
what gets written (e.g., via `setMarkdown(_:)` being reachable from some code path), the user's
file is silently corrupted.

### Attack scenario

1. User opens `project.md` — PowerBox grants the app a read-write security-scoped bookmark for that
   file.
2. An attacker delivers a crafted `.md` file that triggers a bug in the markdown parser (e.g., via
   a future CommonMark library vulnerability or a code path exposed by the new editor).
3. The bug calls `markdownDocument?.setMarkdown(payload)` and triggers an autosave.
4. The app overwrites `project.md` with attacker-controlled content, since the existing bookmark
   authorizes the write.
5. Because `autosavesInPlace = true`, there is no separate autosave container — the overwrite
   lands on the original file immediately.

The host bridge (`didReceiveHostMessage`) exposes `copyCode`, `scroll`, `height`, and `log` — no
direct write path from JavaScript. The risk is indirect (parser vulnerability → `setMarkdown`), but
the blast radius is higher now that write is enabled.

### Remediation

1. Scope `temporary-exception.files.absolute-path.read-only` to `~/` (or specific well-known
   directories) rather than `/`. This satisfies the project-navigator use case (finding sibling
   assets relative to the document) without granting read access to system paths, `/etc`, or other
   users' home directories.
2. Request Apple's App Review team to confirm the `/` read-only exception is accepted for the
   `Editor` role — the comment claims "same pattern as Quick Look" but the Quick Look extension
   cannot write; the main app target now can.

---

## Finding 2 — Symlink Following in `MarkdownAssetScheme.resolve()`

**Severity:** Medium  
**CWE:** CWE-59 (Improper Link Resolution Before File Access — "Link Following")

### Code

```swift
// MarkdownAssetSchemeHandler.swift:49-61
nonisolated static func resolve(_ assetURL: URL, against base: URL) -> URL? {
    var path = assetURL.path
    while path.hasPrefix("/") { path.removeFirst() }
    guard !path.isEmpty else { return nil }

    let candidate = base.appendingPathComponent(path).standardizedFileURL
    let basePath = base.standardizedFileURL.path
    guard candidate.path == basePath
            || candidate.path.hasPrefix(basePath + "/") else {
        return nil
    }
    return candidate
}
```

`standardizedFileURL` collapses `..` components (lexical normalization) but **does not resolve
symbolic links** on disk. If the user's document directory contains a symlink that points outside
the base path, `candidate.path.hasPrefix(basePath + "/")` succeeds for the symlink itself (it is
inside `base`), and `Data(contentsOf: resolved)` then follows the link to its target.

### Attack scenario

1. Attacker plants a symlink in a directory alongside a markdown file:
   `~/Documents/notes/secret.png → /Users/alice/.ssh/id_rsa`
2. Attacker delivers `notes.md` containing `![](secret.png)`.
3. User opens `notes.md`. The asset base URL is `~/Documents/notes/`.
4. WebView requests `md-asset:///secret.png`.
5. `resolve()` canonicalises to `~/Documents/notes/secret.png` — inside `basePath` ✓.
6. `serve()` calls `Data(contentsOf: resolved)` which follows the symlink and reads `id_rsa`.
7. The content is served to the WebView with `Content-Type: image/png` (wrong MIME); the image
   fails to render visibly. The response carries `Access-Control-Allow-Origin: *`.
8. Page JavaScript (which is **enabled** in the WKWebView) can `fetch('md-asset:///secret.png')`
   and read the response body via the CORS-open response.
9. Combined with `com.apple.security.network.client`, the fetched bytes can be POSTed to an
   external server via a second `fetch()`.

Note: the `/` read-only exception already lets the **host process** read `id_rsa`. The additional
concern here is that the symlink path makes the content available to the **JavaScript sandbox**
inside WKWebView, and the CORS wildcard makes it retrievable from there, enabling in-page
exfiltration — a path the host process does not take.

### Remediation

After computing `candidate`, call `resolvingSymlinksInPath()` and re-check containment:

```swift
let candidate = base.appendingPathComponent(path).standardizedFileURL
let basePath = base.standardizedFileURL.path

// Lexical check (catches `..` traversal):
guard candidate.path == basePath
        || candidate.path.hasPrefix(basePath + "/") else { return nil }

// Physical check (catches symlinks pointing outside base):
let physical = candidate.resolvingSymlinksInPath()
let physicalBase = URL(fileURLWithPath: basePath).resolvingSymlinksInPath().path
guard physical.path == physicalBase
        || physical.path.hasPrefix(physicalBase + "/") else { return nil }

return candidate
```

Additionally, replace `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Origin: null`
(since the page is loaded with `baseURL: nil` / `about:blank` origin). This prevents JavaScript
running in any other origin from cross-origin-fetching asset scheme responses.

---

## Finding 3 — `showExternalChangeAlert` Has No Duplicate-Sheet Guard

**Severity:** Medium  
**CWE:** CWE-362 (Concurrent Execution Using Shared Resource with Improper Synchronization)

### Code

```swift
// DocumentWindowController.swift:1176-1188
private func showExternalChangeAlert(fileURL: URL) {
    let alert = NSAlert()
    // ...
    alert.beginSheetModal(for: documentWindow) { [weak self] response in
        if response == .alertSecondButtonReturn {
            self?.loadFile(at: fileURL, silentOnFailure: true)
        }
    }
}
```

`NSWindow.beginSheetModal` stacks sheets — it does not check whether one is already visible before
appending a new one. The FileWatcher fires on every `write`/`extend`/`rename`/`delete` event with
an 80 ms debounce (`scheduleChange`). With `autosavesInPlace = true`, NSDocument performs atomic
writes: write temp file → `rename()` into place. This generates a `write` + `rename` pair within a
single save, potentially firing the debounced callback twice. Each firing calls
`showExternalChangeAlert` independently.

### Attack scenario

1. User is editing a large document; autosave fires every 1–2 seconds.
2. Each autosave triggers a `rename` event on the watched fd, which fires the callback.
3. Because `markdownDocument?.isDocumentEdited == true` (the file was just autosaved but
   `updateChangeCount(.changeDone)` was called without a matching `.changeCleared` yet), the check
   passes and a new sheet is enqueued.
4. Over 30 seconds the window accumulates a queue of ~15 stacked modal sheets. Each must be
   dismissed individually before the user can interact with the window.
5. Maliciously, a process with write permission on the same file can loop-touch the file to
   continuously enqueue new alert sheets — a denial-of-service against the user's ability to save
   or dismiss the document.

### Remediation

Track a `private var externalChangeAlertIsVisible = false` flag; set it to `true` before calling
`beginSheetModal` and back to `false` in the completion handler. Skip the sheet if the flag is set:

```swift
private var externalChangeAlertIsVisible = false

private func showExternalChangeAlert(fileURL: URL) {
    guard !externalChangeAlertIsVisible else { return }
    externalChangeAlertIsVisible = true
    let alert = NSAlert()
    // ...
    alert.beginSheetModal(for: documentWindow) { [weak self] response in
        self?.externalChangeAlertIsVisible = false
        if response == .alertSecondButtonReturn {
            self?.loadFile(at: fileURL, silentOnFailure: true)
        }
    }
}
```

The secondary race (autosave triggering the watcher for the app's own writes) should be addressed
separately by suppressing FileWatcher callbacks during the save operation itself (set a flag before
`save()`, clear it in the document callback), which is the correct fix for the Phase 1 autosave
conflict.

---

## Finding 4 — Filename Interpolated Unescaped in Alert Message (Unicode Injection)

**Severity:** Medium  
**CWE:** CWE-116 (Improper Encoding or Escaping of Output), social-engineering vector

### Code

```swift
// DocumentWindowController.swift:1179
alert.informativeText = "\"\(fileURL.lastPathComponent)\" has been modified by another application."
```

`lastPathComponent` is inserted directly into the user-visible string without sanitizing Unicode
directional control characters. macOS (HFS+/APFS) permits filenames containing:

- **U+202E RIGHT-TO-LEFT OVERRIDE** — reverses display order of subsequent characters
- **U+200B ZERO-WIDTH SPACE** — invisible separator that defeats literal matching
- **Look-alike/confusable characters** — Cyrillic `а` (U+0430) for Latin `a`, etc.

### Attack scenario

1. An attacker hosting a Git repository or a shared folder adds a file named
   `‮fdp.tnemucodevitisnes` (RTL override at U+202E, so displayed left-to-right as
   `sensitivedocument.pdf`).
2. User opens the repo folder in the app's sidebar navigator; the file appears normal.
3. User edits a sibling `.md` file; the FileWatcher fires on the planted file (e.g., via `touch`
   from a build script).
4. The alert reads: `"sensitivedocument.pdf" has been modified by another application.`
5. The user clicks "Reload from Disk", loading attacker-controlled content into the editor.

The deception is stronger if the attacker controls not just the filename but the file content to be
reloaded — both are now possible since the user just granted write access to files in that
directory.

### Remediation

Sanitize before displaying:

```swift
import Foundation

private func sanitizedDisplayName(_ url: URL) -> String {
    // Strip Unicode direction-override and other invisible formatting characters.
    let controlCategories: [Unicode.GeneralCategory] = [
        .control, .format, .privateUse, .surrogate
    ]
    return url.lastPathComponent.unicodeScalars
        .filter { scalar in
            // Allow standard ASCII control chars NSAlert handles (none really needed)
            // but drop all Unicode directional/invisible formatters.
            !controlCategories.contains(scalar.properties.generalCategory)
                || scalar.value < 0x20
        }
        .reduce(into: "") { $0.append(Character($1)) }
}
```

Use `sanitizedDisplayName(fileURL)` in the `informativeText` assignment.

---

## Finding 5 — No Document-Size Guard in `applyHighlighting(to:)` — CPU DoS

**Severity:** Medium  
**CWE:** CWE-400 (Uncontrolled Resource Consumption)

### Code

```swift
// MarkdownSyntaxHighlighter.swift:28-129
func applyHighlighting(to textStorage: NSTextStorage) {
    let length = textStorage.length
    guard length > 0 else { return }   // ← only guard is non-empty

    let fullRange = NSRange(location: 0, length: length)
    let string = textStorage.string as NSString

    textStorage.beginEditing()
    textStorage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor],
                              range: fullRange)    // O(n) full reset

    highlightCodeFences(...)  // O(n) line scan
    applyPattern("`[^`\\n]+`", ...)
    applyPattern("(?m)^#{1,6}\\s+.*$", ...)
    // ... 5 more patterns, each O(n)
    textStorage.endEditing()
}
```

Every call performs a full `setAttributes` reset followed by seven regex passes over the entire
document, all on the main thread. This runs on **every keystroke** via `textDidChange`. No size
threshold guards the call.

### Attack scenario

A user opens a crafted 5 MB `.md` file (well within plausible documentation sizes) and presses a
key. `applyHighlighting` runs 8 O(n) passes over ~5 million characters on the main thread. On
slower machines this can block the main run loop for 400–800 ms per keystroke, making the app
effectively unresponsive. A 50 MB file causes multi-second freezes. Because the file was opened
via the sandboxed file picker, no privilege is required — just a large enough markdown document on
the filesystem.

### Remediation

Add a size threshold above which highlighting is skipped or deferred to a background thread with
appropriate NSTextStorage locking:

```swift
private static let highlightThresholdBytes = 512 * 1024  // 512 KB

func applyHighlighting(to textStorage: NSTextStorage) {
    guard textStorage.length > 0,
          textStorage.length < Self.highlightThresholdBytes else { return }
    // ...
}
```

For documents above the threshold, show a status-bar note ("Syntax highlighting disabled for large
files") rather than silently degrading. See also Finding 6 for the companion issue.

---

## Finding 6 — Per-Keystroke Regex Recompilation in `applyPattern`

**Severity:** Medium  
**CWE:** CWE-400 (Uncontrolled Resource Consumption)

### Code

```swift
// MarkdownSyntaxHighlighter.swift:194-209
private func applyPattern(_ pattern: String, ...) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
    // ...
}
```

`NSRegularExpression(pattern:)` compiles the ICU pattern every time it is called. `applyPattern` is
called seven times per `applyHighlighting` invocation, and `applyHighlighting` is called in
`textDidChange` (every keystroke). Net effect: **7 regex compilations per keystroke**, 100% wasted
— the patterns are string literals that never change.

Only `fenceOpenRegex` is compiled once (`lazy var`).

### Attack scenario

Beyond the general performance regression, this creates a computable DoS scenario: a document with
very long lines (no newlines) exercises the worst-case backtracking path of `(?m)^#{1,6}\\s+.*$`
and `\\*[^*\\n]+\\*` on the full document string. Since each regex is recompiled fresh and
NSRegularExpression does not cache the internal automaton state between calls, each keystroke
restarts the automaton from zero. On a 100 KB single-line document (legal in Markdown), each
`applyPattern` call on the `.*$` pattern can take O(n²) time in the ICU backtracking engine.

### Remediation

Cache all compiled regexes as `private lazy var` properties, mirroring the existing pattern for
`fenceOpenRegex`:

```swift
private lazy var inlineCodeRegex = try? NSRegularExpression(pattern: "`[^`\\n]+`")
private lazy var headingRegex    = try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+.*$")
private lazy var boldRegex       = try? NSRegularExpression(pattern: "(\\*\\*|__)(.+?)\\1")
private lazy var italicRegex     = try? NSRegularExpression(pattern: "\\*[^*\\n]+\\*")
private lazy var linkRegex       = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")
private lazy var blockquoteRegex = try? NSRegularExpression(pattern: "(?m)^>\\s+.*$")
private lazy var listRegex       = try? NSRegularExpression(pattern: "(?m)^[\\t ]*([-*+]|\\d+\\.)\\s")
private lazy var hruleRegex      = try? NSRegularExpression(pattern: "(?m)^[-*_]{3,}\\s*$")
```

Pass the cached regex directly to a private overload of `applyPattern` that accepts
`NSRegularExpression` instead of `String`. This also removes the silent `try?` failure mode where
a typo in a pattern string would silently skip highlighting with no diagnostic.

---

## Finding 7 — `Access-Control-Allow-Origin: *` on Custom-Scheme Responses

**Severity:** Low  
**CWE:** CWE-942 (Permissive Cross-domain Policy)

### Code

```swift
// MarkdownAssetSchemeHandler.swift:149
"Access-Control-Allow-Origin": "*"
```

All responses from the `md-asset://` scheme handler include an unrestricted CORS allow-all header.
The page is loaded with `baseURL: nil`, so its effective origin is `null`. JavaScript executing in
that page (which is already same-origin with `md-asset://` for script-tag and image-tag loading)
can additionally `fetch()` any `md-asset://` URL and read the response body because the CORS
wildcard permits cross-origin reads.

This is the CORS channel exploited in Finding 2's attack chain. Independently, it also means that
if any third-party origin were ever loaded in the same WebView, it would receive full read access
to every file in the document's directory via the scheme handler.

### Remediation

Replace `*` with the actual page origin. Since the page is loaded with `baseURL: nil` / `null`
origin, use:

```swift
"Access-Control-Allow-Origin": "null"
```

Or omit the header entirely (same-origin resource requests such as `<img src="md-asset://...">` do
not require CORS headers; only `fetch()` from JavaScript across origins does). Omitting it is the
more conservative choice: asset images and vendor scripts load via `<img>` and `<script>` tags
which never check CORS headers, while JavaScript `fetch()` calls from the page to `md-asset://`
would be blocked — which is the desired behavior.

---

## WKWebView XSS Assessment — No New Finding

The DOMPurify sanitization pipeline correctly defends against XSS from user-authored or maliciously
crafted markdown:

- HTML renders inside an inert `<template>` element on first load (no script execution during
  parsing).
- Every update path calls `sanitize(articleHTML)` via `MdPreview.update` before assigning to
  `innerHTML`.
- The sanitizer is fail-closed: if `purify.min.js` is missing, `sanitize()` returns `''` and
  renders nothing.
- `FORBID_TAGS` excludes `<style>`, `<form>`, `<iframe>`, `<object>`, `<embed>`, `<meta>`,
  `<link>`, and `<base>`.
- `ALLOWED_URI_REGEXP` correctly rejects `javascript:` URIs (the third alternative
  `[a-z+.\\-]+(?:[^a-z+.\\-:]|$)` requires the scheme-like prefix to be followed by a non-colon
  character, so `javascript:` does not match).
- `evaluateJavaScript` call sites pass user content through `javaScriptStringLiteral()` which uses
  `JSONSerialization` for safe encoding — no raw string interpolation of user content into
  JavaScript source.
- The host bridge (`didReceiveHostMessage`) exposes only: height reporting, debug logging,
  clipboard write, and scroll actions — no file-write or filesystem-access primitives.

The only residual XSS risk comes from Finding 2 (symlink-mediated content exfiltration via
JavaScript `fetch`), which requires the `Access-Control-Allow-Origin: *` CORS header to be
exploitable.

---

## NSTextView Input Handling Assessment — No Critical Findings

- **Null bytes**: `String(data:encoding:.utf8)` in `read(from data:ofType:)` silently drops null
  bytes during decoding (Swift's `String` does not include embedded nulls). The editing path stores
  a clean Swift `String` in `markdownStorage`, so null bytes cannot survive into a write.
- **RTL override in editor**: Bidi text in NSTextView is a display concern (text looks different
  from the Unicode codepoints) but not a security violation — the editor is a plain-text author
  tool and what the user types is exactly what gets stored. The filename-display issue is covered in
  Finding 4.
- **Extremely long lines**: Covered under Findings 5 and 6 (regex DoS). No additional NSTextView-
  specific vulnerability was identified.
- **`insertMarkdownSnippet`**: Calls `textView.insertText(_:replacementRange:)` — this is the
  standard AppKit snippet insertion path and does not bypass any delegate-side change tracking.

---

## Summary Table

| # | Finding | Severity | CWE | Status |
|---|---------|----------|-----|--------|
| 1 | Entitlement over-breadth: `/` read + user-write blast radius | **High** | CWE-732 | Open |
| 2 | Symlink following in `MarkdownAssetScheme.resolve()` | **Medium-High** | CWE-59 | Open |
| 3 | No duplicate-sheet guard in `showExternalChangeAlert` | **Medium** | CWE-362 | Open |
| 4 | Filename unescaped in alert — Unicode/RTL injection | **Medium** | CWE-116 | Open |
| 5 | No document-size guard before highlighter — CPU DoS | **Medium** | CWE-400 | Open |
| 6 | Per-keystroke regex recompilation — CPU DoS | **Medium** | CWE-400 | Open |
| 7 | `Access-Control-Allow-Origin: *` in asset scheme | **Low** | CWE-942 | Open |
| — | WKWebView XSS pipeline | — | — | No finding |
| — | NSTextView input handling | — | — | No finding |
