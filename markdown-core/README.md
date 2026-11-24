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
  pkg/md4c/        the Markdown parser (C), built into the library
  build.sh         builds libmdcore.a
  test.sh          runs the unit tests
  bench/           the benchmark programs: the core alone, and the app
  BENCHMARKS.md    the main numbers over time, and how to measure them
  AGENTS.md        state, decisions, open work, and timeline of the project
```

## How it works

| Step | Package | What it does |
| --- | --- | --- |
| Parse | `document` | md4c reads the source; the result is the blocks of the document with styled text, with no fonts, colors, or sizes. The blocks are in parts of about 60, each part one piece of memory |
| Lay out | `layout` | gives every block, line, and decoration a place on the page, for the part of the page that the view shows. What nobody looked at has a height that is estimated from its text, so the first frame, a new width, and a jump to the end cost the work of one view. The records are kept for each part of the document by itself, and a height in them counts from the top of that part |
| Keep | `layout` | keeps the shaped text only for the lines near the view, and shapes a line again when the view comes to it, so the largest part of the memory does not grow with the document (the document model and the records of the blocks still do) |
| Show | `layout` | makes the quads (the display list) of the part of the page around the scroll position only |
| Draw | `renderer` | draws rectangles, then the selection, then one quad for each glyph |
| Select | `layout` | hit testing, the highlight, and the copied text |

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
that open, Find, Edit Mode, the outline, print, export, and VoiceOver.
