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

CORE = Path(__file__).resolve().parents[1]
OUT = CORE / "build" / "bench"
LONG_COPIES = 128

# The numbers in the order of the table, with the name a reader sees.
METRICS = [
    ("source_kb", "Source (KB)"),
    ("first_frame_ms", "First frame (ms)"),
    ("full_layout_ms", "Layout of the rest (ms)"),
    ("first_scroll_frame_cpu_ms", "Scroll frame, new glyphs (CPU ms)"),
    ("first_scroll_longest_frame_cpu_ms", "Longest such frame (CPU ms)"),
    ("second_scroll_frame_cpu_ms", "Scroll frame, glyphs ready (CPU ms)"),
    ("second_scroll_longest_frame_cpu_ms", "Longest such frame (CPU ms)"),
    ("total_cpu_ms", "CPU for the full run (ms)"),
    ("first_frame_heap_mb", "Heap at the first frame (MB)"),
    ("heap_mb", "Heap at the end (MB)"),
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
    short = CORE / "bench" / "short.md"
    long = OUT / "long.md"
    long.write_text("\n\n".join([short.read_text()] * LONG_COPIES))

    results = [measure(program, document, args.runs) for document in (short, long)]
    print("| | Short | Long |")
    print("| --- | --- | --- |")
    for name, title in METRICS:
        print(f"| {title} | " + " | ".join(f"{result[name]:g}" for result in results) + " |")


if __name__ == "__main__":
    main()
