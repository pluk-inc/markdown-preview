#!/usr/bin/env python3
"""Benchmark of the app: a cold launch with one document, to the first frame.

    markdown-core/bench/app.py <Markdown Preview.app> [--renderer native|web] [--runs 5]

Each run starts a new copy of the app in the background with a document,
waits for the signpost of the first document frame ("nativePaint" or
"webPaint", see LaunchSignposts.swift), and reads the app process a few
seconds later. It measures a short document (short.md) and a long one
(short.md many times, about 1 MB), and prints the median of each number as
a Markdown table, in the form that BENCHMARKS.md records.

Use a Release build. Its windows open behind the front app and close when a
run ends. The memory and CPU numbers are for the app process only: with the
web renderer most of the work is in WebKit's helper processes, so compare
those two numbers between native runs, not between the renderers.
"""
from __future__ import annotations

import argparse
import json
import queue
import re
import signal
import statistics
import subprocess
import tempfile
import threading
import time
from datetime import datetime
from pathlib import Path

CORE = Path(__file__).resolve().parents[1]
LONG_COPIES = 128
PAINT_EVENT = {"native": "nativePaint", "web": "webPaint"}
PAINT_TIMEOUT = 30.0  # seconds; the first launch of a new build is slow
SETTLE = 3.0  # seconds after the first frame, before memory and CPU are read


def app_pids(executable: Path) -> set[int]:
    found = subprocess.run(["pgrep", "-f", re.escape(str(executable))], capture_output=True, text=True)
    return {int(pid) for pid in found.stdout.split()}


def cpu_seconds(pid: int) -> float:
    # "0:01.23" or "1:02:03.45": minutes and seconds, with hours on a long run.
    value = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    seconds = 0.0
    for part in value.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def footprint_mb(pid: int) -> float:
    output = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"Footprint: ([\d.]+) (KB|MB|GB)", output)
    if not match:
        raise RuntimeError(f"no footprint for process {pid}")
    return float(match[1]) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[match[2]]


def run_once(app: Path, executable: Path, document: Path, renderer: str) -> dict[str, float]:
    event = PAINT_EVENT[renderer]
    stream = subprocess.Popen(
        ["log", "stream", "--signpost", "--style", "ndjson",
         "--predicate", 'subsystem == "doc.md-preview.launch"'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    # A thread reads the log, so a quiet log cannot hold a wait past its
    # deadline.
    lines: queue.Queue[str] = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in stream.stdout], daemon=True).start()
    # A copy of the app that runs already is not this run's to read or stop.
    others = app_pids(executable)
    pid = None
    painted = None
    try:
        try:
            lines.get(timeout=PAINT_TIMEOUT)  # the header line: the stream is ready
            started = time.time()
            subprocess.run(
                ["open", "-g", "-n", "-F", "-a", app, document, "--args",
                 "-ApplePersistenceIgnoreState", "YES", "-MarkdownPreview.renderer", renderer],
                check=True,
            )
            while painted is None and (left := started + PAINT_TIMEOUT - time.time()) > 0:
                line = lines.get(timeout=left)
                if not line.startswith("{"):
                    continue
                entry = json.loads(line)
                pid = pid or next(iter(app_pids(executable) - others), None)
                if entry.get("signpostName") == event and entry.get("processID") == pid:
                    painted = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        except queue.Empty:
            pass  # the deadline passed: no frame, reported below
        if painted is None:
            raise RuntimeError(f"no {event} signpost from {app} in {PAINT_TIMEOUT:g} s")
        time.sleep(SETTLE)
        return {
            "first_frame_ms": (painted - started) * 1000,
            "cpu_ms": cpu_seconds(pid) * 1000,
            "memory_mb": footprint_mb(pid),
        }
    finally:
        stream.kill()
        for started_pid in app_pids(executable) - others:
            subprocess.run(["kill", str(started_pid)])
        time.sleep(0.5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path, help="the built app, a Release build")
    parser.add_argument("--renderer", choices=sorted(PAINT_EVENT), default="native")
    parser.add_argument("--runs", type=int, default=5, help="launches for each document (default 5)")
    args = parser.parse_args()

    app = args.app.resolve()
    name = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", app / "Contents" / "Info.plist"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    executable = app / "Contents" / "MacOS" / name
    signal.signal(signal.SIGINT, signal.default_int_handler)

    short = CORE / "bench" / "short.md"
    with tempfile.TemporaryDirectory() as folder:
        long = Path(folder) / "long.md"
        long.write_text("\n\n".join([short.read_text()] * LONG_COPIES))
        results = []
        for document in (short, long):
            run_once(app, executable, document, args.renderer)  # not counted: fills the caches
            samples = [run_once(app, executable, document, args.renderer) for _ in range(args.runs)]
            results.append({key: statistics.median(sample[key] for sample in samples) for key in samples[0]})

    print(f"| {args.renderer} | Short | Long |")
    print("| --- | --- | --- |")
    for key, title in (
        ("first_frame_ms", "Launch to first document frame (ms)"),
        ("cpu_ms", f"CPU of the app process, {SETTLE:g} s after it (ms)"),
        ("memory_mb", "Memory of the app process then (MB)"),
    ):
        print(f"| {title} | " + " | ".join(f"{result[key]:.0f}" for result in results) + " |")


if __name__ == "__main__":
    main()
