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
  the top between them, a jump to the end, a new width there, the same
  text again with one paragraph more in its middle, ten characters typed
  into that paragraph and ten at the end of the text, ten at a caret
  that a click put in the view, ten steps of that caret to the left and
  to the right, Select All,
  a copy of all of the text, frames through all of the document (so all
  of it is laid out), and the heap. Before the runs it walks the caret
  through two documents with each key that moves it, and stops with a
  message when a move is wrong (`mdcore-bench <file> --caret-walk`). It
  takes a minute and shows no window. A scroll frame is CPU time of the drawing thread, because
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
| 2026-11-24 | a selection is two addresses in the document; a copy reads the document | 586 / 570 | 58 / 97 | 560 / 820 | 69 / 68 | none | 0.46 / 0.39 | 7.0 / 21.5 (15.4 before all of it was laid out) |
| 2026-11-24 | the core keeps the reader's place across a new layout | 553 / 537 | 53 / 87 | 490 / 710 | 63 / 66 | none | 0.48 / 0.40 | 7.0 / 21.4 (15.3 before all of it was laid out) |
| 2026-11-24 | a changed text changes the document in place | 566 / 577 | 57 / 92 | 540 / 800 | 61 / 67 | none | 0.43 / 0.39 | 7.0 / 22.9 with the changed text of the benchmark (15.4 before all of it was laid out) |
| 2026-11-24 | the document keeps its source; each block knows its lines of it | 558 / 576 | 61 / 107 | 470 / 700 | 59 / 69 | none | 0.45 / 0.39 | 7.0 / 25.3 (16.2 at the first frame) |
| 2026-11-24 | a change of the source as a range and a text | 574 / 582 | 62 / 108 | 465 / 705 | 59 / 71 | none | 0.43 / 0.37 | 7.0 / 25.4 (16.2 at the first frame) |
| 2026-11-24 | an edit parses only the blocks around it | 577 / 599 | 62 / 107 | 460 / 700 | 60 / 74 | none | 0.47 / 0.42 | 7.0 / 25.3 (16.1 at the first frame) |
| 2026-11-24 | a key lays out its block again, not its part | 558 / 560 | 62 / 108 (see the section) | 450 / 695 | 60 / 70 | none | 0.50 / 0.42 | 7.2 / 25.5 (16.1 at the first frame) |
| 2026-11-25 | a caret, and text that is typed at it | 596 / 587 | 53 / 98 | 505 / 730 | 66 / 72 | none | 0.51 / 0.43 | 7.1 / 26.7 (16.2 at the first frame) |
| 2026-11-25 | Edit Mode in the native view | 569 / 579 | 53 / 99 | 475 / 720 | 61 / 71 | none | 0.52 / 0.44 | 7.2 / 26.7 (16.2 at the first frame) |
| 2026-11-25 | the keys that move the caret | 650 / 628 | 59 / 105 | 545 / 875 | 56 / 81 | none | none / 0.42 | 7.1 / 26.6 (16.2 at the first frame) |
| 2026-11-25 | Return, and the empty line that it makes | 616 / 565 | 61 / 107 | 490 / 775 | 48 / 61 | none | none / 0.34 | 7.2 / 26.6 (16.1 at the first frame) |
| 2026-11-25 | the bullet of a list item as a circle | 598 / 596 | 51 / 96 | 490 / 740 | 62 / 78 | none | 0.49 / 0.41 | 7.0 / 26.2 (16.1 at the first frame) |
| 2026-11-25 | a caret after a space at the end of a text | 635 / 619 | 56 / 103 | 545 / 840 | 66 / 81 | none | none | 7.1 / 26.2 (16.1 at the first frame) |
| 2026-11-25 | a selection that goes, and the delete keys | 620 / 613 | 52 / 100 | 495 / 745 | 69 / 82 | none | none | 7.0 / 26.2 (16.1 at the first frame) |
| 2026-11-25 | the marks at the caret | 580 / 591 | 53 / 99 | 485 / 725 | 63 / 80 | none | none | 7.0 / 26.2 (16.1 at the first frame) |
| 2026-11-25 | the mark of a heading at the caret | 557 / 603 | 53 / 100 | 470 / 735 | 59 / 76 | none | none | 7.0 / 26.1 (16.1 at the first frame) |
| 2026-11-25 | the mark of a list item and of a quote at the caret | 601 / 609 | 62 / 108 (the base too) | 480 / 715 | 61 / 75 | none | none | 7.0 / 26.3 (16.1 at the first frame) |
| 2026-11-25 | the frame for a key does not wait for the refresh | 611 / 586 | 65 / 110 (the base too) | 490 / 800 | none | none | none (the core is the same) | none |

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
| Select All (ms) | 2.9 / 301, the layout of the rest | 5.4 / 4.4 |
| Layout of all of the document (ms) | 2.9 / 301 | 5.7 / 332, only for a copy of all of it |
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
  was laid out, against the real one in the same width: -1.3% for the
  long benchmark document (-0.4% for the short one),
  0.0% for a 725 KB document of tasks, -0.5% and 0.2% for two documents
  of this repository (`AGENTS.md` of the core, `CHANGELOG.md`). `core.py`
  prints it.

## A selection as addresses in the document (2026-11-24)

The base (the layout where the view is) and the change, one after the
other, short / long.

| | Base | Change |
| --- | --- | --- |
| Select All (ms) | 5.4 / 4.4 | 0.00 / 0.00 |
| Copy of all of the text (ms) | 0.04 / 355, with the layout of all of it | 0.03 / 1.9 |
| First frame (ms), 7 runs in turn, long | 62 | 44 |
| Scroll frame, new glyphs / ready (CPU ms), 7 runs in turn, long | 0.446 / 0.370 | 0.468 / 0.397 |
| Heap after the scroll passes and a copy of all (MB) | 6.9 / 20.4 | 6.6 / 15.4 plus the copied text |
| `app.py`: launch to the first frame (ms) | 578 / 619 | 586 / 570 |
| `app.py`: CPU to 3 s after (ms) | 570 / 830 | 560 / 820 |
| `app.py`: memory (MB) | 57 / 92 | 58 / 97 |

A copy does not lay out anything any more, so the heap stays at what the
reader went through. The first frame and the scroll frames do the same
work in the two; the differences are what two runs on this Mac differ by
(the base ran first in each pair).

The app memory of the long document was 5 MB higher for the change in
the run of the table (97 against 92 MB). So the two builds ran again in
turn, three times each with three launches: launch 566, 544, 561 against
548, 551, 541 ms; CPU 800, 770, 770 against 770, 780, 770 ms; memory 96,
96, 95 against 96, 96, 96 MB. No difference. One run of `app.py` can be
5 MB off for the memory.

`core.py` has a new last step for the number "all of the document laid
out": frames from the top to the end, each second view height. It costs
2.1 s of CPU for the long document, most of it for the quads and the
glyph bitmaps of each frame, not for the layout (0.33 s when the base
measured that alone).

## The reader's place in the core (2026-11-24)

The base (a selection as addresses) and the change. `core.py`, short /
long: first frame 63 / 66 ms, a new width at the end 17 / 10 ms, scroll
frames 0.48 and 0.40 ms, heap 13.7 MB at the first frame and 15.3 MB
after the scroll passes. The same as the base (62 / 66, 17 / 10, 0.48 and
0.40, 13.7, 15.4). The new width at the end now has the place kept by the
core, where the benchmark asked for it before.

`app.py`, long document, the two builds in turn with three launches for
each number. The base first, two pairs: launch 552, 537 against 565,
569 ms; CPU 710, 720 against 720, 720 ms; memory 92, 91 against 92,
91 MB. That looked like 10 to 30 ms more for the launch. The change
first, three pairs: launch 537, 621, 603 against 620, 618, 616 ms; CPU
710, 760, 750 against 770, 760, 760 ms; memory 87, 91, 91 against 91, 92,
91 MB. So the build that runs second in a pair is the slower one, and
the two builds do not differ. To judge a launch time of this size,
measure in the two orders.

## A changed text in place (2026-11-24)

`core.py` has a new step: with the reader at the end, the document gets
the same text again with one paragraph more in its middle. The time is
for the parse of the new text, the comparison with the old blocks, the
one part that is made again, and the frame at the same scroll position:
8.6 ms for the short document, 28.6 ms for the long one. About 24 ms of
the long one is the parse of all of the text, which this change does not
remove. The other numbers of `core.py` are the ones of the base (the
reader's place in the core): first frame 61 / 67 ms, scroll frames 0.43
and 0.39 ms, heap 13.7 MB at the first frame and 15.4 MB after the scroll
passes.

What the number does not show is what changed for the reader. Before, a
new text was a new document: the view kept its distance from the top of
the page, so text that came in above the reader moved what they read,
and all that was laid out was laid out again when the reader came to
it. Now the first line that shows stays where it is, and the parts that
did not change keep their records.

`app.py`, short / long, the base, the step before it (a selection as
addresses), and the change, in three orders with three launches for each
number. The builds at the two ends of an order were 20 to 30 ms faster
at launch than the ones in its middle, whichever build that was:

| Order | Launch to the first frame (ms), short |
| --- | --- |
| selection, place, change, change, place, selection | 540, 566, 562, 560, 581, 549 |
| change, selection, selection, place, selection, change | 566, 564, 566, 555, 531, 554 |

So the three builds do not differ: CPU 520 to 560 ms short and 780 to
820 ms long, memory 56 to 57 MB short and 90 to 96 MB long for each of
them.

## The source kept, and a block's lines of it (2026-11-24)

The document keeps the Markdown text, and each block has the start of its
first line in it. The parser copy says the start of each block through one
new callback.

`core.py`, short / long, the base (a changed text in place) and the
change, one after the other, two times each:

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 59 / 72 | 59 / 69 |
| Scroll frame, new glyphs / ready (CPU ms, long) | 0.51 / 0.42 | 0.45 / 0.39 |
| A change of the text in its middle (ms) | 8.4 / 26 | 8.5 / 27 |
| Heap at the first frame (MB) | 5.3 / 15.6 | 5.3 / 16.2 |
| Heap with all of the document laid out (MB) | 7.0 / 24.7 | 7.0 / 25.3 |

No time changed. The heap of the long document has 1.1 MB more for the
kept source and 0.5 MB less because the arrays of a text are copied to
their exact size (an array that is made smaller in place keeps its room
in the system's allocator).

One number is not explained, and it is not from this change: with a block
of 280 bytes (58 in a part) the heap at the first frame is 1.6 MB lower
than with one of 264 bytes (61 in a part): 14.0 MB against 15.6 MB on the
base with 16 bytes added to the block, 14.6 MB against 16.2 MB on the
change. The base with 58 blocks of 264 bytes in a part shows 15.8 MB, so
it is not the number of blocks in a part. The block of the change has 264
bytes (its small fields stand together). See Open work in `AGENTS.md`.

The footprint of the process for the parse of the long document alone
(a small program, not `core.py`): +16.2 MB on the base and +17.0 MB with
the change, of which 7.4 and 8.0 MB are in use after it.

`app.py`, short / long, three launches for each number, the base built
from the same commit of `main` on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 624 / 626 | 62 / 108 | 470 / 760 |
| change | 558 / 576 | 61 / 107 | 470 / 700 |
| change | 543 / 573 | 61 / 107 | 460 / 710 |
| base | 574 / 635 | 62 / 104 | 460 / 750 |

Memory is the same. The long document shows about 50 ms less to the
first frame and 50 ms less CPU. The reason is not verified: a text that
the host sets a second time at launch would explain it, because that is
now one comparison with the kept source and not a parse. (A first
comparison used a copy of the base app that was
built before the last commits of the base, and showed 7 MB less memory
for it; a base must be built from the commit that the change starts
from.)

## A change as a range of the source (2026-11-24)

`core.py` has two new steps, with the reader at the end of the text: ten
characters typed into a paragraph in the middle of the text, and ten at
the end of its last line, one call and one frame for each
(`mdcore_replace_text`). The number is the CPU time for one of them (a
frame waits for the display, so the time on the clock says nothing).

| | Short | Long |
| --- | --- | --- |
| A typed character in the middle of the text (CPU ms) | 5.0 | 10.4 |
| A typed character at the end of the text (CPU ms) | 4.8 | 10.5 |

The end of the text is the end of its last line that shows on the page
(the benchmark document ends with definitions of links, which show
nothing).

An editor has 8.3 ms for a key at 120 Hz. Two costs are in these
numbers:

- The parse of all of the new source and the comparison of all blocks:
  it is most of the 10 ms of the long document, and 0.1 ms of the short
  one.
- The layout of the part of the document that has the changed block:
  all blocks of the part are laid out again, with their text shaped
  again, when the part is near the view. It is the 5 ms of the short
  document, where all of the text is near the view.

So two things are between this and a key that costs less than 1 ms: the
parse of only what changed, and a layout that makes only the changed
block again, not its part.

The other numbers of `core.py` are the ones of the base (the source
kept): first frame 58 / 70 ms against 56 / 70 ms, scroll frames 0.44 and
0.37 ms against 0.42 and 0.37 ms, heap 16.2 MB at the first frame for
the two.

`app.py`, short / long, five launches for each number, the base built
from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 529 / 568 | 62 / 108 | 450 / 700 |
| change | 572 / 584 | 62 / 107 | 460 / 700 |
| change | 575 / 579 | 62 / 108 | 470 / 710 |
| base | 552 / 562 | 61 / 108 | 450 / 700 |

Memory and CPU are the same. The change is in the middle of the order,
where a build is 20 to 30 ms slower at launch than at the two ends,
whichever build it is (see "A changed text in place"); the launch path
has the same work in the two builds.

A run before this one, with three launches for each number, showed 155
to 198 MB in four of its eight numbers, for the base and for the change.
The run above did not show it. The reason is not known; a number that
is 90 MB over the others is a sign of it, and the run is then made
again.

## The parse of only what changed (2026-11-24)

An edit parses the blocks around it, not all of the source. `core.py`,
short / long, the base (a change as a range) and the change, with the
same benchmark program, one after the other:

| | Base | Change |
| --- | --- | --- |
| A change of the text in its middle, the full text given (ms) | 8.5 / 26 | 8.6 / 8.0 |
| A typed character in the middle of the text (CPU ms) | 5.0 / 10.4 | 4.9 / 1.5 |
| A typed character at the end of the text (CPU ms) | 4.8 / 10.5 | 4.8 / 6.1 |
| First frame (ms) | 59 / 64.7 | 59 / 65.9 |
| Heap at the first frame (MB) | 5.3 / 16.2 | 5.3 / 16.1 |

What a key in the long document has in it now, from a timer in the
core (not in `core.py`):

- In the middle, which the view at the end does not show: 0.5 ms to
  make the edit ready (the copy of the 1.1 MB source with the change,
  and the parse of the piece), 0.03 ms to put the blocks in, and
  the frame.
- At the end, which the view shows: about 1.2 ms to make the edit ready
  and 3.5 ms for the layout of the part that changed. The piece there
  has the definitions of links that the document ends with, and so it
  gets each definition of the document with one of those names: the
  long document is the short one 128 times, so each definition is there
  128 times. A document has a definition one time, as a rule.

The short document did not change: its 5 ms are the layout of the
changed part, which is the next step. With it, the two costs that the
section before names are one less.

The first frame of the long document is the median of ten runs of the
benchmark program for each, in turns: 1 ms more (1.5%). The parse of
all now also notes each definition of a link and counts the lines to
each part. The copy of all of the
text went from 0.3 ms to 1.1 ms in this run order. The code of the
copy did not change. The reason is not verified; the likely one is
that on the base each of the twenty keys before it made all texts of
the document again, so the copy read memory that was just written, and
now the texts are the ones of the first parse.

`app.py`, short / long, five launches for each number, the base built
from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 603 / 586 | 62 / 108 | 480 / 710 |
| change | 582 / 599 | 61 / 108 | 460 / 700 |
| change | 572 / 598 | 62 / 106 | 460 / 700 |
| base | 568 / 594 | 62 / 109 | 460 / 710 |

The app is the same at launch: no part of it types into the core yet.

## A key lays out its block, not its part (2026-11-24)

An edit that leaves the number of blocks (each key in a block) changes
the block at its place, and the layout makes only its records again.
`core.py`, short / long, the base (the parse of only what changed) and
the change:

| | Base | Change |
| --- | --- | --- |
| A typed character in the middle of the text (CPU ms) | 4.9 / 1.5 | 1.3 / 1.4 |
| A typed character at the end of the text (CPU ms) | 4.8 / 6.1 | 1.3 / 3.1 |
| A change of the text in its middle, the full text given (ms) | 8.6 / 8.9 | 8.4 / 8.8 |
| First frame (ms) | 59 / 70 | 60 / 70 |
| Heap at the first frame (MB) | 5.3 / 16.1 | 5.3 / 16.1 |

The short document is all near the view, so each key in it paid for the
layout of a full part (up to 58 blocks); now it pays for one block. In
the long document the middle is not near the view at the end, so that
number had no layout in it and did not change.

Where the time of a key goes now, from a timer in the core (not in
`core.py`). Short document: 0.07 ms to make the edit ready, 0.01 ms to
put the block in, 0.1 to 0.25 ms for the layout of the block and the
reader's place, and about 1 ms for the frame after it. Long document,
at the end: 2.5 ms to make the edit ready, 0.01 ms, 0.3 ms, and the
frame. The 2.5 ms are the parse of a piece that has all 3,200
definitions of links of the document with it: the benchmark document
has each of its 25 definitions 128 times, and the piece at its end has
the last of those definitions in it, with their names. Which rule
makes each definition count there was not looked at. A document has a
definition one time, as a rule.

What is left of a key that the view shows is the frame after it, about
1 ms. The step that puts a paragraph in the middle (one block more)
did not change: a change of the number of blocks still makes its part
again.

`app.py`, short / long, five launches for each number, the base built
from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 552 / 565 | 155 / 201 | 460 / 700 |
| change | 565 / 557 | 155 / 200 | 450 / 690 |
| change | 551 / 563 | 155 / 108 | 450 / 700 |
| base | 583 / 644 | 62 / 107 | 500 / 760 |

Launch and CPU are the same. The memory numbers of the first five
documents are 93 MB over the usual ones, for the base and for the
change, and the last three are the usual ones (62 and 107 MB): the same
jump as in one run of "A change as a range of the source", again not
from a build. The reason is still not known. One built-in display was
on; no other display was there when it was looked at after the run.

## A caret, and text typed at it (2026-11-25)

`core.py` has one step more: a click in the middle of the view puts a
caret in the text there, ten characters are typed at the caret with a
frame after each, and then each is taken out again. The benchmark stops
with an error when the caret did not move to the right or the text is
not the one of before at the end.

| | Short | Long |
| --- | --- | --- |
| A typed character at an offset in the middle of the text (CPU ms) | 1.3 | 1.5 |
| A typed character at an offset at the end of the text (CPU ms) | 1.4 | 2.7 |
| A typed character at a caret that a click put in the view (CPU ms) | 2.0 | 1.8 |

The other numbers of `core.py` are the ones of the base (a key lays out
its block): the first frame is 51 to 58 ms (short) and 61 to 75 ms
(long) for the two over ten runs of the benchmark program each, in
turns; scroll frames 0.50 and 0.42 ms against 0.51 and 0.43 ms. The heap
with all of the document laid out has 1.2 MB more for the long document
(26.7 MB): the benchmark asks for the source two times, and the core
keeps the copy that it gave.

A key at the caret has more in it than a key at an offset of the source
that the caller knows: the place of the caret on the page after the key
is found by a parse of the lines around its block.

`app.py`, short / long, five launches for each number, the base built
from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 613 / 609 | 54 / 100 | 500 / 750 |
| change | 588 / 586 | 53 / 96 | 510 / 730 |
| change | 603 / 588 | 53 / 100 | 500 / 730 |
| base | 611 / 596 | 53 / 100 | 500 / 750 |

The app is the same: no part of it has a caret yet. The memory is 8 MB
under the numbers of the day before for the two builds alike, as the
launch time is 30 ms over them: the state of the Mac, not the builds.

## Edit Mode in the native view (2026-11-25)

The host side of the caret: with the native renderer on, Edit Mode makes
the native view take the keys. Nothing of it runs before the reader
turns Edit Mode on. `app.py`, short / long, five launches for each
number, the base built from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 562 / 591 | 53 / 100 | 480 / 720 |
| change | 571 / 582 | 53 / 100 | 470 / 720 |
| change | 566 / 576 | 53 / 98 | 480 / 720 |
| base | 554 / 569 | 53 / 100 | 470 / 720 |

The core changed by two small calls for the host (`mdcore_caret_show`,
`mdcore_caret_offset`). `core.py`, short / long, the base and the
change, two runs each in turns:

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 60 / 73 | 61 / 71 |
| Scroll frame, new glyphs / ready (CPU ms, long) | 0.52 / 0.44 | 0.52 / 0.44 |
| A typed character in the middle of the text (CPU ms) | 1.3 / 1.4 | 1.2 / 1.5 |
| A typed character at the end of the text (CPU ms) | 1.5 / 3.3 | 1.3 / 3.3 |
| A typed character at a caret (CPU ms) | 1.8 / 2.0 | 1.6 / 2.1 |
| Heap at the first frame (MB) | 5.3 / 16.2 | 5.3 / 16.2 |

The same for the two, as it must be: the benchmark calls neither of
the new calls.

## The keys that move the caret (2026-11-25)

The arrow keys and the other keys that move the caret, with the
selection. Nothing of it runs before a key. The Mac was busier than for
the rows above (other builds ran), so read this row against its own
base only. `app.py`, short / long, five launches for each number, the
base built from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 644 / 623 | 66 / 108 | 510 / 810 |
| change | 665 / 632 | 56 / 104 | 530 / 870 |
| change | 635 / 624 | 61 / 106 | 560 / 880 |
| base | 597 / 607 | 59 / 112 | 510 / 800 |

`core.py`, short / long, the base and the change, two runs each in
turns (base, change, change, base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 63, 60 / 71, 76 | 43, 70 / 75, 88 |
| Scroll frame, glyphs ready (CPU ms) | 0.32, 0.34 / 0.41, 0.43 | 0.48, 0.42 / 0.39, 0.45 |
| A typed character in the middle of the text (CPU ms) | 1.1, 1.5 / 1.3, 1.8 | 1.4, 1.4 / 1.3, 1.7 |
| A typed character at the end of the text (CPU ms) | 1.1, 1.4 / 2.2, 2.6 | 1.5, 1.3 / 2.8, 2.4 |
| A typed character at a caret (CPU ms) | 1.8, 1.8 / 1.4, 2.0 | 1.8, 1.6 / 1.9, 2.1 |
| A step of the caret to the left or to the right (CPU ms) | none | 0.58, 0.50 / 0.46, 0.53 |
| Heap at the first frame (MB) | 5.3 / 16.2 | 5.3 / 16.2 |
| Heap with all of the document laid out (MB) | 7.1 / 26.7 | 7.1 / 26.6 |

No number moved by more than the two runs of one build differ. A step
of the caret is 0.5 ms with its frame, in 9 KB and in 1.1 MB: it makes
the map of the caret's block (one parse of the lines of that block) and
the quads of the selection, not the quads of the page. The first form
of the step made the quads of the page too and was 1.2 ms. The 20 ms
that the app's CPU number is higher in the long document is inside
what the two base runs of the row above it differ by on a busy Mac; the
launch runs no code of this change.

## Return, and the empty line that it makes (2026-11-25)

Each block has the number of empty lines after it that show, the
layout gives each a line, and Return is a call that knows its block.
The number is in two bytes that a block had spare, so a block is no
larger. `app.py`, short / long, five launches for each number, the
base built from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 599 / 557 | 54 / 100 | 510 / 780 |
| change | 603 / 587 | 60 / 107 | 470 / 780 |
| change | 629 / 543 | 61 / 107 | 510 / 770 |
| base | 534 / 532 | 64 / 109 | 450 / 770 |

`core.py`, short / long, the base and the change, two runs each in
turns (base, change, change, base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 49, 49 / 60, 62 | 48, 49 / 63, 60 |
| Scroll frame, glyphs ready (CPU ms) | 0.28, 0.29 / 0.38, 0.35 | 0.28, 0.30 / 0.34, 0.34 |
| A typed character in the middle of the text (CPU ms) | 1.1, 1.0 / 1.5, 1.3 | 1.1, 1.1 / 1.3, 1.4 |
| A typed character at the end of the text (CPU ms) | 1.1, 1.0 / 2.8, 2.7 | 1.0, 0.8 / 2.6, 2.4 |
| A typed character at a caret (CPU ms) | 1.2, 1.2 / 1.8, 1.4 | 1.3, 1.0 / 1.3, 1.8 |
| A step of the caret to the left or to the right (CPU ms) | 0.32, 0.34 / 0.39, 0.32 | 0.34, 0.28 / 0.30, 0.33 |
| Heap at the first frame (MB) | 5.3 / 16.1 | 5.3 / 16.1 |
| Heap with all of the document laid out (MB) | 7.1, 7.2 / 26.7, 26.6 | 7.2, 7.1 / 26.6, 26.6 |

No number moved by more than the two runs of one build differ. The
parse counts the empty lines after each block with one more read of
the lines of the block (to find where they end): that is in the first
frame, which did not move. The memory of the app is what the two base
runs differ by (54 to 64 MB). The walk of the caret before the runs
now also presses Return, types, and deletes, and stops when the text
is not the text of before.

## The bullet of a list item as a circle (2026-11-25)

The bullet is a record of its box and no paragraph of one character,
and the check box of a task has its height from the font. `app.py`,
short / long, five launches for each number, the base built from its
commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 595 / 598 | 51 / 96 | 500 / 740 |
| change | 593 / 587 | 51 / 94 | 490 / 740 |
| change | 602 / 605 | 51 / 97 | 490 / 740 |
| base | 613 / 653 | 50 / 97 | 500 / 770 |

`core.py`, short / long, the base and the change, two runs each in
turns (base, change, change, base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 64, 61 / 80, 80 | 61, 63 / 79, 77 |
| Scroll frame, new glyphs (CPU ms) | 0.63, 0.61 / 0.47, 0.48 | 0.57, 0.58 / 0.48, 0.50 |
| Scroll frame, glyphs ready (CPU ms) | 0.34, 0.33 / 0.41, 0.43 | 0.35, 0.42 / 0.42, 0.40 |
| A typed character in the middle of the text (CPU ms) | 1.2, 1.2 / 1.4, 1.7 | 1.2, 1.4 / 1.6, 1.5 |
| Heap at the first frame (MB) | 5.3 / 16.2 | 5.3 / 16.1 |
| Heap with all of the document laid out (MB) | 7.1, 7.2 / 26.6 | 7.0 / 26.2 |

No time moved. The heap with all of the long document laid out is
0.4 MB lower: a bullet was a paragraph record and a line record with a
shaped line, and is one record of its box now. A first run of this
benchmark showed 40 ms more for a launch of the change; two reviewer
agents had started in the middle of it. This run had the Mac to
itself.

## A caret after a space at the end of a text (2026-11-25)

The caret knows the spaces of the source before it that the text has
not. Nothing of it runs before a key. `app.py`, short / long, five
launches for each number, the base built from its commit on the same
day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 644 / 667 | 53 / 100 | 530 / 800 |
| change | 639 / 613 | 53 / 102 | 510 / 830 |
| change | 630 / 624 | 58 / 103 | 580 / 850 |
| base | 627 / 628 | 53 / 96 | 510 / 760 |

`core.py`, short / long, the base and the change, two runs each in
turns (base, change, change, base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 64, 68 / 80, 95 | 66, 66 / 82, 79 |
| A typed character in the middle of the text (CPU ms) | 1.2, 1.5 / 1.5, 1.6 | 1.1, 1.3 / 1.6, 1.7 |
| A typed character at the end of the text (CPU ms) | 1.4, 1.5 / 2.7, 3.3 | 1.3, 1.3 / 3.9, 3.5 |
| A typed character at a caret (CPU ms) | 1.9, 1.7 / 1.8, 2.1 | 1.5, 1.4 / 2.2, 2.2 |
| A step of the caret to the left or to the right (CPU ms) | 0.39, 0.43 / 0.37, 0.50 | 0.37, 0.34 / 0.49, 0.49 |
| Heap at the first frame (MB) | 5.3 / 16.1 | 5.3 / 16.1 |
| Heap with all of the document laid out (MB) | 7.2, 7.0 / 26.2 | 7.2, 7.0 / 26.2 |

No number moved by more than the two runs of one build differ (the
character at the end of the long text is 2.7 and 3.3 for the base and
3.9 and 3.5 for the change; unit tests of another branch ran on the
Mac for some seconds of this run). The walk of the caret before the
runs types two spaces at the end of a paragraph and goes back over
them.

## A selection that goes, and the delete keys (2026-11-25)

A delete is a move of the caret with the selection and then one edit of
a range of the source. The parser says where the marks of the styles
are, only for the parse that makes the map of one block; the map of
the block of the caret keeps them. Nothing of it runs before a key.
`app.py`, short / long, five launches for each number, the base built
from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 592 / 540 | 53 / 99 | 480 / 680 |
| change | 620 / 613 | 52 / 100 | 490 / 740 |
| change | 620 / 613 | 52 / 99 | 500 / 750 |
| base | 625 / 639 | 53 / 98 | 500 / 760 |

`core.py`, short / long, the base and the change, three runs each in
turns (base, change, change, base, change, base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 68, 55, 63 / 83, 84, 89 | 68, 69, 69 / 87, 82, 81 |
| A typed character in the middle of the text (CPU ms) | 1.09, 0.98, 1.00 / 1.62, 1.32, 1.33 | 0.83, 1.49, 1.04 / 1.36, 1.13, 1.34 |
| A typed character at the end of the text (CPU ms) | 0.78, 0.96, 0.88 / 2.08, 1.79, 1.91 | 0.89, 1.38, 0.90 / 1.97, 1.84, 1.99 |
| A typed character at a caret (CPU ms) | 1.11, 1.20, 1.09 / 1.38, 1.24, 1.30 | 1.06, 1.66, 1.25 / 1.61, 1.22, 1.49 |
| A step of the caret to the left or to the right (CPU ms) | 0.28, 0.49, 0.35 / 0.42, 0.34, 0.45 | 0.27, 0.58, 0.40 / 0.41, 0.29, 0.42 |
| Heap at the first frame (MB) | 5.3 / 16.1 | 5.3 / 16.1 |
| Heap with all of the document laid out (MB) | 7.0 / 26.1, 26.2 | 7.0 / 26.1, 26.2 |

The Mac was not quiet: another session built and measured on it, with
a load of 6 to 12 through these runs (and 20 to 100 through a first
set, which is not here). So the runs of one build differ by as much as
the two builds do. The launch, the memory, and the heap are the same.
The median of a typed character at a caret is 1.25 / 1.49 against
1.11 / 1.30: this can be the marks that the map of the caret's block
keeps now, or the load (the second run of the change is the high one
in each row of the short document, also in the rows that the change
has no part in). To measure again on a quiet Mac. The time of a
delete key has no number yet: the benchmark does deletes to check
them, not to time them.

## The marks at the caret (2026-11-25)

The marks of the element that the caret is in show as text. A parse
looks at each mark only while a caret is there, and a block is made
again only when the caret goes into an element or out of it. `app.py`,
short / long, five launches for each number, the base (the delete
keys) built from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 575 / 577 | 53 / 96 | 480 / 730 |
| change | 577 / 578 | 53 / 99 | 480 / 720 |
| change | 582 / 604 | 53 / 99 | 490 / 730 |
| base | 603 / 628 | 53 / 99 | 480 / 750 |

`core.py`, short / long, the base and the change, two runs each in
turns (base, change, change, base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 57, 60 / 80, 84 | 66, 60 / 86, 73 |
| A typed character in the middle of the text (CPU ms) | 1.08, 1.37 / 1.52, 1.60 | 1.15, 1.24 / 1.50, 1.51 |
| A typed character at the end of the text (CPU ms) | 1.27, 1.32 / 2.77, 3.72 | 1.20, 1.34 / 3.45, 2.82 |
| A typed character at a caret (CPU ms) | 1.57, 1.59 / 2.02, 2.14 | 1.41, 1.70 / 1.81, 1.72 |
| A step of the caret to the left or to the right (CPU ms) | 0.40, 0.43 / 0.52, 0.47 | 0.35, 0.36 / 0.40, 0.35 |
| Heap at the first frame (MB) | 5.3 / 16.1 | 5.3 / 16.1 |
| Heap with all of the document laid out (MB) | 7.0, 7.2 / 26.2, 26.1 | 7.0 / 26.2 |

No number moved by more than the two runs of one build differ. The Mac
was quiet for the runs of the change (a load of 3 to 4) and had more
load for the first and the last one of the base (8, and 30 at the end
of the last launch set). The steps of the caret in the benchmark go
through the styled text of the document, so they have the changes of
the marks in them; the walk before the runs also selects and steps
back at each place.

## The mark of a heading at the caret (2026-11-25)

The "#" of a heading shows for a caret in its line. The parser gives
the lines of the text of a heading only to a parse that notes the
marks. `app.py`, short / long, five launches for each number, the base
(the marks at the caret) built from its commit on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 593 / 603 | 54 / 96 | 480 / 730 |
| change | 522 / 598 | 53 / 100 | 460 / 730 |
| change | 591 / 608 | 53 / 100 | 480 / 740 |
| base | 578 / 597 | 53 / 101 | 490 / 730 |

`core.py`, short / long, two runs each in turns (base, change, change,
base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 56, 58 / 76, 74 | 59, 59 / 78, 74 |
| A typed character in the middle of the text (CPU ms) | 1.17, 1.36 / 1.55, 1.60 | 1.31, 1.31 / 1.53, 1.52 |
| A typed character at the end of the text (CPU ms) | 0.92, 1.51 / 3.49, 2.89 | 1.43, 1.11 / 2.99, 3.47 |
| A typed character at a caret (CPU ms) | 1.11, 1.94 / 2.04, 2.04 | 1.84, 1.54 / 2.02, 2.02 |
| A step of the caret to the left or to the right (CPU ms) | 0.35, 0.43 / 0.35, 0.48 | 0.44, 0.36 / 0.41, 0.37 |
| Heap with all of the document laid out (MB) | 7.0 / 26.1 | 7.0 / 26.0, 26.1 |

No number moved by more than the two runs of one build differ. The
Mac had other work for some minutes of the launch sets (a load of 38
at the end of the first set of the change, 18 and 10 after the next
two). The measure was of the form that looked for the "#" back from
the first text; the form that has the lines from the parser came
after it and does less work for each heading.

## The mark of a list item and of a quote at the caret (2026-11-25)

The mark of a block shows before its text for a caret in the block.
The parser gives the lines of paragraphs too, to a parse that notes
marks; a block has one flag more. `app.py`, short / long, five launches
for each number, the base (the mark of a heading) built from its commit
on the same day:

| Order | Launch to the first frame (ms) | Memory (MB) | CPU (ms) |
| --- | --- | --- | --- |
| base | 611 / 626 | 62 / 108 | 480 / 730 |
| change | 600 / 608 | 62 / 108 | 480 / 710 |
| change | 602 / 610 | 62 / 107 | 480 / 720 |
| base | 595 / 631 | 62 / 108 | 470 / 730 |

`core.py`, short / long, two runs each in turns (base, change, change,
base):

| | Base | Change |
| --- | --- | --- |
| First frame (ms) | 44, 62 / 76, 69 | 64, 58 / 75, 75 |
| A typed character in the middle of the text (CPU ms) | 1.11, 1.33 / 1.40, 1.45 | 1.22, 1.15 / 1.47, 1.36 |
| A typed character at the end of the text (CPU ms) | 1.27, 1.40 / 2.56, 2.85 | 1.29, 1.07 / 2.42, 2.42 |
| A typed character at a caret (CPU ms) | 1.65, 1.60 / 1.33, 1.80 | 1.64, 1.77 / 1.75, 1.83 |
| A step of the caret to the left or to the right (CPU ms) | 0.38, 0.34 / 0.39, 0.40 | 0.35, 0.37 / 0.32, 0.43 |
| Heap with all of the document laid out (MB) | 7.1, 7.0 / 26.2 | 7.0 / 26.3, 26.4 |

No number moved by more than the two runs of one build differ, but the
heap of the long document: 0.1 to 0.2 MB more, which is the flag in
each of its 15 000 blocks. The memory of the app process is 62 / 108 MB
for the two builds in this set, and was 53 / 100 in the sets of the
morning: the two builds moved together, so it is the state of the Mac
(the same jump is in the section of the key that lays out its block).
The load was 4 to 9.

## The frame for a key does not wait for the refresh (2026-11-25)

A key asked for a frame at the next refresh of the display, so the
reader saw it up to one refresh later. The frame is now drawn at once
on the queue of the render loop, when no frame was drawn in the last
refresh and no scroll is in progress. The view also sets the caret, the
check boxes, and the pointer only when the layout or the page area
changed, not after each key. The core is the same, so `core.py` did not
run.

The time from a key to its frame has no program in `bench/` yet (see
Open work in `AGENTS.md`). It was measured with a build that has time
stamps in `keyDown` and around the draw of the frame: 200 keys, 50 ms
apart, at a caret in the middle of the text, on a 60 Hz display, from
the time of the key event to the frame handed to the display system,
the median and the slowest of each set, in ms:

| | Short document | Long document (1 MB) |
| --- | --- | --- |
| Base | 11.9 / 18.2 | not recorded |
| Change | 3.4 / 5.4 | 4.0 / 9.1 |

The CPU of the app process for each key, measured from outside for the
same keys, was 5.6 ms (short) and 6.5 ms (long) with the change.

`app.py`, short / long, five launches for each number, the base (the
mark of a list item) built from its commit on the same day, in the
order that they ran:

| Order | Launch to the first frame (ms) |
| --- | --- |
| change | 623 / 598 |
| base | 614 / 612 |
| base | 638 / 620 |
| change | 589 / 580 |
| base | 617 / 620 |
| change | 611 / 586 |

Memory and CPU of a set before it, with the same build of the change:
65 / 110 MB and 490 / 800 ms, against 64 / 108 MB and 470 to 510 / 790
to 810 ms for the base. No number of a launch moved by more than the
runs of one build differ. The load was 4 to 5.
