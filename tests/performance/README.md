# Performance regression checks

The **Performance → performance regression** GitHub check compares each PR with
its merge base on the same `macos-15` runner. Pushes to `main` compare with the
previous commit from the push event; manual runs compare with the parent commit.
The job publishes a table in the Actions summary and retains raw measurements,
revision IDs, toolchain details, fixture bytes, and build/run logs as `performance-comparison`.

## What is measured

There are **18 metrics**:

| Workload | Measurements |
| --- | --- |
| Prose at 100 KB and 1 MB; code, bare links, and mixed Markdown at 100 KB | Swift renderer wall time and process CPU time (10 metrics) |
| The same Swift workloads | Renderer process peak RSS before creating WebKit (1 metric) |
| A 100 KB mixed file and a small file containing an image, math, highlighted code, and Mermaid | Read/editor page opening through ready DOM, assets, and layout (4 metrics) |
| A 100 KB mixed file | Editor insert/delete cycle, editor document replacement, and read-mode DOM update (3 metrics) |

The probe uses actual production Swift sources and vendored CodeMirror,
DOMPurify, Highlight, KaTeX, Mermaid, and Morphdom from each revision. It checks
that edits/updates apply and preserves the original source after each edit cycle.
It runs in **Release** with two warmups and seven measured samples per timing metric.

Both revisions use the same benchmark source and fixture. Builds finish before
measurements start. Two rounds run in **base, candidate, candidate, base** order
to balance cache warming and runner drift. They never run concurrently.

`dependencies.json` pins the parser revisions currently resolved by the app and
helper tests (Swift Markdown/cmark 0.8.0). The app does not check in its own
`Package.resolved`. Update these pins alongside parser dependency changes; once
this suite is on both sides, each revision uses its own pins. For older baselines
without this suite, the candidate's initial pins are used on both sides. The
one-time legacy editor adapter extracts the original page from
`EditorViewController`; it preserves that revision's HTML, CSS, and JavaScript.
Resource lookup is adapted only to locate the benchmark's SwiftPM assets.

## When the check fails

A metric must regress in **both independent rounds**, and the median increase
must exceed all three thresholds in each round:

1. **25%** of the baseline median.
2. **5 ms** for rendering/edit/update work, **20 ms** for page opening, or
   **16 MiB** for renderer peak RSS.
3. Three times the sum of both batches' median absolute deviations, to account
   for measurement noise. Peak RSS has one high-water sample per process.

An isolated/noisy slowdown produces a visible warning and a `check variability`
row instead of a confirmed-regression failure. Rerun that job before drawing a
conclusion. The table shows pooled medians and each round's percentage change so
runner drift is visible. Missing metrics, changed fixture hashes, invalid samples, build
failures, crashes, and timeouts fail the job; they cannot silently pass as faster
results. Changes smaller than the gate still appear in the comparison table.

The check reports failures on the PR. Repository branch protection must mark
`performance regression` as required if merges should be blocked by it.

## Run locally

From the repository root, with a **new** output directory:

```sh
python3 scripts/bench/run_performance.py --base origin/main --candidate HEAD --out /tmp/md-preview-performance
python3 -m unittest discover -s scripts/bench -p 'test_performance.py'
```

The benchmark snapshots committed revisions. Commit production changes before
comparing them; uncommitted production edits are not part of `HEAD`. The
controller's current benchmark source and fixture are used for both snapshots.
`--samples 3` is available for a quicker development smoke run; CI uses seven.
Do not run builds, tests, or other heavy work concurrently with timed runs.

## Boundaries

These are regression signals for the tested workloads, not a complete app
performance score. Both pages use a fixed 900 × 600 viewport, default typography,
and the macOS 15 editor scrolling path. Inputs and assets are offline.

WebKit views run in a foreground AppKit window to avoid background throttling.
Local runs briefly show this benchmark window. The probe explicitly drives
production animation callbacks. Open timings include page navigation, vendor parsing, and
readiness polling driven from Swift, avoiding hidden-page JavaScript timer
clamping in the test loop. Edit/update timings include synchronous work, scheduled frame
callbacks, and forced WebKit layout; timer waiting is excluded. They do **not**
measure native display paint, scroll smoothness, frame pacing, or all deferred
background work. The media page waits for actual image decoding, KaTeX, and
Mermaid output. Mixed-file opening keeps normal viewport virtualization.

Peak RSS is the **Swift renderer process**, including its in-process highlighter,
before WKWebView is created. It excludes WebContent and total application memory.
Native app launch, idle CPU, memory leaks, file I/O/autosave, Quick Look host
startup, and interactive scrolling still need the manual app/Quick Look harness
in [`scripts/bench/README.md`](../../scripts/bench/README.md) or Instruments.

## References

- [Apple: writing and running performance tests](https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests)
- [GitHub: job summaries](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary)
