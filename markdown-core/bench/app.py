#!/usr/bin/env python3
"""Benchmark of the app: a launch with one document, to the first frame.

    markdown-core/bench/app.py <Markdown Preview.app>... [--renderer native|web]
                               [--runs 20] [--documents short,long]

Each run starts a new process of the app in the background with a
document, waits for the signposts of the first document frame (see
LaunchSignposts.swift), and reads the app process a few seconds later. It
prints the median of each number as Markdown tables, in the form that
BENCHMARKS.md records.

Give two apps (the base and the change) to judge a change: the launches of
the two go in turns in the same sitting. A number that the runs of another
day gave is of another load of the Mac.

Use Release builds. The files of the app are in the cache of the system
after the first launch, which is not counted: this is not the launch after
a restart of the Mac. The windows open behind the front app and close when
a run ends, so the launch is not the one of an app that comes to the
front. The memory, CPU, and instruction numbers are for the app process
only: with the web renderer most of the work is in WebKit's helper
processes, so compare those numbers between native runs, not between the
renderers.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import queue
import re
import signal
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

import corpus
from report import COUNTED, Metric, Samples, in_turns, note, one_at_a_time, tables

# The frame is drawn, and the frame is committed to the window server. A
# build from before the second signpost has only "…Paint", at the draw.
DRAW_EVENT = {"native": "nativeDraw", "web": "webDraw"}
PAINT_EVENT = {"native": "nativePaint", "web": "webPaint"}
PAINT_TIMEOUT = 30.0  # seconds; the first launch of a new build is slow
OLD_BUILD_WAIT = 0.5  # seconds for the second signpost, before a build counts as one with no such signpost
SETTLE = 6.0  # seconds after the first frame, before memory and CPU are read

METRICS = [
    Metric("paint_ms", "Launch to the first document frame, committed (ms)"),
    Metric("draw_ms", "Launch to the first document frame, drawn (ms)"),
    Metric("process_ms", "The same from the start of the process, with no time of the `open` command (ms)"),
    Metric("cpu_ms", f"CPU of the app process, {SETTLE:g} s after the frame (ms)"),
    Metric("minstructions", "Instructions of the app process then (millions)", COUNTED),
    Metric("memory_mb", "Memory of the app process then (MB)", COUNTED),
    Metric("peak_memory_mb", "Highest memory of the app process until then (MB)", COUNTED),
]

_RUSAGE_FIELDS = (
    "user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint "
    "proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups "
    "child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten "
    "cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility "
    "cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time "
    "serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy "
    "serviced_energy interval_max_phys_footprint runnable_time"
).split()


class Usage(ctypes.Structure):
    """`struct rusage_info_v4` of <sys/resource.h>."""
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in _RUSAGE_FIELDS]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
_libc.mach_absolute_time.restype = ctypes.c_uint64
_timebase = Timebase()
_libc.mach_timebase_info(ctypes.byref(_timebase))


def ticks_ms(ticks: int) -> float:
    """Units of the clock of the kernel as milliseconds."""
    return ticks * _timebase.numer / _timebase.denom / 1e6


def usage(pid: int) -> Usage:
    """What the kernel counted for a process: exact CPU time, memory, and
    instructions, with no other program between."""
    result = Usage()
    if _libc.proc_pid_rusage(pid, 4, ctypes.byref(result)) != 0:
        raise RuntimeError(f"no usage numbers for process {pid}")
    return result


def app_pids(executable: Path) -> set[int]:
    found = subprocess.run(["pgrep", "-f", re.escape(str(executable))], capture_output=True, text=True)
    return {int(pid) for pid in found.stdout.split()}


def executable_of(app: Path) -> Path:
    name = subprocess.run(
        ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleExecutable", app / "Contents" / "Info.plist"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return app / "Contents" / "MacOS" / name


def run_once(app: Path, executable: Path, document: Path, renderer: str) -> dict[str, float]:
    draw_event, paint_event = DRAW_EVENT[renderer], PAINT_EVENT[renderer]
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
    seen: dict[str, float] = {}
    try:
        try:
            lines.get(timeout=PAINT_TIMEOUT)  # the header line: the stream is ready
            started = time.time()
            subprocess.run(
                ["open", "-g", "-n", "-F", "-a", app, document, "--args",
                 "-ApplePersistenceIgnoreState", "YES", "-MarkdownPreview.renderer", renderer],
                check=True,
            )
            deadline = started + PAINT_TIMEOUT
            while (left := deadline - time.time()) > 0:
                line = lines.get(timeout=left)
                if not line.startswith("{"):
                    continue
                entry = json.loads(line)
                pid = pid or next(iter(app_pids(executable) - others), None)
                name = entry.get("signpostName")
                if name not in (draw_event, paint_event) or entry.get("processID") != pid or name in seen:
                    continue
                seen[name] = datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
                if len(seen) == 2:
                    break
                # A build with the two signposts sends them in one turn of
                # the run loop or a few frames apart.
                deadline = min(deadline, time.time() + OLD_BUILD_WAIT)
        except queue.Empty:
            pass  # the deadline passed: no frame, or an old build, sorted out below
        if not seen:
            raise RuntimeError(f"no {paint_event} signpost from {app} in {PAINT_TIMEOUT:g} s")
        # An old build: its one signpost is at the draw.
        drawn = seen.get(draw_event, seen.get(paint_event))
        painted = seen.get(paint_event) if draw_event in seen else None
        first = usage(pid)
        # The start of the process on the clock of this program.
        process_started = time.time() - ticks_ms(_libc.mach_absolute_time() - first.proc_start_abstime) / 1000
        time.sleep(max(0.0, (painted or drawn) + SETTLE - time.time()))
        counted = usage(pid)
        sample = {
            "draw_ms": (drawn - started) * 1000,
            "process_ms": ((painted or drawn) - process_started) * 1000,
            "cpu_ms": ticks_ms(counted.user_time + counted.system_time),
            "minstructions": counted.instructions / 1e6,
            "memory_mb": counted.phys_footprint / 1048576,
            "peak_memory_mb": counted.lifetime_max_phys_footprint / 1048576,
        }
        if painted is not None:
            sample["paint_ms"] = (painted - started) * 1000
        return sample
    finally:
        stream.kill()
        for started_pid in app_pids(executable) - others:
            subprocess.run(["kill", str(started_pid)])
        time.sleep(0.5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path, nargs="+", help="a built app, a Release build; two for the base and the change")
    parser.add_argument("--renderer", choices=sorted(PAINT_EVENT), default="native")
    parser.add_argument("--runs", type=int, default=20, help="launches for each document and app (default 20)")
    parser.add_argument("--documents", default="short,long",
                        help=f"a list of {', '.join(corpus.NAMES)}, or all (default short,long)")
    args = parser.parse_args()

    lock = one_at_a_time()
    apps = {}
    for app in args.app:
        app = app.resolve()
        label = app.stem if app.stem not in apps else str(app)
        apps[label] = (app, executable_of(app))
    if len(apps) != len(args.app):
        raise SystemExit("the same app two times")
    builds = list(apps)
    documents = corpus.documents(args.documents)
    signal.signal(signal.SIGINT, signal.default_int_handler)

    samples: Samples = {label: {name: {} for name, _ in documents} for label in builds}
    for name, path in documents:
        for label in builds:
            run_once(*apps[label], path, args.renderer)  # not counted: fills the caches
        for run in range(args.runs):
            note(f"{name}: launch {run + 1} of {args.runs}")
            for label in in_turns(builds, run):
                for key, value in run_once(*apps[label], path, args.renderer).items():
                    samples[label][name].setdefault(key, []).append(value)
    del lock

    print(f"Renderer: {args.renderer}\n")
    shown = [metric for metric in METRICS if any(metric.key in samples[label][name] for label in builds for name, _ in documents)]
    tables(samples, builds, [name for name, _ in documents], shown)


if __name__ == "__main__":
    main()
