"""What the two benchmarks share: runs in turns, and the tables.

A sample is one number of one run. `samples[build][document][key]` is the
list of them. The key of the instructions that a number cost is the key of
the number with ":instructions" after it.
"""
from __future__ import annotations

import contextlib
import fcntl
import math
import os
import statistics
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

Samples = dict[str, dict[str, dict[str, list[float]]]]
INSTRUCTIONS = ":instructions"
# The kind of a number. A difference counts only when the runs of the two
# builds are apart (CHANCE) and the medians differ by more than the share
# of the kind. For a time the share is large: where the linker puts a hot
# function moves a time by 3 to 5 percent with no change of the work. A
# number of the kind VALUE is only shown.
TIME, COUNTED, VALUE = "time", "counted", "value"
LEAST = {TIME: 0.05, COUNTED: 0.01}
CHANCE = 0.05
# A time below this many milliseconds is a few ticks of the clock: shown,
# not judged. So is a number of instructions below FEWEST: a step that
# small differs by 2 percent from run to run of the same program.
SHORTEST_MS = 0.05
FEWEST = 2_000_000


@dataclass(frozen=True)
class Metric:
    key: str
    title: str
    kind: str = TIME


def new_samples(builds: list[str], documents: list[str]) -> Samples:
    return {build: {document: {} for document in documents} for build in builds}


def add(into: dict[str, list[float]], values: dict[str, float]) -> None:
    """The numbers of one run to the samples of its build and document."""
    for key, value in values.items():
        into.setdefault(key, []).append(value)


@contextlib.contextmanager
def one_at_a_time():
    """Stops when another benchmark of this user runs: two at a time
    measure each other."""
    path = Path.home() / "Library" / "Caches" / "sh.pluk.md-preview.bench.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    # Not through a link, and with no change of what is there.
    lock = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise SystemExit("another benchmark runs on this Mac; wait for it, or the two measure each other")
        load = os.getloadavg()[0]
        if load > (os.cpu_count() or 8) / 4:
            note(f"the Mac is busy (load {load:.1f}): the times have more noise; the instructions are still good")
        yield
    finally:
        os.close(lock)


def note(text: str) -> None:
    print(text, file=sys.stderr, flush=True)


def in_turns(builds: list[str], run: int) -> list[str]:
    """The order of the builds in a run: turned around each second run, so
    that no build is always the first or always the one after another."""
    return builds if run % 2 == 0 else builds[::-1]


def number(value: float) -> str:
    size = abs(value)
    if size >= 100 or value == int(value):
        return f"{value:.0f}"
    if size >= 10:
        return f"{value:.1f}"
    return f"{value:.2f}" if size >= 1 else f"{value:.3f}"


def spread(values: list[float]) -> float:
    """Half of the distance from the lowest to the highest run, as a share
    of the median."""
    middle = statistics.median(values)
    return (max(values) - min(values)) / 2 / abs(middle) if middle else 0.0


def cell(values: list[float] | None, scale: float = 1.0) -> str:
    if not values:
        return "–"
    middle = statistics.median(values)
    text = number(middle * scale)
    apart_by = round(spread(values) * 100)
    return f"{text} ±{apart_by}%" if apart_by else text


def no_unit(title: str) -> str:
    """A title with no unit at its end: "Parse (ms)" is "Parse"."""
    return title.rsplit(" (", 1)[0] if title.endswith(")") else title


def apart(first: list[float], second: list[float]) -> float:
    """The chance that two lists of runs differ this much with no real
    difference: the rank sum test of Mann and Whitney, two sides, counted
    exactly (no approximation, which is wrong for a few runs)."""
    values = sorted(first + second)
    # Two times the rank of each value, so that the middle rank of equal
    # values is a whole number.
    rank: dict[float, int] = {}
    at = 0
    while at < len(values):
        end = at
        while end < len(values) and values[end] == values[at]:
            end += 1
        rank[values[at]] = at + end + 1
        at = end
    # ways[count][sum]: in how many ways `count` of the values have this
    # sum of ranks.
    n, total = len(first), len(values)
    ways = [Counter() for _ in range(n + 1)]
    ways[0][0] = 1
    for value in values:
        for count in range(n - 1, -1, -1):
            for rank_sum, number_of in list(ways[count].items()):
                ways[count + 1][rank_sum + rank[value]] += number_of
    middle = n * (total + 1)
    far = abs(sum(rank[value] for value in first) - middle)
    as_far = sum(number_of for rank_sum, number_of in ways[n].items() if abs(rank_sum - middle) >= far)
    return as_far / math.comb(total, n)


def change(base: list[float] | None, new: list[float] | None, kind: str, smallest: float = 0) -> tuple[str, bool]:
    """The difference of the medians as text, and whether it counts. A
    number below `smallest` is not judged."""
    if not base or not new:
        return "–", False
    before, after = statistics.median(base), statistics.median(new)
    least = LEAST.get(kind)
    if before == 0 and after == 0:
        return "0%", False
    share = (after - before) / abs(before) if before else math.inf
    real = (least is not None and abs(share) >= least and len(base) > 1 and len(new) > 1
            and max(abs(before), abs(after)) >= smallest
            and apart(base, new) < CHANCE)
    return (f"{share * 100:+.1f}%" if before else "new") + (" **" if real else ""), real


def rows(lines: list[list[str]]) -> None:
    print("| " + " | ".join(lines[0]) + " |")
    print("|" + " --- |" * len(lines[0]))
    for line in lines[1:]:
        print("| " + " | ".join(line) + " |")
    print()


def grid(columns: list[str], metrics: list[Metric], cells) -> None:
    """A table with a row for each metric; `cells(metric)` gives the row
    after its title."""
    rows([["", *columns]] + [[title, *row] for title, row in ((m.title, cells(m)) for m in metrics)])


def one_build(samples: Samples, build: str, documents: list[str], metrics: list[Metric]) -> None:
    """The numbers of one build: the median of the runs, and how far the
    runs are from it."""
    of = samples[build]
    grid(documents, metrics, lambda m: [cell(of[d].get(m.key)) for d in documents])
    instructions(samples, build, documents, metrics)


def instructions(samples: Samples, build: str, documents: list[str], metrics: list[Metric]) -> None:
    """The instructions of a build's numbers: what a later day can compare
    with, on the same Mac and with the same documents."""
    of = samples[build]
    counted = [Metric(m.key + INSTRUCTIONS, no_unit(m.title)) for m in metrics
               if any(m.key + INSTRUCTIONS in of[d] for d in documents)]
    if counted:
        print(f"Instructions of {build} for the same numbers (millions):\n")
        grid(documents, counted, lambda m: [cell(of[d].get(m.key), 1e-6) for d in documents])


def two_builds(samples: Samples, base: str, new: str, documents: list[str], metrics: list[Metric]) -> None:
    """Two builds beside each other, and the differences that count."""
    found: list[str] = []
    # The app benchmark has one number of instructions, as a row.
    with_work = any(key.endswith(INSTRUCTIONS) for document in documents for key in samples[new][document])
    for document in documents:
        print(f"### {document}\n")
        lines = [["", base, new, "Difference"] + (["Instructions"] if with_work else [])]
        for metric in metrics:
            before, after = (samples[build][document].get(metric.key) for build in (base, new))
            work_before, work_after = (samples[build][document].get(metric.key + INSTRUCTIONS) for build in (base, new))
            value, real = change(before, after, metric.kind, SHORTEST_MS if metric.kind == TIME else 0)
            work, real_work = change(work_before, work_after, VALUE if metric.kind == VALUE else COUNTED, FEWEST)
            lines.append([metric.title, cell(before), cell(after), value] + ([work] if with_work else []))
            if real or real_work:
                found.append(f"- {document}: {metric.title}: {cell(before)} to {cell(after)}"
                             + (f", instructions {work.removesuffix(' **')}" if work_before else "")
                             + (" (the time only, for the same work: measure it again before you believe it)"
                                if work_before and not real_work else ""))
        rows(lines)
    print("`**`: the runs of the two builds are apart (chance below "
          f"{CHANCE:g} that they are not), and the medians differ by {LEAST[TIME]:.0%} or more for a time, "
          f"{LEAST[COUNTED]:.0%} or more for instructions and memory.\n")
    print("Differences that count:\n\n" + ("\n".join(found) if found else "none") + "\n")
    instructions(samples, new, documents, metrics)


def tables(samples: Samples, metrics: list[Metric]) -> None:
    """The tables for the builds and the documents of the samples, with
    the metrics that a run gave."""
    builds = list(samples)
    documents = list(samples[builds[0]])
    metrics = [m for m in metrics if any(m.key in samples[b][d] for b in builds for d in documents)]
    if len(builds) == 1:
        one_build(samples, builds[0], documents, metrics)
    elif len(builds) == 2:
        two_builds(samples, builds[0], builds[1], documents, metrics)
    else:
        # More than two builds, measured in one sitting: the direction.
        for document in documents:
            print(f"### {document}\n")
            grid(builds, metrics, lambda m: [cell(samples[b][document].get(m.key)) for b in builds])
            counted = [Metric(m.key + INSTRUCTIONS, no_unit(m.title)) for m in metrics
                       if any(m.key + INSTRUCTIONS in samples[b][document] for b in builds)]
            if counted:
                print("Instructions for the same numbers (millions):\n")
                grid(builds, counted, lambda m: [cell(samples[b][document].get(m.key), 1e-6) for b in builds])
