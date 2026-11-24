# Benchmarks of the native renderer

The main numbers of the native renderer, recorded over time, so that each
new feature shows what it costs. Add a row when a pull request changes
`markdown-core/` or the host view. Do not edit old rows.

## How to measure

Two programs. Both use `bench/short.md` (9 KB, most block kinds) and a
long document that is `short.md` 128 times (1.1 MB). Both print the median
of five runs as a table.

```bash
markdown-core/bench/core.py                         # the core alone, no window
markdown-core/bench/app.py <Markdown Preview.app>   # the app, cold launch; add --renderer web to compare
```

- **`core.py`** builds the core and `bench/bench.m` and runs the core
  through its C API in a new process each time: the first frame, the layout
  of the rest, two scroll passes of 24,000 points (the first makes the
  glyph bitmaps, the second has them), a jump back to the top between
  them, and the heap. It takes a minute and
  shows no window. A scroll frame is CPU time of the drawing thread, because
  a draw waits for the display.
- **`app.py`** starts a Release build of the app with a document, in the
  background, and measures from the `open` command to the signpost of the
  first document frame (`nativePaint`, or `webPaint` for the web renderer).
  Three seconds later it reads the CPU time and the memory footprint of the
  app process. Its windows open behind the front app. Use a copy of the app
  with its own bundle identifier, so the run does not use the settings of
  the installed app.

The numbers depend on the Mac and on what else runs on it: a second run on
a busy Mac gave core times twice as long. To judge a change, measure the
base and the change one after the other on the same Mac, and compare those
two. Use the table below to see the direction over months.

With the web renderer most of the work is in WebKit's helper processes,
which `app.py` does not count. Compare its first frame with the native
one; do not compare its CPU and memory.

## Main numbers

Short / long document. M3 Pro, 36 GB, macOS 27.0.

| Date | Commit | App: launch to first frame (ms) | App: memory (MB) | App: CPU to 3 s after (ms) | Core: first frame (ms) | Core: layout of the rest (ms) | Core: scroll frame, new glyphs / ready (CPU ms, long) | Core: heap at the end (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-11-23 | a29a58e9 | 684 / 960 | 64 / 235 | 510 / 1460 | 69 / 46 | 3.3 / 299 | 0.36 / 0.33 | 10.8 / 133 |
| 2026-11-23 | shaped text only near the view | 647 / 918 | 65 / 111 | 505 / 1245 | 59 / 65 | 3.0 / 311 | 0.34 / 0.32 | 10.6 / 28.1 |

The web renderer in the same build on the same day as the first row, for
the first frame only: 945 ms for the short document, 13,283 ms for the
long one.

## Shaped text only near the view (2026-11-23)

Measured against its base in the same sitting, two times each. The base
in that sitting: app launch 665 / 872 ms, app memory 64 / 214 MB, core
scroll frame 0.34 / 0.32 CPU ms, heap 10.9 / 133 MB.

- The heap of the long document went from 133 MB to 28 MB, and the app's
  memory with it from 214 MB to 111 MB. The short document does not change.
- The mean scroll frame, the launch time, and the layout time did not
  change beyond the noise.
- The frame that makes new quads now also shapes the text that came into
  view: the longest frame with the glyphs ready went from 2 ms to 4 to 6 ms
  of CPU.
- `core.py` has a new number from this record on, the frame after a jump
  to the top: 1.2 ms on the base, 3.5 to 4.1 ms now.

## What the first record shows

- The first frame of the core does not grow with the document: the layout
  runs in steps. The first frame of the short document includes the start
  of Metal and of the fonts, which changes from run to run (35 to 69 ms).
- The app needs about 280 ms more to show the long document than the short
  one. The first frame of the core does not account for it; where the app
  spends it is not found yet.
- The heap is about 120 bytes for each byte of the source after the full
  layout. The app's memory for the long document follows it.
- The longest scroll frame was 9 ms of CPU with new glyphs and 2 ms with
  the glyphs ready.
