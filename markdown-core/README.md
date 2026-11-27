# Markdown core

The native renderer of Markdown Preview, written in
[Odin](https://odin-lang.org). It parses a Markdown document, lays it out,
and draws it on the GPU, without a web view. The app shows it when
**Settings → Advanced → Use the experimental native renderer** is on; the
web view stays the default renderer until this one has all of its features.

The core is a static library with a C API. It knows nothing about the app:
a host gives it a surface to draw into, a style, and a document, and sends
it the scroll position and the pointer.

```
markdown-core/
  include/         the C API: mdcore.h, and a module map for Swift
  src/
    mdcore.odin    the C API's implementation: the state of one view
    base/          types that all packages share: colors, quads, the style
    document/      the parser and the document model
    text/          fonts, line breaking, glyph bitmaps, the glyph cache
    layout/        places of blocks and lines, the display list, the selection
    renderer/      draws the display list on the GPU
  pkg/md4c/        the Markdown parser (C) with one change, built into the library
  build.sh         builds libmdcore.a
  test.sh          runs the unit tests
  bench/           the benchmark programs (the core alone, and the app) and their documents
  BENCHMARKS.md    the main numbers over time, and how to measure them
  AGENTS.md        state, decisions, open work, and timeline of the project
```

## How it works

| Step | Package | What it does |
| --- | --- | --- |
| Parse | `document` | md4c reads the source; the result is the blocks of the document with styled text, with no fonts, colors, or sizes. The blocks are in parts of about 60, each part one piece of memory. The document keeps the source, and each block knows its lines of it |
| Change | `document`, `layout` | a change of the source is a range of it and a text (a full new text is the case where the core finds the range). Only the blocks around the range are parsed, when that gives the document of the new source, and they are compared with the old ones block by block, from the two ends; the blocks at the start and at the end that are the same stay where they are, and the parts of what is between them are made and laid out again |
| Lay out again | `layout` | after a change that leaves the number of blocks (a key in a block), only the records of the changed blocks are made again; the other blocks of the part keep theirs and move by what the new text is higher |
| Lay out | `layout` | gives every block, line, and decoration a place on the page, for the part of the page that the view shows. What nobody looked at has a height that is estimated from its text, so the first frame, a new width, and a jump to the end cost the work of one view. The records are kept for each part of the document by itself, and a height in them counts from the top of that part |
| Keep | `layout` | keeps the shaped text only for the lines near the view, and shapes a line again when the view comes to it, so the largest part of the memory does not grow with the document (the document model and the records of the blocks still do) |
| Show | `layout` | makes the quads (the display list) of the part of the page around the scroll position only |
| Draw | `renderer` | draws rectangles, then the selection, then one quad for each glyph |
| Type | `document`, `mdcore.odin` | the caret of an editor is an offset in the source. The core finds where a piece of the text of a block is in the source, and back, by a parse of the lines around that block when it is asked for. A typed text goes into the source at the caret, as each other change does |
| Move | `document`, `layout`, `mdcore.odin` | a key moves the caret by a character or a word (in the text of the document), by a line or to an end of one (in the layout), or to an end of the document. The caret then goes to the first place from there that the source has room for. With the selection, the caret is the end of it that moves |
| Select | `document`, `layout` | a selection is two addresses in the document; Select All and the copied text read the document, with no layout. The layout finds the address at a point and makes the highlight on the lines that show |

A package uses only the packages before it in the folder list, and `base`
uses none. `mdcore.odin` uses all of them.

### Platform code

Two packages have a part for each platform, in files with the platform in
the name. Everything else is the same on every platform.

| Package | Shared | Apple systems |
| --- | --- | --- |
| `text` | `text.odin`, `atlas.odin` | `coretext_darwin.odin` (CoreText) |
| `renderer` | `renderer.odin` (what a backend must have) | `metal_darwin.odin`, `shaders/quad.metal` (Metal) |

A port to another platform adds one file to each of the two. The text
backend works in UTF-8 byte offsets for the rest of the core, whatever its
own text system counts in.

The host of this app is
`md-preview/Features/NativeRenderer/NativeRendererView.swift`. It owns the
view, its `CAMetalLayer`, the scroll position, and the input events. It
draws the frames on a queue of its own, so the main thread stays free for
events; `include/mdcore.h` says which calls can come from which thread.

## Build

The app target's **Build Markdown Core** phase runs `build.sh` before the
link, for the architectures of the build, and the app links the result. It
needs the Odin compiler and Xcode's C and Metal compilers:

```bash
brew install odin
```

To build the library by hand:

```bash
ARCHS="arm64 x86_64" markdown-core/build.sh /tmp/mdcore   # → /tmp/mdcore/libmdcore.a
```

The library has no dependency on the app. The parser is inside it, with
its public names changed, so a host that links another Markdown parser has
no symbol conflict.

## Test

```bash
markdown-core/test.sh
```

The tests are next to the code (`*_test.odin`) and need no window: the
parser's are plain data, and the layout's use the text backend. Add a test
with each change to the parser or the layout.

## What it does not do yet

Images, math, diagrams, syntax colors, footnotes, alerts, raw HTML, links
that open, Find, a click in the outline and its active heading (the core
gives the headings of the outline, `mdcore_outline`), the table of front
matter (front matter at the top of a file does not show), print, export,
and VoiceOver.

Edit Mode has its first form: a click puts a caret in the text, and the
reader types, deletes the character before the caret, pastes, and
saves. Return starts a new paragraph, a new item in a list, or a new
line in code, and the caret is in the new line at once. A line of the
source with nothing in it shows as an empty line of the page (each but
the last one before a block), in Read mode and in Edit Mode. The arrow keys move the caret
(with Option by a word, with Command to the ends of a line and of the
document), and with Shift they select. Typed text, a paste, and Return
take the place of the text that is selected; Delete and Cut take it out.
The delete keys of the system work: forward (Fn-Delete, Control-D), by
a word (with Option), to the ends of the line (with Command), to the
end of the paragraph (Control-K, with Control-Y to put it back), and
Delete at the start of a block joins it with the block before.
Control-T changes the places of two characters, and Command-Shift-K
takes the line of the source out. Undo and Redo (Command-Z and
Shift-Command-Z) take each change back and make it again: characters
that are typed or deleted in a row are one step, and Undo of a change
over a selection selects that text again. It does not have the
formatting bar, images that are pasted, or a caret in a table cell with
no text. Some selections have no edit yet, so typed text, a paste,
Return, Delete, and Cut do nothing with them: one with an end in code
or in a table and the other end in another block, and one over two
cells of a table (but when all of the text of those blocks or of the
table is selected, as with Select All). The marks of
bold, italic, and struck text, of code, and of a link (with its
target) show in gray while the caret is in their text or at an end of
it, so the caret has a place on each side of a mark and a delete can
take a mark. They do not show while text is selected (but a selection
of only characters of those marks keeps them) and while the window
does not have the keys. The mark of a block shows in the same way, before its text, while the
caret is in the block: the "#" of a heading and the ">" of a quote. So
a reader changes the level of a heading or makes a paragraph of a quote
with the keys. A list item keeps its bullet, number, or check box at
the caret too, as in other Markdown editors: a mark with nothing after
it ("-", "1.", "- [ ]") is plain text where it is typed, and the space
after it makes the list item. Return in an item with no text ends the
list, and a list that is started after empty lines below another list
gets the other mark ("*" for "-", "1)" for "1."), so it stays a list of
its own. The ">" of the later lines of a quote, a code fence, and the
line under a heading do not show yet.
