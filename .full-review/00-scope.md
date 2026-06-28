# Review Scope

## Target

Editing feature implementation (Option A: Side-by-Side Editor + Live Preview) for the Markdown Preview macOS app. This is a feature branch (`feat/add-editing-support`) adding inline Markdown editing capability to a previously read-only viewer app.

The feature adds a collapsible NSTextView-based source editor pane alongside the existing WKWebView preview, with live preview updates, syntax highlighting, save/undo support, and external-change conflict handling.

Base commit: `7fc5aa2` (Release 0.0.28)
Head commit: `5916646` (latest on feat/add-editing-support)

## Files

### Modified files (5)
- `Info.plist` — CFBundleTypeRole changed from Viewer to Editor (+1/-1)
- `md-preview/md-preview.entitlements` — File access upgraded from read-only to read-write (+1/-1)
- `md-preview/MarkdownDocument.swift` — NSDocument subclass transformed from read-only to editable (+10/-17)
- `md-preview/MainSplitViewController.swift` — 4th split pane (editor) added, accessor updates (+53/-2)
- `md-preview/DocumentWindowController.swift` — Toolbar, data flow wiring, FileWatcher conflict handling (+95/-3)

### New files (2)
- `md-preview/EditorViewController.swift` — NSViewController wrapping NSScrollView+NSTextView (93 lines)
- `md-preview/MarkdownSyntaxHighlighter.swift` — Regex-based Markdown syntax highlighting (228 lines)

### Unchanged files that interact with changes
- `md-preview/MarkdownWebView.swift` — Receives markdown via display() (unchanged, but downstream)
- `md-preview/ContentViewController.swift` — Wraps MarkdownWebView (unchanged, but downstream)
- `md-preview/SidebarViewController.swift` — TOC/file navigator (unchanged, but receives updates)
- `md-preview/InspectorViewController.swift` — Metadata panel (unchanged, but receives updates)
- `md-preview/AppDelegate.swift` — App lifecycle (unchanged)

## Flags

- Security Focus: no
- Performance Critical: no
- Strict Mode: no
- Framework: AppKit/macOS (Swift, NSDocument architecture, WKWebView, NSSplitViewController)

## Review Phases

1. Code Quality & Architecture
2. Security & Performance
3. Testing & Documentation
4. Best Practices & Standards
5. Consolidated Report
