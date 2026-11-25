#!/usr/bin/env python3
"""Benchmark of the Markdown core, with no window.

    markdown-core/bench/core.py [--runs 5]

Builds the core and bench.m, then runs the program on a short document
(short.md) and on a long one (short.md many times, about 1 MB). Each run is
a new process. Prints the median of each number as a Markdown table, in the
form that BENCHMARKS.md records.
"""
from __future__ import annotations

import argparse
import statistics
import subprocess
from pathlib import Path

from fixture import CORE, SHORT, write_long

OUT = CORE / "build" / "bench"

# The numbers in the order of the table, with the name a reader sees.
METRICS = [
    ("source_kb", "Source (KB)"),
    ("first_frame_ms", "First frame (ms)"),
    ("first_scroll_frame_cpu_ms", "Scroll frame, new glyphs (CPU ms)"),
    ("first_scroll_longest_frame_cpu_ms", "Longest such frame (CPU ms)"),
    ("jump_frame_cpu_ms", "Frame after a jump to the top (CPU ms)"),
    ("second_scroll_frame_cpu_ms", "Scroll frame, glyphs ready (CPU ms)"),
    ("second_scroll_longest_frame_cpu_ms", "Longest such frame (CPU ms)"),
    ("end_frame_ms", "To the end: layout and first frame there (ms)"),
    ("resize_at_end_ms", "A new width at the end: layout and frame (ms)"),
    ("change_ms", "A change of the text in its middle: parse, compare, and frame (ms)"),
    ("type_middle_cpu_ms", "A typed character in the middle of the text, the view at the end (CPU ms)"),
    ("type_end_cpu_ms", "A typed character at the end of the text, the view at the end (CPU ms)"),
    ("type_caret_cpu_ms", "A typed character at a caret that a click put in the view (CPU ms)"),
    ("caret_move_cpu_ms", "A step of the caret to the left or to the right (CPU ms)"),
    ("select_all_ms", "Select All (ms)"),
    ("copy_all_ms", "Copy of all of the text (ms)"),
    ("full_layout_cpu_ms", "All of the document laid out, by frames through it (CPU ms)"),
    ("estimate_error_percent", "Estimated page height against the real one (%)"),
    ("total_cpu_ms", "CPU for the full run (ms)"),
    ("first_frame_heap_mb", "Heap at the first frame (MB)"),
    ("scrolled_heap_mb", "Heap after the scroll passes (MB)"),
    ("heap_mb", "Heap with all of the document laid out (MB)"),
]


def build() -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run([CORE / "build.sh", OUT], check=True)
    program = OUT / "mdcore-bench"
    subprocess.run(
        ["xcrun", "clang", "-fobjc-arc", "-O2", f"-I{CORE / 'include'}",
         CORE / "bench" / "bench.m", OUT / "libmdcore.a",
         "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "Metal",
         "-framework", "CoreText", "-framework", "CoreGraphics", "-o", program],
        check=True,
    )
    return program


def caret_document(path: Path) -> Path:
    """A document with the places that are hard for a caret."""
    text = "# \n\na\n\n| x | y |\n| - | - |\n" + "|  |  |\n" * 40 + "\nmiddle\n\n"
    text += "#\n\n" * 70 + "-\n" * 70 + "\n" + "# \n\n" * 6
    text += "日本語の文章がここにあります。" * 6 + "\n\n"
    text += "```\nab   \n\n\tcd\n```\n\n> a &amp; **b** \\* `c`  \n> [d](https://example.com) e\u0301 👨‍👩‍👧‍👦\n\n---\n\nz\n\n- \n"
    path.write_text(text, encoding="utf-8")
    return path


def check_caret(program: Path, document: Path) -> None:
    """Moves the caret through all of a document; stops when a move is wrong."""
    result = subprocess.run([program, document, "--caret-walk"], capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(result.stderr.strip() or f"the caret walk of {document} did not end")


def measure(program: Path, document: Path, runs: int) -> dict[str, float]:
    samples: dict[str, list[float]] = {}
    for _ in range(runs):
        output = subprocess.run([program, document], check=True, capture_output=True, text=True).stdout
        for line in output.splitlines():
            name, value = line.split()
            samples.setdefault(name, []).append(float(value))
    return {name: statistics.median(values) for name, values in samples.items()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=5, help="processes for each document (default 5)")
    args = parser.parse_args()

    program = build()
    for document in (SHORT, caret_document(OUT / "caret.md")):
        check_caret(program, document)
    results = [measure(program, document, args.runs) for document in (SHORT, write_long(OUT / "long.md"))]
    print("| | Short | Long |")
    print("| --- | --- | --- |")
    for name, title in METRICS:
        print(f"| {title} | " + " | ".join(f"{result[name]:g}" for result in results) + " |")


if __name__ == "__main__":
    main()
