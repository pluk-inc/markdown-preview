# Markdown core — agent guide

Read this before you change `markdown-core/` or the native renderer's host
code in `md-preview/Features/NativeRenderer/`. It says where the work
stands, what was decided, and what comes next. `README.md` in this folder
explains the structure; this file is the project log.

**Keep it current.** When a session changes the state, a decision, or the
list of open work, it updates this file in the same commit. Add to the
timeline; do not rewrite its history.

## Goal

Replace the web view as the reader's renderer with a renderer that draws in
the app process: text on screen with the window, less memory, and one core
that can later build for other platforms and the web. The web view stays
the default until the native renderer has every feature. Features move
over one at a time.

## State

| | |
| --- | --- |
| Where | `markdown-core/` (the core), `md-preview/Features/NativeRenderer/` (the host view and the style), a switch in `ContentViewController.display` |
| How a reader gets it | Settings → Advanced → "Use the experimental native renderer" (`RendererSetting`, key `MarkdownPreview.renderer`, `web` or `native`). Off by default. |
| For one launch | `--args -MarkdownPreview.renderer native` |
| First pull request | #665 |

What works: headings, paragraphs, bold, italic, strikethrough, inline code,
links (shown, not opened), lists with nesting, task lists, quotes, code
blocks, tables, rules, emoji, text of any script that CoreText can shape.
Scrolling with the system scroll bar, selection by drag, Select All, Copy.
The reader style from the app: font, text size and zoom, line spacing,
bold text, margins, content width, theme colors, light and dark.

What does not work yet is the list at the end of `README.md`.

## Decisions

These came from the maintainer. Do not undo one without asking.

- **The native renderer is the only renderer while its switch is on.** A
  feature it does not have is a visible gap. There is no automatic fall
  back to the web view for a document that needs one.
- **The core is built from source in the Xcode build.** No prebuilt binary
  in the repository. Odin is a build requirement (`brew install odin`).
- **Names say what the thing is, not what it is written in.** The folder is
  `markdown-core`, the C prefix is `mdcore_`. The core is meant to build
  for other platforms later.
- **The window comes first, then the document.** The host draws the native
  view right after the window's first frame.
- **The core is a product, not a prototype.** It was rewritten from zero
  into packages for that reason. Keep the package borders and the two
  platform seams (see below) when you add to it.
- **One pull request for one line of work.** Do not stack branches for
  parts of the same change.

## Rules for the code

- Platform code goes only in `text/*_darwin.odin` and
  `renderer/*_darwin.odin`. No CoreText, CoreGraphics, or Metal type
  anywhere else, and none in the document model.
- Outside the text backend, every text offset is a UTF-8 byte offset.
- A package uses only the packages before it: `base`, `document`, `text`,
  `layout`, `renderer`. `mdcore.odin` is the C API and uses all of them.
- The C API in `include/mdcore.h` is the contract with hosts. A change to
  `mdcore_style` must be made in the header and in `base.Style` together;
  the two have the same fields in the same order.
- `pkg/md4c` is an unchanged copy of upstream. Do not patch it here.
- A change to the parser or the layout comes with a unit test
  (`*_test.odin`), and `markdown-core/test.sh` must pass.
- The Swift host owns the view, the scroll position, and the events. The
  scroll bar is AppKit's: a transparent `NSScrollView` over the Metal
  layer.
- The host draws one frame for each display refresh, from a display link
  (`NSView.displayLink`), never one for each event. A draw waits for a
  drawable, so a draw in an event handler holds the main thread: a scroll
  measured at twice its time that way (see Numbers). An event calls
  `setNeedsDraw()`. Only a new layout (first frame, resize, style) draws
  at once.

## How to check a change

```bash
markdown-core/test.sh                      # unit tests, no window
xcodebuild -project md-preview.xcodeproj -scheme md-preview -configuration Debug build
```

Then look at it in the app with the hidden-display skill
(`headless-ui-test`), launched with `-MarkdownPreview.renderer native`.
`samples/full.md` covers most block kinds.

Things that cost time before:

- Menu items such as Select All and Zoom In are disabled while the test
  app is not the front app, so a click through Accessibility does nothing.
- A launch argument cannot set the zoom (the app reads a number, the
  argument is a string). Zoom through the View menu.
- The appearance setting is shared between development builds. Set it back
  after a dark mode check.
- The first launch after a build can need more than five seconds to show a
  window.
- `tests/test-mode-transitions.py` copies the zoom functions and the zoom
  callback out of `ContentViewController` into a stub class. A new member
  used there needs a stub in that script.
- `MarkdownWebView.swift` is shared with the Quick Look target: no
  app-only type in it.
- No CI job builds the Xcode app or has Odin, so CI does not compile the
  core or run its tests yet.

## Numbers

The main numbers are recorded in `BENCHMARKS.md`, with the two programs
that measure them (`bench/core.py`, `bench/app.py`). Before a pull request
that changes the core or the host view, run both on the base and on the
change, and add a row.

The first version of the core, measured on screen on 2026-11-21 with a
Release build and a new document (another method, so do not compare it
with `BENCHMARKS.md`):

| | Web view | Native |
| --- | --- | --- |
| Text on screen, 7 KB file | 573–611 ms | 400–456 ms |
| Text on screen, 152 KB file | 771–836 ms | 427–470 ms |
| Memory, small file, all processes | 139 MB | 89 MB |

Scroll, 2026-11-23, Debug build, 60 Hz display, 600 scroll steps sent
8 ms apart (4.8 s of input) over a document of 18,000 points:

| | Draw in the event | Draw from the display link |
| --- | --- | --- |
| Time to finish the scroll | 10.0 s | 5.7–6.3 s |
| Main thread held by draws | 4.1 s | 0.2–1.5 s |
| Median draw | 6.8 ms | 0.3–3.8 ms |

The slow frames that stay (10 to 50 ms, a few in the first screens of a
document) are glyphs drawn for the first time and the first growth of the
glyph atlas. Later passes over the same text have none.

## Open work

Known limits, found in review and left on purpose:

- One very long paragraph or one large table is laid out in one step. Code
  blocks stop between lines.
- A glyph atlas that reaches 1024 × 16384 px drops new glyphs until the
  cache is emptied. More atlas pages would fix it.
- The first growth of the glyph atlas costs one frame of 40 to 50 ms,
  because the whole texture is made again. A larger first size or atlas
  pages would remove it.
- The parser reads a heading right after a table as a table row, and
  accepts a header row with more cells than the delimiter row. Both are
  upstream behavior.
- A `WKWebView` object still exists in a native window, which starts
  WebKit's GPU process (about 5 MB). Making the web view on demand would
  remove it.
- A 1 MB document takes about 130 MB of heap after the full layout, and
  the app shows it about 280 ms later than a short one, which the core's
  first frame does not account for (`BENCHMARKS.md`).
- The core has no way to call the host yet (open a link, load an image).
  It needs a callback struct given at creation.

Next features, in the order that seems best (not agreed with the
maintainer): links that open, images, code colors, Find, the outline's
scroll position, footnotes and alerts, VoiceOver, print and export.

## Timeline

- **2026-11-21** — Tests of the idea: an in-process renderer removes the
  wait for WebKit's helper processes. A first Odin version drew the reader
  in the real app and gave the numbers above.
- **2026-11-21** — The maintainer decided to build it for real, beside the
  web view, behind a setting. First version of the core as one flat
  package that parsed with the app's own parser copy. Pull request #665
  opened: the core, the build phase, the setting, the host view.
- **2026-11-21 to 22** — Review rounds on #665: old text after a reload,
  tables that ask for millions of cells, a full glyph atlas, code fences
  in the table scanner, a document with no text.
- **2026-11-22** — Reader style from the app: fonts, zoom, colors, dark
  mode, through `mdcore_set_style`.
- **2026-11-22** — The maintainer asked for a structure that lasts, then
  for a rewrite from zero. The core became packages with md4c inside,
  CoreText and Metal behind one file each, a document model without
  platform types, quads only for the visible part, and unit tests. The C
  API stayed the same, so the host did not change. All of it went into
  #665.
- **2026-11-22** — More review fixes: the Margins slider (`column_inset`
  in the style), blank lines in copied code, markers of empty items and of
  items that start with code. System scroll bar added. This guide added.
- **2026-11-23** — The maintainer found the scroll slower and less smooth
  than the web view's. Measured: each draw in a scroll event held the main
  thread about 7 ms. Drawing moved to a display link, the keyboard scroll
  is animated, and the display list looks up a font one time for each run.
- **2026-11-23** — The maintainer asked for main numbers that are kept
  over time. `bench/core.py` (the core, no window) and `bench/app.py` (the
  app, cold launch, from a new `nativePaint` signpost) added, with the
  first record in `BENCHMARKS.md`.
