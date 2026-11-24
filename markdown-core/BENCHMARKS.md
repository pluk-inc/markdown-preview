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
| 2026-11-23 | outline and inspector numbers off the main thread | 648 / 653 | 69 / 103 | 600 / 1090 | – | – | – | – |
| 2026-11-23 | frames from a CVDisplayLink, at the rate of the display | 704 / 717 | 66 / 111 | 575 / 1235 | – | – | – | – |
| 2026-11-23 | cleanup of the core; no growth slack kept in the document model | – | – | – | 60 / 70 | 2.9 / 301 | – | 6.6 / 20.2 |
| 2026-11-23 | task check boxes (system buttons on the page); a resize frame in step with the window | 562 / 543 | 58 / 99 | 460 / 1080 | – | – | – | – |
| 2026-11-24 | the view goes under the toolbar on macOS 26, so the page shows through it | 674 / 592 | 57 / 101 | 510 / 1080 | – | – | – | – |

The web renderer in the same build on the same day as the first row, for
the first frame only: 945 ms for the short document, 13,283 ms for the
long one.

## Native renderer against the web view (2026-11-23)

One Release build (the top of the stack at that time), the renderer chosen
with the launch argument, three runs each, median. "All processes" is the
app and each helper process that it is responsible for; the web view does
most of its work in WebKit's helpers. Not from `app.py`: a script that is
not in the repository yet did the launches, found the helpers, and sent
the key presses.

| 9 KB document | Web view | Native |
| --- | --- | --- |
| Launch to first document frame | 939 ms | 630 ms |
| Processes | 12 | 7 |
| Memory at rest, app process | 75 MB | 65 MB |
| Memory at rest, all processes | 205 MB | 107 MB |
| CPU until 4 s after the first frame, all processes | 2.26 s | 1.73 s |
| CPU for 30 Page Down presses, all processes | 0.74 s | 0.42 s |

| 1.1 MB document | Web view | Native |
| --- | --- | --- |
| Launch to first document frame | 13,881 ms | 611 ms |
| Processes | 12 | 7 |
| Memory at rest, app process | 165 MB | 105 MB |
| Memory at rest, all processes | 653 MB | 147 MB |
| CPU until 4 s after the first frame, all processes | 16.87 s | 2.28 s |
| CPU for 30 Page Down presses, all processes | 7.44 s | 1.18 s |

At rest both use almost no CPU (0 to 4 ms a second). The native window
still has a `WKWebView` object, so WebKit's GPU process is among its
helpers.

Frame rate on the built-in 120 Hz display, in a keyboard scroll of 18
pages, one run each. A capture of the window at 120 samples a second
(ScreenCaptureKit) gave the times at which the window changed; the share
is of the gaps inside the scroll animations.

| | Web view | Native |
| --- | --- | --- |
| 9 KB document: gaps of one refresh (8.3 ms) | 373 of 435 | 361 of 406 |
| 1.1 MB document: gaps of one refresh (8.3 ms) | 9 of 321 | 583 of 606 |
| 1.1 MB document: updates a second while it moves | 44 | 101 |

So for a short document both run at the rate of the display, and for the
long one the web view falls to two or three refreshes for each frame. The
test windows were not the front window, and the scroll came from the
keyboard; a trackpad scroll in the front window was not measured.

## Cleanup of the core (2026-11-23)

Only `core.py`, base and change in turns, two times each. Heap of the
long document at the first frame 17.2 MB before and 13.4 MB after, at the
end 24.2 MB and 20.2 MB: a finished text gives back the room that its
arrays grew ahead (most texts have one span, and the first one reserved
room for eight). First frame and layout time did not change. The base's
heap is 4 MB lower than in the first rows of the table. The reason was
not checked; a likely one is that a view has its own small working memory
since the render thread change, in place of the thread's 4 MB one.

## Frame rate (2026-11-23)

`app.py` does not scroll, so it cannot show this change; its row above
says only that launch, CPU, and memory stayed the same (the base in that
sitting: 674 / 646 ms, 65 / 111 MB, 565 / 1190 ms). The rate was measured
with a recording build on the built-in 120 Hz display, in a keyboard
scroll of 14 pages: all 172 frame gaps were 16.7 ms before, and 314 of 322
are 8.3 ms now. `bench/core.py` was not run: the core did not change.

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

## Task check boxes (2026-11-23)

The benchmark documents have no tasks, so they do not show what a check
box costs. Two documents of tasks only: 320 tasks (24 KB) and 9,600 tasks
(725 KB). Three Release builds, one after the other on the same Mac, five
launches each, median, app process only. Not from `app.py`: the script
that made the comparison with the web view, which also sends 30 Page Down
presses.

| 320 tasks / 9,600 tasks | Base (core cleanup) | Resize frame in step | Task check boxes |
| --- | --- | --- | --- |
| Launch to first document frame (ms) | 575 / 566 | 549 / 541 | 574 / 561 |
| Memory at rest (MB) | 58 / 80 | 58 / 79 | 63 / 80 |
| CPU until 4 s after the first frame (s) | 0.48 / 0.88 | 0.45 / 0.82 | 0.49 / 0.80 |
| CPU for 30 Page Down presses (s) | 0.69 / 1.00 | 0.66 / 1.04 | 1.09 / 1.82 |

The check boxes cost nothing at launch and about 5 MB for the buttons.
They cost main-thread time in a scroll: 13 to 27 ms more for each Page
Down in a document that is tasks from top to bottom, where each press
puts about 25 buttons on new tasks. The frames of the text do not wait for
it; they come from the render thread. The first version cost 1.76 s for
the 320 tasks. What brought it down: no question to the core and no move
of a button while the view stays in the part that has its boxes, the
size of the system's check box asked for one time, and no cursor
rectangles of the page that change with the boxes. What is left is the
system's check box itself, which on macOS 27 answers and draws through
its own view tree (a sample showed its layout, its drawing, and the
tracking areas of the window). Why the larger document costs more for
each press was not checked.

## The view under the toolbar (2026-11-24)

`app.py`, the base (task check boxes) and the change one after the other,
two and three runs of five launches. Launch to the first frame, short /
long document: base 613 / 594 and 651 / 582 ms; change 668 / 594,
674 / 554 and 687 / 592 ms. The long document shows no change. The short
one is 20 to 60 ms later in each run, at the edge of what the runs differ
by; if it is real, the view now draws the strip under the toolbar too and
the system makes its edge effect at the first frame. Not looked into.
Memory and CPU did not change. The core is not touched, so `core.py` was
not run.
