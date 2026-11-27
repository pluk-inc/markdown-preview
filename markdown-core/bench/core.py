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
import shutil
import subprocess
from pathlib import Path

import corpus
from corpus import CORE
from report import COUNTED, VALUE, Metric, add, in_turns, new_samples, note, one_at_a_time, tables

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


LINK = ["xcrun", "clang", "-fobjc-arc", "-O2", "-framework", "Foundation", "-framework", "QuartzCore",
        "-framework", "Metal", "-framework", "CoreText", "-framework", "CoreGraphics"]


def recipe() -> str:
    """What a program is made with, but for its core: bench.m, the command
    that links it, and the compiler of the core."""
    odin = subprocess.run(["odin", "version"], capture_output=True, text=True).stdout
    return hashlib.sha256(BENCH.read_bytes() + " ".join(LINK).encode() + odin.encode()).hexdigest()


def build(core: Path, out: Path, never_changes: bool = False) -> Path:
    """The core of a checkout as a library, and this bench.m with it. The
    program is linked again only when its recipe or the library changed;
    the core of a commit (`never_changes`) is not built a second time."""
    program, stamp = out / "mdcore-bench", out / "bench.stamp"
    made = stamp.read_text().split() if program.exists() and stamp.exists() else ["", ""]
    if never_changes and made[0] == recipe():
        return program
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([core / "build.sh", out], check=True, stdout=subprocess.DEVNULL)
    library = out / "libmdcore.a"
    version = [recipe(), str(library.stat().st_mtime_ns)]
    if made == version:
        return program
    linked = subprocess.run([*LINK, f"-I{core / 'include'}", BENCH, library, "-o", program], capture_output=True, text=True)
    if linked.returncode != 0:
        raise SystemExit(
            f"{linked.stderr}\nbench.m of this checkout does not build with the core in {core}: "
            "its C API is another one. Compare two commits that have the same API."
        )
    stamp.write_text(" ".join(version))
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
    source = out / "source"
    if not source.exists():
        source.mkdir(parents=True)
        archive = subprocess.Popen(["git", "-C", CORE.parent, "archive", commit, "markdown-core"], stdout=subprocess.PIPE)
        unpacked = subprocess.run(["tar", "-x", "-C", source], stdin=archive.stdout)
        if archive.wait() != 0 or unpacked.returncode != 0:
            shutil.rmtree(source)
            raise SystemExit(f"cannot read markdown-core at {commit}")
    label = name if name == commit else f"{name} ({commit})"
    return label, build(source / "markdown-core", out, never_changes=True)


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


def measure(program: Path, document: Path, cases: list[str]) -> dict[str, float]:
    arguments = [argument for case in cases for argument in ("--case", case)]
    output = subprocess.run([program, document, *arguments], check=True, capture_output=True, text=True).stdout
    return {name: float(value) for name, value in (line.split() for line in output.splitlines())}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, help="processes for each document and build (default 10)")
    parser.add_argument("--quick", action="store_true",
                        help="four runs: the fewest that can show a difference. With --case and one document, for a check "
                             "of a few seconds while a change is made; judge it from the instructions")
    parser.add_argument("--base", action="append", default=[], metavar="COMMIT_OR_FOLDER",
                        help="also measure the core of this commit or checkout, in turns with this one")
    corpus.add_argument(parser)
    parser.add_argument("--case", action="append", default=[], help="only this case of bench.m (can be given more than once); the walk of the caret is then left out")
    args = parser.parse_args()

    runs = args.runs or (4 if args.quick else 10)
    lock = one_at_a_time()
    documents = corpus.documents(args.documents)
    programs = dict(base_build(name) for name in args.base)
    programs["this checkout"] = build(CORE, OUT)
    # The walk is the check of all of the editor: not for one case.
    if not args.case:
        for document in (corpus.SHORT, caret_document(OUT / "caret.md")):
            check_caret(programs["this checkout"], document)

    samples = new_samples(list(programs), [name for name, _ in documents])
    for run in range(runs):
        note(f"run {run + 1} of {runs}")
        for name, path in documents:
            for label in in_turns(list(programs), run):
                add(samples[label][name], measure(programs[label], path, args.case))
    del lock
    tables(samples, METRICS)


if __name__ == "__main__":
    main()
