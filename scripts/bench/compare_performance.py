#!/usr/bin/env python3
"""Validate two paired benchmark rounds and enforce confirmed regressions."""
from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path


EXPECTED_METRICS = {
    *(f"render-{document}-{clock}" for document in ["prose-100k", "prose-1m", "code-100k", "links-100k", "mixed-100k"]
      for clock in ["wall", "cpu"]),
    *(f"{surface}-open-{document}" for surface in ["editor", "read"] for document in ["mixed-100k", "media"]),
    "editor-edit-cycle-mixed-100k", "editor-replace-mixed-100k", "read-update-mixed-100k", "renderer-peak-rss",
}


class InvalidReport(ValueError):
    pass


def load(path: Path) -> dict:
    report = json.loads(path.read_text())
    if report.get("schema") != 1 or not report.get("revision"):
        raise InvalidReport(f"{path}: missing revision or unsupported schema")
    metrics = {}
    for metric in report.get("metrics", []):
        name, unit, samples = metric["name"], metric["unit"], metric["samples"]
        if name in metrics or unit not in {"ms", "MiB"} or not metric.get("inputSHA256"):
            raise InvalidReport(f"{path}: invalid/duplicate metric {name}")
        minimum = 1 if unit == "MiB" else 3
        if len(samples) < minimum or any(isinstance(x, bool) or not isinstance(x, (int, float))
                                        or not math.isfinite(x) or x <= 0 for x in samples):
            raise InvalidReport(f"{path}: invalid samples for {name}")
        metrics[name] = metric
    if set(metrics) != EXPECTED_METRICS:
        raise InvalidReport(f"{path}: missing or unexpected benchmark metrics")
    for name, metric in metrics.items():
        if metric["unit"] != ("MiB" if name == "renderer-peak-rss" else "ms"):
            raise InvalidReport(f"{path}: incorrect unit for {name}")
    return {**report, "metrics": metrics}


def median_mad(values: list[float]) -> tuple[float, float]:
    median = statistics.median(values)
    return median, statistics.median(abs(value - median) for value in values)


def compare(baselines: list[dict], candidates: list[dict]) -> tuple[str, bool, list[str]]:
    if len(baselines) != 2 or len(candidates) != 2:
        raise InvalidReport("Two independent rounds per revision are required")
    reports = baselines + candidates
    names = set(reports[0]["metrics"])
    for report in reports:
        if set(report["metrics"]) != names:
            raise InvalidReport("Missing or extra metrics; refusing a partial comparison")
        if (report["os"], report["architecture"]) != (reports[0]["os"], reports[0]["architecture"]):
            raise InvalidReport("Measurements came from different platforms")
    for group in [baselines, candidates]:
        if group[0]["revision"] != group[1]["revision"]:
            raise InvalidReport("Revision changed between rounds")
    rows, warnings = [], []
    improved_count = regressed_count = 0
    for name in sorted(names):
        entries = [report["metrics"][name] for report in reports]
        if len({(entry["unit"], entry["inputSHA256"]) for entry in entries}) != 1:
            raise InvalidReport(f"{name}: units or input changed between measurements")
        unit = entries[0]["unit"]
        # Relative and absolute floors both apply. MAD prevents a noisy batch
        # from being interpreted as convincing evidence of a slowdown.
        floor = 16.0 if unit == "MiB" else (20.0 if "-open-" in name else 5.0)
        regressions = []
        improvements = []
        material_changes = []
        round_changes = []
        for base, candidate in zip(baselines, candidates):
            old, old_mad = median_mad(base["metrics"][name]["samples"])
            new, new_mad = median_mad(candidate["metrics"][name]["samples"])
            round_changes.append(f"{(new / old - 1) * 100:+.1f}%")
            threshold = max(old * 0.25, floor, 3 * (old_mad + new_mad))
            regressions.append(new - old > threshold)
            improvements.append(old - new > threshold)
            material_changes.append(new - old > max(old * 0.25, floor))
        old = statistics.median(x for report in baselines for x in report["metrics"][name]["samples"])
        new = statistics.median(x for report in candidates for x in report["metrics"][name]["samples"])
        regressed = all(regressions)
        improved = all(improvements)
        regressed_count += regressed
        improved_count += improved
        if any(material_changes) and not regressed:
            warnings.append(f"{name}: slowdown was noisy or not repeated in both rounds; rerun to investigate")
        if regressed or improved:
            status = "Regressed" if regressed else "Improved"
            rounds = " / ".join(round_changes)
            rows.append(f"| {name} | {old:.2f} | {new:.2f} | {(new / old - 1) * 100:+.1f}% | {rounds} | {unit} | **{status}** |")
    failed = regressed_count > 0
    table = [
        "| Metric | Base median | Candidate median | Combined change | Rounds 1 / 2 | Unit | Result |",
        "| --- | ---: | ---: | ---: | --- | --- | --- |", *rows,
    ] if rows else ["No confirmed improvements or regressions."]
    unchanged_count = len(names) - improved_count - regressed_count
    summary = "\n".join([
        "# Performance comparison", "",
        f"Base: `{baselines[0]['revision'][:12]}` · Candidate: `{candidates[0]['revision'][:12]}`", "",
        "**FAIL — confirmed regression**" if failed else "**PASS — no confirmed regression**", "",
        f"{len(names)} metrics checked: **{improved_count} improved**, **{regressed_count} regressed**, "
        f"{unchanged_count} without a confirmed change (omitted from the table).", "",
        *table, "",
        "All measurements remain available in the raw benchmark artifacts.", "",
        "Combined medians pool both rounds; per-round changes determine the gate and expose runner drift.", "",
        "Improvements and regressions must exceed 25% of baseline, the absolute floor, and the noise allowance in both rounds.",
        "Floors: 5 ms for rendering/edit work, 20 ms for page opening, 16 MiB for renderer peak RSS.",
        "Noise allowance: 3 × the sum of the two median absolute deviations. Lower is better.", "",
        "WebKit work includes real DOM/layout and driven animation callbacks; it does not measure display paint or frame pacing.",
        "RSS covers the Swift renderer process before WebKit starts, not WebContent or total app memory.", "",
        *[f"- Warning: {warning}" for warning in warnings], "",
    ])
    return summary, failed, warnings


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", nargs=2, type=Path, required=True)
    parser.add_argument("--candidate", nargs=2, type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    args = parser.parse_args()
    try:
        summary, failed, warnings = compare([load(p) for p in args.baseline], [load(p) for p in args.candidate])
    except (InvalidReport, KeyError, TypeError, ValueError) as error:
        args.summary.write_text(f"# Performance comparison\n\n**ERROR — no valid comparison**\n\n{error}\n")
        raise SystemExit(f"Invalid performance evidence: {error}") from error
    args.summary.write_text(summary)
    print(summary)
    for warning in warnings:
        print(f"::warning::{warning}")
    if failed:
        print("::error::Confirmed performance regression. See the job summary and raw benchmark artifacts.")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
