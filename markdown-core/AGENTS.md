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
- **The base carries an editor before the reader gets its missing
  features** (2026-11-24). The editor of the app is to move to this core
  later. So the structure that an editor needs (a change to one block
  that costs the work of one block, text that is laid out where the view
  is and not from the top, addresses that stay true through a change)
  comes first, and links, Find, footnotes, images, and code colors come
  after it. The reason: a base made for a reader only would be made
  again for the editor, and that second time costs speed. See "The base
  for an editor" in Open work.
- **A reader at the end of the document is kept by the first line that
  shows, as at each other place** (2026-11-24). With a narrower window the
  end then goes out of view. Browsers and editors do the same; only a
  view of text that grows (a terminal, a log) keeps the end. Do not add a
  rule for the end to a resize.
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
- `pkg/md4c` is a copy of upstream with one change, which is also there
  as a patch file: the parser says where in the source each block starts,
  where each definition of a link is, and what each use of one counts
  for in its limit (`pkg/md4c/README.md`). Do not add another change, but for something
  that only the parser knows and that the core cannot do without.
- The document keeps its source (`Document.source`), and each block has
  its range of it (`document.block_source`): from the start of its first
  line to the start of the next block's first line, so the ranges of all
  blocks are the source. The first block of a list item or a quote
  starts at the line of their mark. An offset in a block (`Block.source`,
  `Block.task_mark`) counts from the start of its part (`Part.source`),
  and a part has the number of lines before it (`Part.line`): an edit
  then moves all that is after it with two numbers for each part. Read
  an offset through `block_start` and `task_line`, not from the field.
  The source is always
  the text of the blocks: code that changes a block in place changes the
  source too (`set_task_done`). A field of a block that a layout reads
  goes in `document.Shape` (one value) or beside the texts of `Block`
  (and in `layout_equal`); all other fields are below them, and a change
  to one of those needs no new records.
- A change to the parser or the layout comes with a unit test
  (`*_test.odin`), and `markdown-core/test.sh` must pass.
- Every block keeps its small records (place, line ranges and widths,
  decorations) for the full document. Only the lines near the view keep
  their shaped text, the text system's paragraph and line objects
  (`layout/window.odin`). Code that reads glyphs or a caret's x takes its
  line from `shaped_line`, which shapes it again when needed.
- A caret, the ends of a selection, and the place of a view are addresses
  in the document (`document.Address`: block, cell, byte), not in a
  layout. Work on the text of a range (the copied text, Select All, later
  Find) reads the document (`document.text_between`) and needs no layout;
  the selection itself is a type of the document (`document.Selection`).
  Only what is drawn (the highlight on the lines that show) reads the
  records.
- The blocks of the document are in parts (`document.Part`), and the
  layout keeps its records for each part by itself (`layout.Part`). A
  height in a record (a line, a box, a decoration, a task) counts from
  the top of its part; only `Part.top` is a height of the page, and it is
  a 64-bit number. Do not put a height of the page in a record: then a
  block that gets another height is a change to each record below it.
  What must stand on a whole point or a whole pixel is put there on the
  page (`page_pixel`, `tasks_between`), not in the part, or it moves by a
  fraction when the part does.
- The layout is made where the view is, and a part that nobody looked at
  has an estimated height and no records. Code that needs records calls
  for them first (`lay_out`, `lay_out_block`) and says
  what must stay in place (the anchor): text at the anchor and below it
  keeps its height on the page, and the top of the page (`origin`) moves
  for a part above it. Do not lay out from the first block down to reach
  something, and do not read a height of the page as if it started at 0.
- The source of the document changes in one place, `change_source` in
  `mdcore.odin`: a text takes the place of a range of the source
  (`document.Edit`). A key that an editor types is that call
  (`mdcore_replace_text`), and a full text is the case where the core
  finds the range itself (`mdcore_set_markdown`, `edit_between`). Only a
  task that is set changes the source in place with no edit. Do not add
  a second way in: what comes after an edit (the place, the selection,
  the layout of the parts that changed) is there one time. A call
  that changes the source holds `source_lock` from its edit to its end,
  so an edit is of the source that is there; the parse runs with only
  that lock, which no frame takes.
- An edit parses a piece of the source, not all of it (`document.prepare`,
  then `commit`). The result must be the document that a parse of all of
  the new source gives, each time; the tests compare the two for each
  of some thousand random edits, and a change to this code runs them.
  What makes a piece right:
  - It starts at a block that is in no list and no quote (or is the
    first of one): the lines before such a block do not change what it
    is. One such block earlier when the edit is in the first line of
    its block, because that line can become a part of the block before.
  - It ends at a block start after the edit, and has two blocks more
    (`GUARD_BLOCKS`). Those two must come out as they were, at their
    place. If the edit opened something that takes the text after it (a
    code fence, a raw HTML block, a list that the next lines go into),
    they do not, and all of the source is parsed. The two are only
    compared: the document keeps its own blocks there. They show that
    they are as they were, not that the lists around them are: a list
    that the edit makes can go on in the list after it, and then later
    items have other numbers. So a block in a list is compared only
    when it is the first block of its list (`List_Start`).
  - A definition of a link changes text at any distance. The piece is
    parsed with the definitions of the rest of the document that it
    can use (the first word of the name is the first word in a pair of
    brackets of the piece), and its own definitions must come out with
    the text they had: an edit that makes, changes, or takes out a
    definition is a parse of all. The parser takes two names as one by
    rules for all of Unicode; a name with a byte that is not plain
    ASCII counts for each piece, and a piece with such a name gets each
    definition.
  - The parser has a limit for the uses of definitions that is of the
    size of the text it parses (16 times, 1 MB at most). A piece is
    right only when each of its uses had room in the limit of the
    piece, and a parse of all has room for each use of the document
    (`Document.defs_used`, which an edit adds to and takes nothing off,
    so after many edits one of them is a parse of all).
  - What a parse numbers from the start of the document is made right
    for a piece: list items get numbers after the last one of the
    document (`Document.items`), links go to the end of the list of
    links, and the limit for the cells of a table is the one of all of
    the source. Do not end the
  layout for a new text: `document.replace` keeps the blocks at the start
  and at the end of the document that are the same for a layout at their
  address (`adopt`), and `layout.apply_change` keeps the records of each
  part that was not made again. All between the first and the last
  block that changed is made again, also a block there that did not
  change. Code that
  holds an address through a change takes its new one from
  `document.moved` (an address in the blocks that changed goes to the
  start of them). The parse of the new text runs before the core takes
  its lock, and what is left of the two texts is freed after it. What a block says that a layout does not read (the
  line of a task, the number of a link) is not part of "the same".
- The core keeps the reader's place: the first line that the view shows
  below the strip that the host covers (`mdcore_set_top_inset`). The host
  says its scroll offset each time it changes (`mdcore_note_scroll`,
  which never waits). Each core call that ends or changes the layout
  takes the place first, from the layout that is still there
  (`take_place` in `mdcore.odin`), and a new layout of the same document
  puts it at the height of the page that it had (`restore_place`). So a
  host draws at the offset that it has after a new width or style, and
  carries no place. A new call that changes the layout calls
  `take_place` first; the host needs no new call for it. A frame does
  not take the place: the steps of a live resize would add up.
- A host gives its scroll area the top and the height of the page
  (`mdcore_page_area`), and takes the two again when
  `mdcore_layout_revision` changed. A scroll to the top or to the end of
  the document is a scroll to a fixed place (`mdcore_draw_toward`,
  `mdcore_layout_end`); a scroll by a distance is not.
- The layout changes its sums and ranges in place. `layout.check` looks
  at all of them and says what is wrong; a new test of the layout calls it
  after each change, and a build with `-debug` calls it after each `lay_out`.
- A block is reached through its part (`part.blocks[slot]`) in a loop,
  and by its number (`document.block_at`) for one block. The number of a
  block is not an identity: it will change when a block is added above
  it.
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
- Frames run off the main thread, and the layout that they need runs
  in them. A draw can wait for a
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
  `frame_draw` after it). A new export calls `hold`. The one exception is
  `mdcore_pointer_shape`, which the main thread calls for each move of the
  pointer: it tries the lock and says "busy" when it does not get it. Code after the block
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
that changes the core or the host view, measure the base and the change
one after the other, and add a row: `app.py` for each such pull request,
and `core.py` when files of the core changed. A run of `core.py` for a
change with no core code measures the same program two times; leave it
out and say so in the section. For a feature that the two benchmark
documents do not contain (tasks, tables in number), measure a document
that is full of it too.

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
- A part with one very long block (a code block of thousands of lines) is
  laid out from its first line. A view that comes into it from below, or
  a jump into its middle, lays out all of it down to the view in one
  frame. Code lines in parts of their own would remove it.
- The height of a part that is not laid out is estimated from the size of
  its text and a mean width of a character (`estimate_block`). For five
  documents the page height was within 1.3% of the real one
  (`BENCHMARKS.md`); text of wide characters and a narrow column are
  farther off. The scroll bar moves by that difference when the reader
  comes to such a part.
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

The window around the page, left on purpose:

- Find does not search in the native renderer: the search runs in the web
  view, which has no page then, and the find bar says "Not found".
- When the reader comes back from Edit mode with the search open, the
  page goes back to another place. Left as it is: Edit mode is to move to
  this core.
- Not checked on macOS 26.1 to 26.x, where the find bar is an accessory of
  the split view, and on macOS 15, where the view starts below the
  toolbar and a find bar lies over its first lines.

Task check boxes, left on purpose:

- The core keeps the reader's place across a new width or style, and
  across a change of the text. A place in the blocks that changed goes
  to the start of them.
- "The same for a layout" compares the number of an ordered list item,
  because the marker is drawn from it. So one item more near the top of
  a long numbered list makes all items after it again. `layout_equal` is
  a list of fields kept by hand: a `Block` in two parts (what a layout
  reads, and what is read when the page is drawn) would make it one
  comparison, and gives the source range of a block its place.
- A place is an address in the document: block, cell, byte. Find, a jump
  to a footnote or a heading, and the way back from Edit mode can use
  it; none of them does yet.
- After a click on a task the app makes the sidebar outline and the
  inspector numbers again for the full document, off the main thread
  (0.3 s of CPU for 725 KB). Neither changes with a task mark. This is in
  the app, for the two renderers.
- A scroll through a document that is all tasks costs 13 to 27 ms of
  main-thread time more for each Page Down (`BENCHMARKS.md`). The cost is
  in the system's check box. A lighter control, or boxes that are placed
  some at a time between frames, would lower it.
- The check box has no accessibility label (a new string that must go
  through translation), and the keyboard cannot reach it.
- The system moves the check boxes with the scroll view; the text is drawn
  by the render thread. A box can be one frame ahead of its text. Not
  measured.
- `Block.done` is on each block of an item, and
  `Block.item` says which item that is (a number from the parser). The
  two belong to one item record when the model gets containers.
- `ContentViewController` keeps the scroll place when the same file opens
  again (`isSameFile`). That is a guess of the caller's intent, and a third
  scroll channel beside the two that the web view has. One scroll intent
  on `display` (top, keep, anchor, target) for the two renderers would
  replace it.
- The task is known by its source line in the C API, because the app's
  toggle takes a line. The model has only the byte offset
  (`Block.task_mark`) and counts the line from its part when asked. A
  byte offset in the C API would follow the rule for text offsets.
- The heap depends on the size of a block in a way that is not
  explained: with a block of 280 bytes (58 in a part) the benchmark
  shows 1.6 MB less heap for 1 MB of text than with one of 264 bytes (61
  in a part), on the base and on this change. The two parts are in the
  same size class of the system (16 KB), and a part with 58 blocks of 264
  bytes does not show it. The block has 264 bytes now. Find the reason
  before the next change to the size of a block or of a part.
- The parse of 1 MB leaves about 9 MB of memory that is free but still
  counts for the process (footprint +16 MB, in use +7 MB): what md4c
  and the growing arrays needed for a moment.
- A block has the lines after it that are no block (raw HTML, the
  definitions of links, empty lines) in its range of the source, and the
  first block also the ones before it. An editor needs a rule for a
  caret in those lines.
- The buttons of one view above and below are made before the first frame
  shows. Not measurable at launch so far (`BENCHMARKS.md`).
- The core draws no box of its own. A host without a control (the
  benchmark program, another platform) shows a task with no box.

The base for an editor (the maintainer's direction of 2026-11-24, see
Decisions). Four things an editor needs that a reader does not, with
what is there and what is next:

1. **Where the text lives.** Done: the document keeps the source, and a
   block knows its range of it (the start of its first line; the parser
   copy says it). A block still has a copy of its text, because that
   text is not the source: marks are gone, spaces are one space, an
   entity is its character. Not done: the source is one piece of memory
   that each change copies (0.05 ms for 1 MB; not the cost that counts
   while the parse is full).
2. **What a block is.** Done: the blocks are in parts of one piece of
   memory each, so a later change moves the blocks of one part. Not done:
   an identity of a block that stays through a change (a place, a
   selection, and a task still use the number of the block), and the
   procedures that add and remove blocks.
3. **How the layout knows its work.** Done: records for each part by
   itself, with heights from the top of the part; a part for each part
   of the document from the start, with an estimated height while it has
   no records; a layout that is made where the view is (`lay_out`), with
   the top of the page as the thing that moves when a part above the view
   gets its real height. Not done: a part whose text changed (it needs
   its records made again, which `advance` can do, and its state set
   back).
4. **How a change comes in.** Done: one entry for the text of the
   document (`mdcore_set_markdown`, `document.replace`). It compares the
   blocks of the old and the new text, keeps the ones that are the same
   at the two ends where they are, and makes only the parts of the
   others again; the layout keeps the records of the rest. A new
   document is the case with no block in common. Not done: the new text
   is still parsed in full (24 ms for 1 MB), because md4c reads full
   documents only. How to parse only what changed is not decided and
   must be measured first. And the blocks that are the same must be at
   the two ends: a text with two changes far from each other makes all
   between them again.

The order of the next steps, from the review of the second step:

- Done: the selection as a document address, with the copied text
  taken from the document.
- Done: the core keeps the reader's place (`Reader_Place`, taken from a
  frame after a scroll, put back by a new layout). Not done: the layout
  calls of a frame still take their anchor as a part (`lay_out`), so a
  change in the part of the reader, above the first line that shows,
  needs the place there too.
- Done: a changed text makes only its parts again (4).
- Done: the source text is kept and a block knows its range of it.
- Done: a change comes as a range of the source (`document.Edit`,
  `mdcore_replace_text`). No host calls it yet; the benchmark types
  through it. It still parses all of the new source: one typed
  character costs 9 to 10 ms of CPU in 1 MB, with no layout in it.
- In 9 KB a typed character costs 5 ms. That is not the parse: a
  change to one block
  lays out all blocks of its part again (58 blocks at most, with their
  text shaped again).
  A layout that makes only the changed block again is as much needed
  for a key under 1 ms as the parse of what changed. For it, the
  records of a part must let one block's records be put in the place
  of the old ones.
- Done: an edit parses only the blocks around it, and the offsets of
  the blocks count from their part. A typed character in 1 MB: the
  parse side is 0.5 ms (10 ms before).
- Next: a layout that makes only the changed block again. It is what is
  left of a key: 3 to 4 ms when the view shows the part of the change.
- Then: an identity of a block that stays through a change (2).
- The source is one piece of memory, and each edit makes a copy of it
  with the change (about 0.2 ms for 1 MB, the largest part of what is
  left of the parse side). A store of the text that an edit changes in
  place (a gap, or pieces) removes it.
- A piece starts at a block that is in no list and no quote. An edit
  far down a list of some thousand items parses the list from its
  start.
- A document with many definitions of one name (the long benchmark
  document has each of its 25 definitions 128 times) gives a piece all
  of them, when the piece has the first word of the name. The first one
  with a name is the one that counts; the others could stay out.
- The list of links (`Document.links`) gets the links of the blocks of
  each edit and loses none, until the next parse of all. When it is two
  times as long as the last parse of all made it, the next edit is a
  parse of all. Links that belong to their block would need no list.
- An edit that the piece is not right for costs the parse of the piece
  and then the parse of all.
- The first block of a list is `List_Start` only when no other list
  starts in its first item: for "1. - b" the list inside takes the
  mark, and the block gets the space of a later item. A layout fault
  that was there before; and an edit before such a list is a parse of
  all.
- The searches for a place in an ordered list are written out in five
  procedures of `document.odin` now. One helper is not made.

Left on purpose in the first step:

- `document.locate` and `first_part_below` search all parts (a binary
  search). Fine for the 250 parts of 1 MB.
- The search for a place in an ordered list is written out in six
  procedures (parts, boxes, lines, spans, blocks). One helper for all is
  not made.
- An address has the number of its block, which is not an identity yet
  (see 2). It is the one type that the identity changes: a selection, a
  place, and a caret all use it.
- All tops are summed again after each part that got another height
  (`sum_tops`): 250 additions for 1 MB.
- The estimate of a code block reads each of its bytes two times: at
  each new layout (each step of a live resize), and when the block gets
  its box. A line count and a longest line from the parser would make it
  one division. Not measured on a document that is mostly code.
- A view that scrolls through text with no records lays out a piece each
  half view height, and then makes its quads again and asks for the
  check boxes again. The check boxes are asked for after each layout
  change, also one that moved none of them.

Next features after that, in the order that seems best (not agreed with
the maintainer): links that open, images, code colors, Find, the
outline's scroll position, footnotes and alerts, VoiceOver, print and
export.

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
- **2026-11-24** — The maintainer saw the scroll bar jump and come back
  after a click on a task. A first fix kept the height of the page while
  the document was laid out again, which hid the effect. The maintainer
  asked for the cause to be fixed: a click was a new document for the
  renderer. The core now changes the one task in place
  (`mdcore_set_task_checked`), and the view does nothing for the text
  that it shows already. Rule from this: fix the cause, not what shows.
- **2026-11-24** — A check of all review threads of the stack found a
  late review round on the lower pull requests that nobody had answered.
  Its findings went into one pull request on top: the page beside a
  scroll bar that takes room (`mdcore_set_page_width`), the scroll
  actions of the Go menu, a forced layout for a view with no size, and
  the outline's remembered heading after a live edit. The benchmark rule
  above was made exact at the same time.
- **2026-11-24** — The maintainer saw the text cursor around the check
  boxes and in the margin. The cursor is now the text one only on a line
  of text. As in the terminal that the window technique came from, the
  core decides the shape of the pointer and the scroll view shows it as
  the cursor of its document; a link that opens will add a shape. The
  question does not wait for the core's lock.
- **2026-11-24** — The maintainer saw the page through the find bar. The
  web view never had this, because WebKit backs all of its covered strip.
  A first fix put a view of the page color behind the bar; the maintainer
  wanted the translucent look that the toolbar has, and pointed to the
  earlier fixes for the web view. Those use the system's own backing of a
  scroll view's covered edge, and the native scroll view has the same
  one, sized from its safe area. The rest of the covered strip is now
  added to that safe area. Rule from this: before something is built for
  the area around the toolbar, look at how the web view got it, and test
  with the find bar, the tab bar, and Edit mode.
- **2026-11-24** — First step of the base that later features need: a
  place in the document in place of an offset in points. A new width or
  text size showed other text, far down a document many paragraphs away.
  From the terminal that the window technique came from: a position is an
  address in the data, the view keeps one such address until the reader
  scrolls, and the top of the document is its own case. The view now asks
  the core for the place of the first text that shows and for the height
  that this place has in the new layout.
- **2026-11-24** — The maintainer set the order of the work: the base
  must carry an editor first, then the reader gets its missing features.
  First step: the blocks of the document are in parts of 16 KB, and the
  layout keeps the records of each part in one piece of memory, with
  heights from the top of the part. Nothing changes on screen. From the
  terminal that the window technique came from: data in pages of one
  allocation, sums that are changed in place with a full check of them in
  debug builds, and a warning it gives about itself (a walk from the
  first page to find a position). Two things were found by measurement,
  not by thought: the system's allocator gives 20 KB for a part of
  16.9 KB, and it does not give back the spare room of an array that
  shrinks. So a part is a little under 16 KB, and a finished part's
  records are copied once into memory of their exact size.
- **2026-11-24** — Second step of the base: the layout is made where the
  view is. A part that nobody looked at has a height that is estimated
  from its text; the maintainer agreed to a scroll bar that is a little
  less exact for that. Nothing lays out the rest in the background any
  more. A part above the reader that gets its real height moves the top
  of the page, not the text on screen, so the host's scroll offset needs
  no correction at the right moment; the page area of the scroll view
  just gets another range. A selection position got the number of its
  block, so it says the same in a layout that started at another place.
  For 1 MB: the first frame 52 ms (75 before), the End key 8 ms (0.3 s of
  layout before), a new width at the end 10 ms (0.37 s before).
- **2026-11-24** — Third step of the base: a caret and the ends of a
  selection are addresses in the document (block, cell, byte), the same
  type as the place of a view. The copied text and Select All read the
  document, so they need no layout: a copy of all of 1 MB takes 2 ms
  (0.34 s with the layout that it needed after the second step). The
  numbers in reading order that the layout kept for the selection are
  gone.
- **2026-11-24** — Fourth step of the base: the core keeps the reader's
  place. The view had carried it across each new layout with five calls
  and three values of its own; now a new layout puts the first line that
  the reader sees at the height it had, and the view draws at the offset
  that it has. The two place calls of the API are gone. This is the
  form that a change of the text needs: the core must hold the line that
  stays, because only the core sees a change before the view does.
- **2026-11-24** — Fifth step of the base: a changed text changes the
  document in place. Until now each new text was a new document and a
  new layout, also when another app saved one more line. Now the core
  compares the blocks, keeps what is the same where it is, and makes
  one part again for a change in one block. A reader far down a long
  document sees no move when the file gets text near its top. This is
  the entry that an editor types through later; it still parses all of
  the text for each change.
- **2026-11-24** — Sixth step of the base: the document keeps its source
  and each block knows its lines of it. md4c knows the lines of a block
  and gives them to no callback, so its copy here got one change, kept
  as a patch file: a callback with the start of each block. The other
  ways were worse: a guess from the places of the text (wrong for a
  block with no text of its own: an image with no words, an empty item,
  a rule, a fence) or a block parser of our own. A task click now
  changes its mark in the kept source too. `Block` has its fields in
  two groups, what a layout reads and what it does not, so the test for
  "the same for a layout" compares the first group as one value. A text
  that the document has already (the host's own save that comes back)
  is known by a comparison with the kept source and is not parsed. The
  arrays of a text are copied to their exact size, because the system
  keeps the room of an array that is made smaller in place. Cost: 1.1 MB
  of heap for 1.1 MB of source, less 0.5 MB from the exact arrays; no
  time.
- **2026-11-24** — Seventh step of the base: a change of the source is
  a range and a text. One procedure makes each change of the source,
  and the two calls of the API (a full text, a range) are cases of it.
  The parse is still full. Tests make 300 random edits of a document
  and 80 with a layout, and compare each result with a new parse and a
  new layout of the same source: the check that the parse of only what
  changed needs before it is written. The benchmark has the number
  that this work is for: one typed character, 9 to 10 ms of CPU in
  1.1 MB (the parse of all), and 5 ms in 9 KB, where it is the layout
  of the full part for one changed block, not the parse. Two
  threads that change the source at one time are in order by a lock
  for such calls, which a frame does not take.
- **2026-11-24** — Eighth step of the base: an edit parses only the
  blocks around it. The piece starts at a block in no list and no
  quote, and ends two blocks after the edit; when those two do not come
  out as they were, all of the source is parsed, as before. The first
  form sent each document with a definition of a link to the parse of
  all, and the benchmark document, which has definitions as many real
  documents do, had no gain. So the parser copy says where each
  definition is (the second callback of its one change), and a piece
  is parsed with the definitions that its words can use. Offsets in
  the blocks count from their part, so a block after an edit is not
  touched. The random edits of the step before found three faults
  while this was written, and a review that looked for a piece that is
  not the document of its source found three more (a list that goes on
  in the next list, names with letters that are not ASCII, the limit
  of the parser for uses of definitions); each is a rule and a test
  now. A typed character in the middle of 1.1 MB: 1.5 ms of CPU (10.4
  before).
