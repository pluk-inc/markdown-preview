#!/usr/bin/env python3
"""Benchmark of the Markdown core, with no window.

    markdown-core/bench/core.py [--base <commit or folder>]... [--runs 10 | --quick]
                                [--documents short,long] [--case scroll]...

Builds the core and bench.m, then runs the program on the documents of
corpus.py. Each run is a new process. Prints the median of each number as
Markdown tables, in the form that BENCHMARKS.md records.

With --base it also builds the core of that commit (or of the checkout in
that folder) with the same bench.m, and runs the two in turns in the same
sitting: this is how to judge a change. A number that the runs of another
day gave is of another load of the Mac. With more than one --base it
shows all of them beside each other: the direction over the commits.
"""
from __future__ import annotations

import argparse
import hashlib
import subprocess
from pathlib import Path

import corpus
from corpus import CORE
from report import COUNTED, VALUE, Metric, Samples, in_turns, note, one_at_a_time, tables

OUT = CORE / "build" / "bench"
BENCH = CORE / "bench" / "bench.m"

# The numbers in the order of the table, with the name a reader sees.
METRICS = [
    Metric("source_kb", "Source (KB)", VALUE),
    Metric("startup_ms", "Start of the system: a first view with one word (ms)"),
    Metric("parse_ms", "Parse (ms)"),
    Metric("first_view_ms", "Layout of the first view and its frame, fonts and glyphs new (ms)"),
    Metric("first_view_again_ms", "The same in a later view of the process (ms)"),
    Metric("first_scroll_frame_cpu_ms", "Scroll frame, new glyphs: mean (CPU ms)"),
    Metric("first_scroll_median_frame_cpu_ms", "Scroll frame, new glyphs: median (CPU ms)"),
    Metric("first_scroll_p99_frame_cpu_ms", "Scroll frame, new glyphs: 99 of 100 are below (CPU ms)"),
    Metric("first_scroll_longest_frame_cpu_ms", "Scroll frame, new glyphs: longest (CPU ms)", VALUE),
    Metric("first_scroll_late_frames", "Scroll frames, new glyphs: above 8.3 ms of CPU", VALUE),
    Metric("jump_frame_cpu_ms", "Frame after a jump to the top (CPU ms)"),
    Metric("second_scroll_frame_cpu_ms", "Scroll frame, glyphs ready: mean (CPU ms)"),
    Metric("second_scroll_median_frame_cpu_ms", "Scroll frame, glyphs ready: median (CPU ms)"),
    Metric("second_scroll_p99_frame_cpu_ms", "Scroll frame, glyphs ready: 99 of 100 are below (CPU ms)"),
    Metric("second_scroll_longest_frame_cpu_ms", "Scroll frame, glyphs ready: longest (CPU ms)", VALUE),
    Metric("second_scroll_late_frames", "Scroll frames, glyphs ready: above 8.3 ms of CPU", VALUE),
    Metric("end_frame_ms", "To the end: layout and first frame there (ms)"),
    Metric("resize_at_end_ms", "A new width at the end: layout and frame (ms)"),
    Metric("change_ms", "A change of the text in its middle: parse, compare, and frame (ms)"),
    Metric("type_middle_cpu_ms", "A typed character in the middle of the text, the view at the end (CPU ms)"),
    Metric("type_end_cpu_ms", "A typed character at the end of the text, the view at the end (CPU ms)"),
    Metric("type_caret_cpu_ms", "A typed character at a caret that a click put in the view (CPU ms)"),
    Metric("caret_move_cpu_ms", "A step of the caret to the left or to the right (CPU ms)"),
    Metric("select_all_ms", "Select All (ms)"),
    Metric("copy_all_ms", "Copy of all of the text (ms)"),
    Metric("full_layout_cpu_ms", "All of the document laid out, by frames through it (CPU ms)"),
    Metric("estimate_error_percent", "Estimated page height against the real one (%)", VALUE),
    Metric("total_cpu_ms", "CPU for the full run, with what each case makes ready (ms)"),
    Metric("first_frame_heap_mb", "Heap at the first frame (MB)", COUNTED),
    Metric("scrolled_heap_mb", "Heap after the scroll passes (MB)", COUNTED),
    Metric("heap_mb", "Heap with all of the document laid out (MB)", COUNTED),
]


def build(core: Path, out: Path) -> Path:
    """The core of a checkout as a library, and this bench.m with it."""
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([core / "build.sh", out], check=True, stdout=subprocess.DEVNULL)
    program = out / "mdcore-bench"
    linked = subprocess.run(
        ["xcrun", "clang", "-fobjc-arc", "-O2", f"-I{core / 'include'}", BENCH, out / "libmdcore.a",
         "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "Metal",
         "-framework", "CoreText", "-framework", "CoreGraphics", "-o", program],
        capture_output=True, text=True,
    )
    if linked.returncode != 0:
        raise SystemExit(
            f"{linked.stderr}\nbench.m of this checkout does not build with the core in {core}: "
            "its C API is another one. Compare two commits that have the same API."
        )
    return program


def base_build(name: str) -> tuple[str, Path]:
    """The label and the program of a base: a folder with a checkout, or a
    commit, whose core is copied out of the repository."""
    folder = Path(name).expanduser()
    if folder.is_dir():
        core = folder / "markdown-core" if (folder / "markdown-core").is_dir() else folder
        return folder.resolve().name, build(core.resolve(), OUT / "base" / folder.resolve().name)
    found = subprocess.run(["git", "-C", CORE, "rev-parse", "--short=8", f"{name}^{{commit}}"], capture_output=True, text=True)
    if found.returncode != 0:
        raise SystemExit(f"{name} is not a folder and not a commit")
    commit = found.stdout.strip()
    out = OUT / "base" / commit
    label = name if name == commit else f"{name} ({commit})"
    # A commit never changes: its program is built one time for each
    # version of bench.m.
    stamp, version = out / "bench.sha", hashlib.sha256(BENCH.read_bytes()).hexdigest()
    if (out / "mdcore-bench").exists() and stamp.exists() and stamp.read_text() == version:
        return label, out / "mdcore-bench"
    source = out / "source"
    if not source.exists():
        source.mkdir(parents=True)
        archive = subprocess.Popen(["git", "-C", CORE.parent, "archive", commit, "markdown-core"], stdout=subprocess.PIPE)
        subprocess.run(["tar", "-x", "-C", source], stdin=archive.stdout, check=True)
        if archive.wait() != 0:
            raise SystemExit(f"cannot read markdown-core at {commit}")
    program = build(source / "markdown-core", out)
    stamp.write_text(version)
    return label, program


def caret_document(path: Path) -> Path:
    """A document with the places that are hard for a caret."""
    text = "# \n\na\n\n| x | y |\n| - | - |\n" + "|  |  |\n" * 40 + "\nmiddle\n\n"
    text += "#\n\n" * 70 + "-\n" * 70 + "\n" + "# \n\n" * 6 + "---\n\n" * 500 + "after the rules\n\n"
    text += "日本語の文章がここにあります。" * 6 + "\n\n"
    text += "one\n\n\n\ntwo\n\n\n\n\n\nthree\r\n\r\n\r\n\r\n- item\n\n\n\n"
    text += "```\nab   \n\n\tcd\n```\n\n> a &amp; **b** \\* `c`  \n> [d](https://example.com) é 👨‍👩‍👧‍👦\n\n---\n\nz\n\n- \n"
    path.write_text(text, encoding="utf-8")
    return path


def check_caret(program: Path, document: Path) -> None:
    """Moves the caret through all of a document; stops when a move is wrong."""
    result = subprocess.run([program, document, "--caret-walk"], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(result.stderr.strip() or f"the caret walk of {document} did not end")


def measure(program: Path, document: Path, cases: list[str], into: dict[str, list[float]]) -> None:
    arguments = [argument for case in cases for argument in ("--case", case)]
    output = subprocess.run([program, document, *arguments], check=True, capture_output=True, text=True).stdout
    for line in output.splitlines():
        name, value = line.split()
        into.setdefault(name, []).append(float(value))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, help="processes for each document and build (default 10)")
    parser.add_argument("--quick", action="store_true",
                        help="four runs: the fewest that can show a difference. With --case and one document, for a check "
                             "of a few seconds while a change is made; judge it from the instructions")
    parser.add_argument("--base", action="append", default=[], metavar="COMMIT_OR_FOLDER",
                        help="also measure the core of this commit or checkout, in turns with this one")
    parser.add_argument("--documents", default="short,long",
                        help=f"a list of {', '.join(corpus.NAMES)}, or all (default short,long)")
    parser.add_argument("--case", action="append", default=[], help="only this case of bench.m (can be given more than once)")
    args = parser.parse_args()

    runs = args.runs or (4 if args.quick else 10)
    lock = one_at_a_time()
    documents = corpus.documents(args.documents)
    programs = dict(base_build(name) for name in args.base)
    programs["this checkout"] = build(CORE, OUT)
    for document in (corpus.SHORT, caret_document(OUT / "caret.md")):
        check_caret(programs["this checkout"], document)

    builds = list(programs)
    samples: Samples = {label: {name: {} for name, _ in documents} for label in builds}
    for run in range(runs):
        note(f"run {run + 1} of {runs}")
        for name, path in documents:
            for label in in_turns(builds, run):
                measure(programs[label], path, args.case, samples[label][name])
    del lock

    shown = [metric for metric in METRICS if any(metric.key in samples[builds[-1]][name] for name, _ in documents)]
    tables(samples, builds, [name for name, _ in documents], shown)


if __name__ == "__main__":
    main()
