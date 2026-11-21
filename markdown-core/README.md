# Markdown core

The experimental native renderer of Markdown Preview, written in
[Odin](https://odin-lang.org). It parses a Markdown document, lays it out,
and draws it on the GPU, without a web view. The app shows it when
**Settings → Advanced → Use the experimental native renderer** is on; the
web view stays the default renderer until this one has all of its features.

```
markdown-core/
  include/           C API that a host app calls: mdcore.h, and a module map for Swift
  src/               Odin source (package mdcore) and the Metal shaders
  build.sh           builds libmdcore.a
```

## How it works

| Step | Code | Done by |
| --- | --- | --- |
| Parse | `src/parse.odin` | cmark-gfm, plus a small table scanner |
| Lay out | `src/layout.odin` | CoreText shapes the text and breaks the lines |
| Cache glyphs | `src/atlas.odin` | CoreText draws each glyph once into a texture atlas |
| Draw | `src/gpu.odin`, `src/shaders.metal` | Metal draws one quad per glyph |
| Select | `src/select.odin` | hit testing, the highlight, and the copied text |

The host app owns the view, its `CAMetalLayer`, the scroll position, and the
input events, and calls the functions in `include/mdcore.h`. In this app the
host is `md-preview/Features/NativeRenderer/NativeRendererView.swift`.

The layout, the glyph cache, and the drawing use CoreText and Metal, so the
core builds for macOS only today. The parser and the document model do not
depend on the platform.

## Build

The app target's **Build Markdown Core** phase runs `build.sh` before the
link, for the architectures of the build, and the app links the result. It
needs the Odin compiler and Xcode's Metal compiler:

```bash
brew install odin
```

To build the library by hand:

```bash
ARCHS="arm64 x86_64" markdown-core/build.sh /tmp/mdcore   # → /tmp/mdcore/libmdcore.a
```

The parser functions (`cmark_*`) are not in the library. They come from the
cmark-gfm copy that the app already links through swift-markdown.

## What it does not do yet

Images, math, diagrams, syntax colors, task list boxes, strikethrough,
footnotes, alerts, raw HTML, links that open, Find, zoom, themes and dark
mode, the reader settings, Edit Mode, the outline, print, export, and
VoiceOver.
