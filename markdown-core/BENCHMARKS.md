# Benchmarks of the native renderer

The main numbers of the native renderer, recorded over time, so that each
new feature shows what it costs. Add a row when a pull request changes
`markdown-core/` or the host view: `app.py` each time, `core.py` when
files of the core changed. Do not edit old rows.

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
  two scroll passes of 24,000 points (the first lays out what it comes
  to and makes the glyph bitmaps, the second has them), a jump back to
  the top between them, a jump to the end, a new width there, the layout
  of all of the document (as Select All needs it), and the heap. It takes a minute and
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
| 2026-11-24 | a task changes in place; the page beside a scroll bar that takes room; Go menu scroll actions | 653 / 667 | 61 / 104 | 470 / 1120 | – | – | 0.33 / 0.33 | 6.7 / 20.7 |
| 2026-11-24 | the text cursor only over text; the core gives the shape of the pointer | 583 / 607 | 55 / 96 | 480 / 1020 | – | – | – | 6.6 / 20.7 |
| 2026-11-24 | the system backing of the covered top edge covers the find bar too | 621 / 633 | 54 / 96 | 510 / 1090 | – | – | – | – |
| 2026-11-24 | the reader keeps their place when the text is laid out again | 683 / 665 | 56 / 99 | 620 / 1260 | – | – | 0.44 / 0.35 | 6.6 / 20.7 |
| 2026-11-24 | blocks and layout records in parts of the document | 623 / 611 | 54 / 96 | 500 / 1040 | 64 / 75 | 2.9 / 301 | 0.42 / 0.40 | 6.7 / 20.0 |
| 2026-11-24 | the layout is made where the view is; estimated heights for the rest | 617 / 634 | 53 / 92 | 490 / 740 | 69 / 45 | none (see the section) | 0.52 / 0.44 | 6.9 / 20.4 (15.5 before Select All) |

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

## A click on a task (2026-11-24)

One click on a check box at the end of the 9,600-task document (725 KB),
by the accessibility press action, three clicks, CPU of the app process
from just before the click to 3 s after it. Not from `app.py`.

| | A click was a new document | The task changes in place |
| --- | --- | --- |
| CPU for one click (s) | 0.64, 0.72, 0.64 | 0.30, 0.42, 0.30 |
| Scroll bar | moved to another place and back (before the page kept its height) | does not move |

What is left is not in the renderer: a sample showed about 20 ms on the
main thread for the click (the change of the source text and the save),
and the rest on the queue that makes the sidebar outline and the
inspector numbers again for the full document. See Open work.

## Numbers that earlier rows left out (2026-11-24)

Two rows above have a dash where a program was not run. What is known:

- "frames from a CVDisplayLink": that pull request changed no file of the
  core, so `core.py` would have measured the same core two times.
- "cleanup of the core": `app.py` on that commit, measured on 2026-11-23
  as the base of the next pull request: 620 / 530 ms to the first frame,
  460 / 1090 ms of CPU. Its own base was not measured with `app.py` on
  the same day, so there is no pair; the row before it (704 / 717 ms) is
  from another run and another load of the Mac.
- "the view goes under the toolbar": no file of the core changed.

## Review findings on the lower pull requests (2026-11-24)

The two programs, the base (a task changes in place) and the change one
after the other. `app.py`, launch to the first frame, short / long: base
686 / 609 ms, change 653 / 667 ms; CPU 480 / 1130 against 470 / 1120 ms;
memory 57 / 101 against 61 / 104 MB. The two launch numbers move in
opposite directions, which is what the runs differ by. `core.py`: the
same in each line that is stable (scroll frame with the glyphs ready 0.285
/ 0.335 against 0.293 / 0.331 ms, CPU for the full run 244 / 1291 against
242 / 1298 ms, heap at the end 6.7 / 20.7 MB for the two). The heap of
the long document is 0.5 MB above the cleanup row: each block got the
number of its list item with the change before this one.

## The shape of the pointer (2026-11-24)

The two programs, the base (the review findings) and the change one after
the other. `app.py`, short / long: launch to the first frame 587 / 580
against 583 / 607 ms (two earlier pairs: 599 / 593 and 602 / 608 against
569 / 610 and 601 / 608), CPU 490 / 1030 against 480 / 1020 ms, memory
54 / 96 against 55 / 96 MB. `core.py`: heap 6.6 / 20.7 MB for the two, CPU
for the full run 314 / 1581 against 304 / 1576 ms. No difference.

Neither program moves the pointer, so they do not show the new work
itself: one question to the core for each move of the pointer and each
step of a scroll. Measured apart, in a loop over the layout of the long
document (15,360 blocks, 27,136 lines): 173 ns for one answer. The
question never waits for the core: when a layout step or a frame has it,
the answer is "busy" and the view asks again 30 ms later. Before that
change it waited, up to the 4 ms of a layout step, on the main thread.
Not measured: the main thread during a scroll with the pointer on the
page of the front window.

## The backing behind the find bar (2026-11-24)

`app.py`, `main` and the change one after the other, short / long: launch
to the first frame 586 / 638 against 621 / 633 ms, CPU 500 / 1090 against
510 / 1090 ms, memory 53 / 95 against 54 / 96 MB. Two pairs of an earlier
form of the change gave 588 / 616 and 574 / 583 against 590 / 598 and
580 / 640 ms. No difference outside what the runs differ by. No file of
the core changed, so `core.py` was not run. The benchmark opens no find
bar; the change does work only when the covered strip changes its height.

## The reader's place across a new layout (2026-11-24)

The two programs, the base (the find bar backing) and the change one after
the other, on a Mac that was busier than for the rows above (the base is
682 / 651 ms here against 621 / 633 ms some hours before). `app.py`, short
/ long: launch to the first frame 682 / 651 against 683 / 665 ms, CPU
630 / 1240 against 620 / 1260 ms, memory 58 / 102 against 56 / 99 MB.
`core.py`: heap at the end 6.6 / 20.7 MB for the two, CPU for the full
run 317 / 1638 against 352 / 1485 ms. No difference outside what the runs
differ by.

Neither program changes the width, which is where the change works. So
one more measure, not from `app.py`: the 1.1 MB document, the view at its
end, 20 changes of the window width sent one after the other, CPU of the
app process, two runs each.

| | Base | With the place kept |
| --- | --- | --- |
| CPU for 20 width changes at the end (s) | 7.43, 7.50 | 7.54, 7.54 |
| What shows after them | text from another part of the document | the same line as before |

The place costs nothing that this shows. The cost that was there before
is large: 0.37 s for each width change at the end of a long document,
because each new layout goes from the top down to the reader, on the
main thread. See Open work.

## Blocks and records in parts (2026-11-24)

The change puts the blocks of the document and the records of the layout
in parts, and shows the same page. So the question for the two programs
is only if something got slower or larger. The base (the reader's place)
and the change one after the other, short / long.

| | Base | In parts |
| --- | --- | --- |
| `core.py`: first frame (ms) | 71 / 75 | 64 / 75 |
| `core.py`: layout of the rest (ms) | 3.0 / 303 | 2.9 / 301 |
| `core.py`: heap at the first frame (MB) | 5.2 / 13.7 | 5.1 / 13.6 |
| `core.py`: heap at the end (MB) | 6.6 / 20.7 | 6.7 / 20.0 |
| Scroll frame, new glyphs / ready (CPU ms, long), 7 runs in turn | 0.400 / 0.379 | 0.407 / 0.368 |
| `app.py`: launch to the first frame (ms), two times | 625 / 624, 587 / 591 | 623 / 611, 587 / 616 |
| `app.py`: CPU to 3 s after (ms) | 500 / 1040, 490 / 1030 | 500 / 1040, 470 / 1040 |
| `app.py`: memory (MB) | 53 / 92, 53 / 96 | 54 / 96, 53 / 97 |

No difference in time. The heap of the long document is 0.7 MB smaller.

The first form of the change was 2 MB larger (22.7 MB), from two things
that only a measurement showed:

- The system's allocator has few sizes above 1 KB (16 KB, then 20 KB). A
  part of 64 blocks is 16.9 KB and took 20 KB. A part is now as many
  blocks as go in 16 KB with the header of the core's allocator (61).
- An array that is made smaller in place keeps its memory. The five
  record arrays of each part had 6.6 MB for 4.4 MB of records. The layout
  now builds a part in arrays that it uses again for each part, and
  copies the finished records into one piece of memory of their size:
  4.9 MB.

The layout was also compared record by record with the base, for a
document of 1,841 blocks at two widths: the same lines, boxes,
decorations, and tasks, at heights that differ by 0.11 points at most
(85,566 points down). That difference is the error that the base adds up
in a 32-bit height; a part now counts from its own top.

## The layout where the view is (2026-11-24)

Before this change the core laid out all of a document, the part after
the first view in steps in the background, because the height of the page
came from that. Now a part that no frame showed has a height that is
estimated from its text, and nothing lays out the rest. `core.py` got
three new numbers for this, and lost "layout of the rest", which is no
step any more. The base (blocks in parts) and the change one after the
other, short / long.

| | Base | Change |
| --- | --- | --- |
| `core.py`: first frame (ms) | 64 / 75 | 69 / 45 |
| To the end of the document: layout and the first frame there (ms) | 3 / 301 and a frame | 8 / 11 |
| A new width with the reader at the end: layout and frame (ms) | – / 370 | 15 / 10 |
| Layout of all of the document (ms) | 2.9 / 301 | 5.7 / 332, only for Select All |
| Scroll frame, new glyphs (CPU ms) | 0.47 / 0.41 | 0.63 / 0.52 |
| Scroll frame, glyphs ready (CPU ms) | 0.32 / 0.37 | 0.43 / 0.44 |
| Heap at the first frame (MB) | 5.1 / 13.6 | 5.3 / 13.8 |
| Heap after the two scroll passes (MB) | 6.7 / 20.0 | 6.6 / 15.5 |
| Heap with all of it laid out (MB) | 6.7 / 20.0 | 6.9 / 20.4 |
| `app.py`: launch to the first frame (ms) | 615 / 641 | 617 / 634 |
| `app.py`: CPU to 3 s after (ms) | 510 / 1060 | 490 / 740 |
| `app.py`: memory (MB) | 53 / 96 | 53 / 92 |

The base numbers for the end and for the new width are from the records
above (the layout of the rest, and the 0.37 s for each step of a live
resize at the end), not from a new run: the base has no call for them.

What to read from it:

- The run of the change was on a busier Mac than the one of the base
  (the frames with glyphs ready do the same work in the two, 0.44
  against 0.37 ms).
- The first frame of the long document lays out the view and a view and
  a half below it. Before, it also had the background layout behind it.
- A scroll frame that comes to new text is slower (0.52 against 0.41 ms),
  because it now lays out that text too. Before, the background had done
  that work, 300 ms of it for 1 MB, also for text that nobody went to.
- The app does 0.3 s less work for the long document, and keeps the
  records only of what was shown.
- The estimated height of the page, before anything but the first view
  was laid out, against the real one: -1.3% for the benchmark document,
  0.0% for a 725 KB document of tasks, -0.5% and 0.2% for two documents
  of this repository (`AGENTS.md` of the core, `CHANGELOG.md`). `core.py`
  prints it.
