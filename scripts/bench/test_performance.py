import copy
import json
import tempfile
import unittest
from pathlib import Path

from compare_performance import EXPECTED_METRICS, InvalidReport, compare, load


def report(values, *, revision="base", name="render-prose-100k-wall", unit="ms"):
    return {"schema": 1, "revision": revision, "os": "macOS", "architecture": "64-bit",
            "metrics": {name: {"name": name, "unit": unit, "inputSHA256": "fixture-sha", "samples": values}}}


class PerformanceComparisonTests(unittest.TestCase):
    def compare_samples(self, base, candidate):
        return compare([report(base), report(base)],
                       [report(candidate, revision="head"), report(candidate, revision="head")])

    def test_unchanged_and_faster_changes_pass(self):
        for candidate in [[98, 100, 102], [68, 70, 72]]:
            self.assertFalse(self.compare_samples([98, 100, 102], candidate)[1])

    def test_confirmed_regression_fails(self):
        summary, failed, warnings = self.compare_samples([98, 100, 102], [138, 140, 142])
        self.assertTrue(failed)
        self.assertIn("**Regressed**", summary)
        self.assertFalse(warnings)

    def test_outlier_does_not_fail_the_median(self):
        self.assertFalse(self.compare_samples([100, 100, 100], [100, 100, 1000])[1])

    def test_small_absolute_difference_does_not_fail(self):
        self.assertFalse(self.compare_samples([1, 1, 1], [3, 3, 3])[1])

    def test_high_variability_does_not_claim_confirmed_regression(self):
        self.assertFalse(self.compare_samples([50, 100, 150], [100, 150, 200])[1])

    def test_single_bad_round_is_reported_as_warning(self):
        summary, failed, warnings = compare([report([100] * 3)] * 2,
                                           [report([140] * 3, revision="head"), report([100] * 3, revision="head")])
        self.assertFalse(failed)
        self.assertTrue(warnings)
        self.assertIn("- Warning: render-prose-100k-wall:", summary)
        self.assertNotIn("| render-prose-100k-wall |", summary)

    def test_confirmed_improvement_is_highlighted(self):
        summary, failed, warnings = self.compare_samples([98, 100, 102], [58, 60, 62])
        self.assertFalse(failed)
        self.assertFalse(warnings)
        self.assertIn("**Improved**", summary)
        self.assertIn("-40.0%", summary)
        self.assertIn("**1 improved**, **0 regressed**", summary)

    def test_small_noisy_or_one_round_improvements_are_omitted(self):
        cases = [
            ([[100] * 3] * 2, [[95] * 3] * 2),
            ([[10] * 3] * 2, [[6] * 3] * 2),
            ([[50, 100, 150]] * 2, [[30, 60, 90]] * 2),
            ([[100] * 3] * 2, [[60] * 3, [100] * 3]),
        ]
        for baseline, candidate in cases:
            with self.subTest(baseline=baseline, candidate=candidate):
                summary, failed, _ = compare([report(values) for values in baseline],
                                             [report(values, revision="head") for values in candidate])
                self.assertFalse(failed)
                self.assertNotIn("| render-prose-100k-wall |", summary)
                self.assertIn("No confirmed improvements or regressions.", summary)

    def test_unchanged_run_has_counts_and_no_empty_table(self):
        summary, failed, warnings = self.compare_samples([100] * 3, [100] * 3)
        self.assertFalse(failed)
        self.assertFalse(warnings)
        self.assertIn("1 metrics checked: **0 improved**, **0 regressed**, 1 without a confirmed change", summary)
        self.assertNotIn("| Metric |", summary)

    def test_mixed_table_only_shows_confirmed_changes(self):
        names = ["render-code-100k-wall", "render-links-100k-wall", "render-mixed-100k-wall"]
        baseline = report([100] * 3, name=names[0])
        candidate = report([60] * 3, name=names[0], revision="head")
        for name, samples in zip(names[1:], [[140] * 3, [102] * 3]):
            baseline["metrics"].update(report([100] * 3, name=name)["metrics"])
            candidate["metrics"].update(report(samples, name=name)["metrics"])
        summary, failed, warnings = compare([baseline] * 2, [candidate] * 2)
        self.assertTrue(failed)
        self.assertFalse(warnings)
        self.assertIn(f"| {names[0]} |", summary)
        self.assertIn(f"| {names[1]} |", summary)
        self.assertNotIn(f"| {names[2]} |", summary)
        self.assertIn("3 metrics checked: **1 improved**, **1 regressed**, 1 without a confirmed change", summary)

    def test_memory_improvement_uses_memory_floor(self):
        base = report([60], name="renderer-peak-rss", unit="MiB")
        for value, visible in [(44, False), (40, True)]:
            head = report([value], revision="head", name="renderer-peak-rss", unit="MiB")
            summary, failed, _ = compare([base] * 2, [head] * 2)
            self.assertFalse(failed)
            self.assertEqual("**Improved**" in summary, visible)

    def test_memory_has_an_absolute_floor(self):
        base = report([20], name="renderer-peak-rss", unit="MiB")
        head = report([30], revision="head", name="renderer-peak-rss", unit="MiB")
        self.assertFalse(compare([base] * 2, [head] * 2)[1])
        head["metrics"]["renderer-peak-rss"]["samples"] = [60]
        self.assertTrue(compare([base] * 2, [head] * 2)[1])

    def test_missing_metrics_and_different_inputs_are_errors(self):
        baseline = report([100] * 3)
        for change in ["missing", "input", "platform", "revision"]:
            candidate = copy.deepcopy(baseline)
            if change == "missing":
                candidate["metrics"] = {}
            elif change == "input":
                candidate["metrics"]["render-prose-100k-wall"]["inputSHA256"] = "changed"
            elif change == "platform":
                candidate["os"] = "another machine"
            else:
                candidate["revision"] = "changed"
            with self.assertRaises(InvalidReport):
                compare([baseline] * 2, [baseline, candidate])

    def test_missing_round_is_an_error(self):
        with self.assertRaises(InvalidReport):
            compare([report([100] * 3)], [report([100] * 3)])

    def test_complete_report_loads_and_a_partial_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            data = report([100] * 3)
            data["metrics"] = [report([100] * 3, name=name, unit="MiB" if name == "renderer-peak-rss" else "ms")
                               ["metrics"][name] for name in EXPECTED_METRICS]
            path.write_text(json.dumps(data))
            self.assertEqual(len(load(path)["metrics"]), 18)
            data["metrics"].pop()
            path.write_text(json.dumps(data))
            with self.assertRaises(InvalidReport):
                load(path)

    def test_invalid_samples_and_duplicate_metrics_are_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            for values in [[float("nan")] * 3, [float("inf")] * 3, [-1] * 3, [0] * 3, [True] * 3, [1]]:
                data = report(values)
                data["metrics"] = list(data["metrics"].values())
                path.write_text(json.dumps(data))
                with self.assertRaises(InvalidReport):
                    load(path)
            data = report([1, 2, 3])
            data["metrics"] = list(data["metrics"].values()) * 2
            path.write_text(json.dumps(data))
            with self.assertRaises(InvalidReport):
                load(path)


if __name__ == "__main__":
    unittest.main()
