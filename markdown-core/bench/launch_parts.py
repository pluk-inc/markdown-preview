#!/usr/bin/env python3
"""The parts of a launch of the app, from its signposts, for two builds.

    markdown-core/bench/launch_parts.py <base.app> <change.app> [document] [--runs 12]

`app.py` gives the time of all of a launch, which differs by 7 to 11 %
from run to run: a change of 15 ms is not seen in it. This program gives
the time between two signposts of the app (see LaunchSignposts.swift), for
the two builds in turns, so a change in one part of the launch shows.

Each run starts a new process in the background with the document and the
native renderer, reads the signposts of that process until the first
document frame is committed, and stops the process. It prints the median
of each part with half of the range of the runs. Use Release builds, each
a copy with a bundle identifier of its own, as for `app.py`.
"""
from __future__ import annotations

import argparse
import json
import queue
import statistics
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from app import app_pids, executable_of
from report import one_at_a_time

WAIT = 20.0  # seconds for the first document frame of one launch
# The parts: from one signpost to another one. An interval of the app has
# a "begin" and an "end"; an event has only "event".
PARTS = [
    ("The app's code starts, to the document frame drawn", "willFinishLaunching:event", "nativeDraw:event"),
    ("The window is made, to the document frame drawn", "makeWindow:begin", "nativeDraw:event"),
    ("The render of the document starts, to its frame drawn", "renderBeforeShow:begin", "nativeDraw:event"),
    ("The warm-up of the renderer, start to end", "nativeWarmUp:begin", "nativeWarmUp:end"),
    ("The end of the warm-up, to the start of the render", "nativeWarmUp:end", "renderBeforeShow:begin"),
]


def launch(app: Path, executable: Path, document: Path) -> dict[str, float]:
    """One launch: when each signpost of the new process came."""
    stream = subprocess.Popen(
        ["log", "stream", "--signpost", "--style", "ndjson",
         "--predicate", 'subsystem == "doc.md-preview.launch"'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    lines: queue.Queue[str] = queue.Queue()
    threading.Thread(target=lambda: [lines.put(line) for line in stream.stdout], daemon=True).start()
    # A copy of the app that runs already is not this run's to read or stop.
    others = app_pids(executable)
    pid = None
    seen: dict[str, float] = {}

    def read(until: float, stop_at: str | None) -> None:
        nonlocal pid
        while (left := until - time.time()) > 0 and (stop_at is None or stop_at not in seen):
            try:
                line = lines.get(timeout=left)
            except queue.Empty:
                return
            if not line.startswith("{"):
                continue
            entry = json.loads(line)
            pid = pid or next(iter(app_pids(executable) - others), None)
            if entry.get("processID") != pid:
                continue
            at = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
            seen.setdefault(f"{entry.get('signpostName')}:{entry.get('signpostType')}", at)

    try:
        try:
            lines.get(timeout=WAIT)  # the header line: the stream is ready
        except queue.Empty:
            return seen  # no log stream: this run is not counted
        subprocess.run(
            ["open", "-g", "-n", "-F", "-a", app, document, "--args",
             "-ApplePersistenceIgnoreState", "YES", "-MarkdownPreview.renderer", "native"],
            check=True,
        )
        read(time.time() + WAIT, "nativePaint:event")
        # What ends after the frame (a thread of its own) is read too.
        read(time.time() + 0.5, None)
    finally:
        stream.terminate()
        stream.wait()
        for started in app_pids(executable) - others:
            subprocess.run(["kill", str(started)], check=False)
        time.sleep(0.8)
    return seen


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apps", nargs=2, type=Path, metavar="app")
    parser.add_argument("document", nargs="?", type=Path, default=Path(__file__).with_name("short.md"))
    parser.add_argument("--runs", type=int, default=12)
    args = parser.parse_args()
    samples: dict[Path, list[dict[str, float]]] = {app: [] for app in args.apps}
    executables = {app: executable_of(app) for app in args.apps}
    with one_at_a_time():
        for run in range(args.runs):
            # In turns, and the first of a pair is the other build each time.
            for app in args.apps if run % 2 == 0 else args.apps[::-1]:
                seen = launch(app, executables[app], args.document)
                if "nativePaint:event" in seen:
                    samples[app].append(seen)
    print("| | " + " | ".join(app.stem for app in args.apps) + " |")
    print("| --- | " + " | ".join("---" for _ in args.apps) + " |")
    for label, start, end in PARTS:
        cells = []
        for app in args.apps:
            values = [(seen[end] - seen[start]) * 1000 for seen in samples[app] if start in seen and end in seen]
            cells.append(f"{statistics.median(values):.0f} ±{(max(values) - min(values)) / 2:.0f} ({len(values)})" if values else "–")
        print(f"| {label} (ms) | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
