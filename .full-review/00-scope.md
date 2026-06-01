# Review Scope

## Target

All code implementing the **Export as PDF** feature on branch `feat/add-pdf-export`
(commits `ac5879a..93e1f0a`, i.e. everything after the plan commit `5e1f327`).
The feature renders the current Markdown document into a dedicated offscreen
`WKWebView`, waits for async renderers (KaTeX/Mermaid/highlight.js) to settle,
and writes a paginated PDF via a silent `NSPrintOperation`.

## Files

New:
- `md-preview/PDFPageSize.swift` — pure locale→paper-size helper
- `md-preview/MarkdownExportAssets.swift` — export CSS + render-readiness JS (string builders)
- `md-preview/PDFExporter.swift` — offscreen render + silent print-to-file (`@MainActor`)
- `tests/swift-tests/Tests/MarkdownHelpersTests/PDFPageSizeTests.swift`
- `tests/swift-tests/Tests/MarkdownHelpersTests/MarkdownExportAssetsTests.swift`
- `tests/swift-tests/Sources/MarkdownHelpers/{PDFPageSize,MarkdownExportAssets}.swift` (symlinks)

Modified:
- `md-preview/MarkdownHTML.swift` — `forExport` param: head injection + eager-Mermaid path
- `md-preview/DocumentWindowController.swift` — `exportMarkdownAsPDF:`, save panel, toolbar item, menu validation
- `md-preview/Base.lproj/MainMenu.xib` — "Export as PDF…" (⌥⌘P)
- `md-preview/md-preview.entitlements` — `com.apple.security.files.user-selected.read-write`
- `md-preview.xcodeproj/project.pbxproj` — add `MarkdownExportAssets.swift` to quick-look `membershipExceptions`

Helper artifacts for reviewers (in `.full-review/`): `_impl-diff.txt` (full diff of
`md-preview/` since the plan commit), `_diff-stat.txt`.

## Flags

- Security Focus: no
- Performance Critical: no
- Strict Mode: no
- Framework: Swift 6 / AppKit / WebKit (sandboxed macOS app, no server/DB/frontend-web)

## Context for reviewers

- The app is **sandboxed**; user file reads go through `com.apple.security.temporary-exception.files.absolute-path.read-only=/`, writes through `NSSavePanel` + Powerbox.
- Markdown HTML is sanitized with **DOMPurify** before injection (`MarkdownHTML` bootstrap); the WebView disables JS-driven navigation and forbids dangerous tags.
- `MarkdownHTML.swift` is **shared** between the app target and the embedded **quick-look** extension.
- Several phases of the generic template (CI/CD blue-green, DB N+1, frontend bundle size) do **not** apply to a local AppKit app — reviewers should note N/A briefly and focus on what's relevant (concurrency/thread-safety, WebKit security surface, sandbox correctness, memory/lifetime, idiomatic Swift 6).

## Review Phases

1. Code Quality & Architecture
2. Security & Performance
3. Testing & Documentation
4. Best Practices & Standards
5. Consolidated Report
