#!/usr/bin/env python3
"""Compare two bench CSV directories and print a markdown table.

Usage:
    scripts/bench/report.py --baseline <dir> --candidate <dir>

Each directory should contain one or more CSVs produced by bench-app.sh /
bench-ql.sh (rows: label,sample,metric,value). Rows are joined on
(sample, metric); duplicate keys within a directory (repeat runs) are
averaged. Pure stdlib, no dependencies.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


def load_dir(path: Path) -> dict[tuple[str, str], float]:
    """Map (sample, metric) -> mean value across every CSV in the directory."""
    sums: dict[tuple[str, str], float] = {}
    counts: dict[tuple[str, str], int] = {}
    files = sorted(path.rglob("*.csv"))
    if not files:
        sys.exit(f"error: no CSV files found under {path}")
    for f in files:
        with f.open(newline="") as fh:
            for row in csv.DictReader(fh):
                try:
                    value = float(row["value"])
                except (KeyError, TypeError, ValueError):
                    continue
                key = (row.get("sample", ""), row.get("metric", ""))
                sums[key] = sums.get(key, 0.0) + value
                counts[key] = counts.get(key, 0) + 1
    return {k: sums[k] / counts[k] for k in sums}


def fmt(value: float | None) -> str:
    if value is None:
        return "—"
    if value == int(value):
        return f"{int(value):,}"
    return f"{value:,.1f}"


def fmt_delta(base: float | None, cand: float | None) -> str:
    if base is None or cand is None:
        return "—"
    if base == 0:
        return "—" if cand == 0 else "n/a"
    return f"{(cand - base) / base * 100.0:+.1f}%"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--baseline", required=True, type=Path)
    ap.add_argument("--candidate", required=True, type=Path)
    args = ap.parse_args()

    baseline = load_dir(args.baseline)
    candidate = load_dir(args.candidate)

    keys = sorted(set(baseline) | set(candidate))
    rows = [
        (
            sample,
            metric,
            fmt(baseline.get((sample, metric))),
            fmt(candidate.get((sample, metric))),
            fmt_delta(baseline.get((sample, metric)), candidate.get((sample, metric))),
        )
        for sample, metric in keys
    ]

    headers = ("sample", "metric", "baseline", "candidate", "delta")
    widths = [
        max(len(headers[i]), *(len(r[i]) for r in rows)) if rows else len(headers[i])
        for i in range(5)
    ]

    def line(cells):
        return "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cells)) + " |"

    print(line(headers))
    print("|" + "|".join("-" * (w + 2) for w in widths) + "|")
    for r in rows:
        print(line(r))


if __name__ == "__main__":
    main()
