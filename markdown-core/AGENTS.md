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
links (shown, not opened), lists with nesting, task lists with check boxes
that a click checks and saves, quotes, code blocks, tables, rules, emoji,
text of any script that CoreText can shape.
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
  parts of the same change. Since 2026-11-23 the first pull request (#665)
  is the base, and each later line of work is a pull request stacked on
  the one before it.

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
- Every block keeps its small records (place, line ranges and widths,
  decorations) for the full document. Only the lines near the view keep
  their shaped text, the text system's paragraph and line objects
  (`layout/window.odin`). Code that reads glyphs or a caret's x takes its
  line from `shaped_line`, which shapes it again when needed. Code that
  works on the full document (the copied text, Select All, the page
  height) must use the records only, or it shapes all of the document.
- The Swift host owns the view, the scroll position, and the events. The
  scroll bar is AppKit's: a transparent `NSScrollView` over the Metal
  layer.
- The host draws one frame for each refresh of the display, never one for
  each event. An event calls `setNeedsDraw()`, which asks the render loop
  (`NativeRenderLoop`) for a frame at the scroll offset; a newer request
  replaces one that is not drawn yet.
- The render loop's clock is a `CVDisplayLink`, and frames are drawn on
  its thread. Do not change it for a display link from AppKit
  (`NSView.displayLink`, and the ones of a window or a screen): on a
  120 Hz display those fire 64 times a second whatever rate they are asked
  for, and `CVDisplayLink` 130 (see Numbers). `CAMetalDisplayLink` has the
  full rate, but most of its frames did not reach the screen for a window
  that is not in front, and its callbacks stopped with a transparent
  layer. `CVDisplayLink` is deprecated since macOS 15, so the build has
  warnings for it.
- Frames and layout steps run off the main thread. A draw can wait for a
  drawable and can make glyph bitmaps, and on the main thread that held
  scroll events: a scroll took up to twice its time (see Numbers). Only a
  frame that must be there with the window's (the first frame, a new
  size, a new style) is drawn on the main thread itself, and goes to the
  screen with that thread's Core Animation transaction
  (`mdcore_draw_with_window`). A frame that is presented at once shows one
  step before the window's new size and before the views that AppKit
  moves; keep this frame in the transaction.
- A keyboard scroll is animated by the render loop, one step for each
  frame, and the scroll view follows on the main thread
  (`frameDidDraw`). The scroll view is not the clock for it.
- The main thread reads the page height from the core itself, after the
  queue's work. Do not send a height from the queue to the main thread: it
  can come after a newer one and make the page shorter for a moment, and
  then the End key stops at the wrong place.
- A block for the render loop must not keep the view alive. The view's
  `deinit` stops the loop and waits for it.
- The core lets one call at a time work on a view's state, from any
  thread (`hold` in `mdcore.odin`), and `mdcore_draw` gives the state free
  before it waits for the display (`renderer.frame_begin` under the lock,
  `frame_draw` after it). A new export calls `hold`. Code after the block
  that holds the state in `mdcore_draw` must use only the frame.
- The working memory of a call is the view's own (`ctx.temp`), not the
  thread's: a queue's threads come and go, and each would leave its own
  behind. An export sets `context.temp_allocator` from it.

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

Render queue, 2026-11-23, Release build on the built-in display, the
same 600 scroll steps (4.8 s of input) over the 1.1 MB document, ten runs
each in two sittings:

| | Frames on the main thread | Frames on the render queue |
| --- | --- | --- |
| Time to finish the scroll | 5.7–10.0 s | 5.5–5.6 s |
| Main thread in the display link callback, total | 0.8–4.5 s | 10–14 ms |
| Longest such call | 7–41 ms | 0.1–0.2 ms |
| Longest gap between two frames | 18–51 ms | 18–30 ms |
| CPU time of the process | 2.5–3.5 s | 2.4–2.9 s |
| Memory after the scroll | 200–212 MB | 202–210 MB |

Launch time and memory at rest (`bench/app.py`) did not change.

Frame rate, 2026-11-23, on the built-in 120 Hz display. Callbacks a
second of each clock, in a small test program: `NSView.displayLink` 64
(also with a request for 120, and also from a window or a screen),
`CVDisplayLink` 130, `CAMetalDisplayLink` 123 to 128. In the app, a
keyboard scroll of 14 pages: with `NSView.displayLink` all 172 frame gaps
were 16.7 ms; with `CVDisplayLink` 314 of 322 are 8.3 ms. A screen
recording of the maintainer's trackpad scroll before the change showed 55
updates a second, one in five late by a refresh.

GPU memory, 2026-11-23: while frames are drawn, the app's footprint has
about 89 MB of GPU driver memory that is not ours (the device reports 14
to 36 MB for our buffers and textures). Five seconds after the last frame
it is gone: 117 MB before a scroll, 215 MB right after it, 123 MB at rest.
So "memory after the scroll" above is the moment of work, not what the
app keeps.

Launch of a long document, 2026-11-23, Release, from the launch
signposts: the step before the window shows took 39 ms for a 9 KB
document and 232 ms for the 1.1 MB one, because the sidebar outline and
the inspector numbers were made there on the main thread. They are now
made off the main thread for a document above 64 KB: that step takes 4 ms,
and launch to first frame went from 889–899 ms to 645–653 ms, the same as
a short document.

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
- The document model of a 1 MB source takes about 20 MB of heap, and the
  app process holds about 45 MB more for the long document than for the
  short one outside the core. Neither was looked at yet.
- The full layout still runs for every block (about 0.3 s of CPU for 1 MB,
  in steps), because the page height comes from it. A layout that starts
  with estimated heights would remove that; it makes the scroll bar less
  exact, so it needs the maintainer's word first.
- The End key and Select All still lay out the rest of the document on
  the main thread, in one call.
- The core has no way to call the host yet (open a link, load an image).
  It needs a callback struct given at creation.

Found by a quality review of the full core on 2026-11-23 and not done
yet. The first group changes the design, so each needs the maintainer's
word; the second group is speed and memory with a measured or estimated
gain.

Design, before the features that need it:

- **Containers are two counters.** A block knows only `list_depth` and
  `quote_depth`, so a list in a quote and a quote in a list are the same
  block, the quote bar of a list in a quote is one level too far right,
  and a quote with two paragraphs has a gap in its bar. Alerts (a quote
  with a kind and a title) and footnotes (a numbered container) do not fit
  two integers. Form: a list of containers in the document, and a
  container number in each block. Before alerts and footnotes.
- **A selection position is a layout address** (`Position{order, index}`).
  Copy and Select All need the full layout for it, empty code lines use up
  a number with no paragraph, and links, Find, footnote jumps, and
  accessibility all need document addresses. Form: `{block, cell, byte}`
  in the `document` package. Before links.
- **Layout records hold resolved colors**, and `mdcore_style` is mirrored
  field by field in three places. A change of colors alone (light, dark, a
  theme) throws the layout away. Form: color roles in the records,
  resolved in `display`; the style compares its geometry and clears only
  the display list for a color change. Before code colors.
- **The host must call `mdcore_resize` after a new style or document**, or
  the next draw shows nothing. Form: one private `ensure_layout` in the
  core that every entry calls.
- **`mdcore.odin` holds the view's state** (the shown and kept window and
  its rules), which can be tested only through a real Metal layer, and a
  view cannot exist without a surface. Print, export, and accessibility
  need one. Form: a `view` package, and a create call that takes the host
  struct with an optional surface.
- **The host pairs the native view with the web view in about ten
  places**, and the zoom lives in the web view. Form: one reader protocol
  for both, with the first feature that needs a second branch.
- **Images and links**: the parser counts an image but drops its source,
  and a link's target is cloned but not used. md4c has no footnotes or
  alerts, so both need a pass in `parse.odin` over its output.
- The marker of a list item has its place from a switch on the block kind
  with each kind's padding repeated, and the first-line height of a block
  is written in two or three places for each kind.
- `layout.Font_Kind` is a middle step between a span's style and a font;
  `text.Font_Kind` is another enum with the same name.
- The page padding formula is copied from `ReaderLayoutSetting` (the web
  path cuts it to an integer, the native one does not), and the fall-back
  colors of `NativeRendererStyle` repeat the stylesheet's.

Speed and memory (the 1.1 MB document):

- `decorate_line` asks CoreText for the x of each inline code and strike
  span at layout time, for all lines. The first such call on a line costs
  more than shaping the line: 24 % of the layout's CPU (measured). Take
  the x from the glyph runs, or make these decorations in `display`.
- The document model is about 9.6 MB (measured, before the cut of the
  growth slack in this change). A block is 240 bytes and carries the
  table fields; a text is two heap blocks. One byte buffer and one span
  array for the document, and small integers, would bring it to about
  2 MB (estimated).
- The frame that makes new quads shapes the lines that came into view:
  2 ms before the window, 4 to 6 ms with it. Shape one view ahead in the
  time-boxed step between frames.
- All quads of five view heights are made again when the view moves one
  and a half, with a new GPU buffer each time. Strips of one view height
  would keep 70 % of them.
- A table cell is shaped two times (natural width, then lines), and each
  bullet and each code line makes a paragraph object that is released at
  once outside the window: 6 to 7 % of the layout.
- Layout records are 64 bytes for a paragraph and for a line; 40 would do.

Task check boxes, left on purpose:

- A checked task sets the whole document again, and the view keeps its
  scroll offset in points. Far down a long document the first draw then
  lays out everything above the reader on the main thread. A change of the
  one block's state in place, and a scroll anchor in the document in place
  of an offset, would remove both.
- A scroll through a document that is all tasks costs 13 to 27 ms of
  main-thread time more for each Page Down (`BENCHMARKS.md`). The cost is
  in the system's check box. A lighter control, or boxes that are placed
  some at a time between frames, would lower it.
- The check box has no accessibility label (a new string that must go
  through translation), and the keyboard cannot reach it.
- The system moves the check boxes with the scroll view; the text is drawn
  by the render thread. A box can be one frame ahead of its text. Not
  measured.
- `Block.done` and `Block.task_line` are on each block of an item; they
  belong to the item when the model gets containers.
- The view finds out that the layout moved from the page height and
  from a range that it clears by hand after a new layout. A revision
  number of the layout from the core would replace both, also for later
  features that move blocks (images that load).
- `ContentViewController` keeps the scroll place when the same file opens
  again (`isSameFile`). That is a guess of the caller's intent, and a third
  scroll channel beside the two that the web view has. One scroll intent
  on `display` (top, keep, anchor, target) for the two renderers would
  replace it.
- The task is known by its source line, which the parser counts from
  md4c's byte offset, because the app's toggle takes a line. A byte offset
  in the model and in the C API would follow the rule for text offsets.
- The buttons of one view above and below are made before the first frame
  shows. Not measurable at launch so far (`BENCHMARKS.md`).
- `first_task_below` is the same search as `first_box_below`; one helper
  for the two is not made yet.
- The core draws no box of its own. A host without a control (the
  benchmark program, another platform) shows a task with no box.

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
- **2026-11-23** — The first record showed 133 MB of heap for a 1 MB
  document. The cause: every paragraph and line of the document kept its
  text system objects. A terminal's scrollback gave the model: all
  content stays in a compact form, and the costly work (shaping, GPU
  cells) is done only for the rows in view. The same split here: records for all blocks, shaped text
  only near the view. Heap 133 MB to 28 MB. First stacked pull request.
- **2026-11-23** — Frames moved to a render queue, after a test that the
  maintainer asked for before the change ("we need to test with memory,
  CPU and everything else"): the main thread is free during a scroll, and
  CPU and memory do not change. Second stacked pull request.
- **2026-11-23** — A trackpad scroll of a long document was rough. A
  recording of the maintainer's scroll and a sample of the main thread
  showed the cause outside the renderer: the toolbar's share item counted
  the words of the document at each validation. Lesson for tests: a
  scroll made by code sends no events and does not show such a stop.
- **2026-11-23** — The 250 ms that a long document added to the launch
  was the sidebar outline and the inspector numbers, made before the
  window shows. Moved off the main thread for large documents.
- **2026-11-23** — The maintainer decided to keep the render thread. His
  screen recording showed the page at 60 frames a second on a 120 Hz
  display. The cause was the clock: AppKit's display links fire at 60
  there. The frames now come from a `CVDisplayLink`, on its thread.
- **2026-11-23** — The maintainer asked for the quality review on every
  pull request of the stack. The one on the first pull request read the
  full core as it stands. Its safe cleanups went into one pull request on
  top of the stack (the later ones had changed the same files); its design
  and speed findings are in Open work.
- **2026-11-23** — The maintainer saw the text run ahead of the window
  edge in a live resize. The frame for a new size went to the screen at
  once, one step before the window's own change. It is now drawn on the
  main thread and presented with its transaction.
- **2026-11-23** — Task check boxes. A first version drew the box in the
  core, a second one placed a picture of the system's box. The maintainer
  wanted the real control: the core now leaves the place empty and gives
  the host the tasks near the view (`mdcore_tasks`), and the view puts an
  `NSButton` on each. A copy of the web view's box drawing was tried and
  dropped the same day: the system's own look stays. The core's own box
  drawing went away with it.
- **2026-11-24** — The maintainer saw that the toolbar no longer showed
  the page through it. The native view started below the toolbar, so
  nothing was under it. On macOS 26 the view now goes up to the top of the
  window, and its owner gives it the height of the strip that the toolbar
  covers (`topInset`), the same value that the web view gets.
