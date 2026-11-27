"""What the two benchmarks share: runs in turns, and the tables.

A sample is one number of one run. `samples[build][document][key]` is the
list of them. The key of the instructions that a number cost is the key of
the number with ":instructions" after it.
"""
from __future__ import annotations

import fcntl
import math
import os
import statistics
import sys
from dataclasses import dataclass

Samples = dict[str, dict[str, dict[str, list[float]]]]
INSTRUCTIONS = ":instructions"
# A difference counts only when the runs of the two builds are apart
# (CHANCE) and the medians differ by more than this share. For a time the
# share is large: where the linker puts a hot function moves a time by 3
# to 5 percent with no change of the work.
CHANCE = 0.05
TIME, COUNTED, VALUE = 0.05, 0.01, None
# A time below this many milliseconds is a few ticks of the clock: shown,
# not judged. Its instructions are judged.
SHORTEST_MS = 0.05


@dataclass(frozen=True)
class Metric:
    key: str
    title: str
    # The smallest share that counts as a difference; None for a number
    # that the table only shows.
    least: float | None = TIME


def one_at_a_time() -> object:
    """Stops when another benchmark runs: two at a time measure each other."""
    lock = open("/tmp/sh.pluk.md-preview.bench.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise SystemExit("another benchmark runs on this Mac; wait for it, or the two measure each other")
    load = os.getloadavg()[0]
    if load > (os.cpu_count() or 8) / 4:
        note(f"the Mac is busy (load {load:.1f}): the times have more noise; the instructions are still good")
    return lock


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
    difference (the rank sum test of Mann and Whitney, two sides)."""
    ranked = sorted([(value, 0) for value in first] + [(value, 1) for value in second])
    rank_sum, ties, at = 0.0, 0.0, 0
    while at < len(ranked):
        end = at
        while end < len(ranked) and ranked[end][0] == ranked[at][0]:
            end += 1
        rank = (at + end + 1) / 2
        rank_sum += rank * sum(1 for _, group in ranked[at:end] if group == 0)
        ties += (end - at) ** 3 - (end - at)
        at = end
    n, m, total = len(first), len(second), len(ranked)
    variance = n * m / 12 * ((total + 1) - ties / (total * (total - 1)))
    if variance <= 0:
        return 1.0
    z = (abs(rank_sum - n * (n + 1) / 2 - n * m / 2) - 0.5) / math.sqrt(variance)
    return math.erfc(max(z, 0) / math.sqrt(2))


def change(base: list[float] | None, new: list[float] | None, least: float | None) -> tuple[str, bool]:
    """The difference of the medians as text, and whether it counts."""
    if not base or not new:
        return "–", False
    before, after = statistics.median(base), statistics.median(new)
    if before == 0:
        return ("0%", False) if after == 0 else ("new", least is not None)
    share = (after - before) / abs(before)
    timed = least != TIME or max(abs(before), abs(after)) >= SHORTEST_MS
    real = least is not None and timed and abs(share) >= least and len(base) > 1 and apart(base, new) < CHANCE
    return f"{share * 100:+.1f}%" + (" **" if real else ""), real


def rows(lines: list[list[str]]) -> None:
    print("| " + " | ".join(lines[0]) + " |")
    print("|" + " --- |" * len(lines[0]))
    for line in lines[1:]:
        print("| " + " | ".join(line) + " |")
    print()


def one_build(samples: Samples, build: str, documents: list[str], metrics: list[Metric]) -> None:
    """The numbers of one build: the median of the runs, and how far the
    runs are from it."""
    rows([["", *documents]] + [
        [metric.title, *(cell(samples[build][document].get(metric.key)) for document in documents)]
        for metric in metrics
    ])
    counted = [m for m in metrics if any(m.key + INSTRUCTIONS in samples[build][d] for d in documents)]
    if counted:
        print("Instructions for the same numbers (millions):\n")
        rows([["", *documents]] + [
            [no_unit(metric.title), *(cell(samples[build][document].get(metric.key + INSTRUCTIONS), 1e-6) for document in documents)]
            for metric in counted
        ])


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
            counted = [samples[build][document].get(metric.key + INSTRUCTIONS) for build in (base, new)]
            value, real = change(before, after, metric.least)
            work, real_work = change(counted[0], counted[1], COUNTED if metric.least is not None else None)
            lines.append([metric.title, cell(before), cell(after), value] + ([work] if with_work else []))
            if real or real_work:
                found.append(f"- {document}: {metric.title}: {cell(before)} to {cell(after)}"
                             + (f", instructions {work.removesuffix(' **')}" if counted[0] else ""))
        rows(lines)
    print("`**`: the runs of the two builds are apart (chance below "
          f"{CHANCE:g} that they are not), and the medians differ by {TIME:.0%} or more for a time, "
          f"{COUNTED:.0%} or more for instructions and memory.\n")
    print("Differences that count:\n\n" + ("\n".join(found) if found else "none") + "\n")


def many_builds(samples: Samples, builds: list[str], documents: list[str], metrics: list[Metric]) -> None:
    """More than two builds, measured in one sitting: the direction."""
    for document in documents:
        print(f"### {document}\n")
        rows([["", *builds]] + [
            [metric.title, *(cell(samples[build][document].get(metric.key)) for build in builds)]
            for metric in metrics
        ])


def tables(samples: Samples, builds: list[str], documents: list[str], metrics: list[Metric]) -> None:
    if len(builds) == 1:
        one_build(samples, builds[0], documents, metrics)
    elif len(builds) == 2:
        two_builds(samples, builds[0], builds[1], documents, metrics)
    else:
        many_builds(samples, builds, documents, metrics)
