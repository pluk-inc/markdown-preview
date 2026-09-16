import copy
import io
import unittest
import zipfile
from unittest.mock import patch

from compare_performance import compare
from post_performance_report import comment_body, compact_summary, post_report, read_report, validate_pull
from test_performance import report


def workflow_run(**changes):
    return {"id": 42, "run_attempt": 1, "run_number": 7,
            "event": "pull_request", "status": "completed", "conclusion": "success",
            "path": ".github/workflows/performance.yml", "head_sha": "a" * 40,
            "html_url": "https://github.com/owner/repo/actions/runs/42",
            "head_repository": {"id": 2, "owner": {"login": "contributor"}},
            "head_branch": "feature", "pull_requests": [{"number": 9}], **changes}


def pull_request():
    return {"number": 9, "base": {"repo": {"full_name": "owner/repo"}},
            "head": {"repo": {"id": 2}, "ref": "feature", "sha": "b" * 40}}


def archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as zipped:
        for name, content in files.items():
            zipped.writestr(name, content)
    return output.getvalue()


class PerformanceReportTests(unittest.TestCase):
    def test_reads_only_report_files_without_extracting(self):
        number, summary = read_report(archive({"pr-number.txt": "9\n", "summary.md": "**PASS**\n",
                                               "../../unexpected.py": "raise RuntimeError()"}))
        self.assertEqual((number, summary), (9, "**PASS**"))

    def test_rejects_oversized_reports_and_invalid_pr_numbers(self):
        for files in [{"summary.md": "a" * 48_001}, {"pr-number.txt": "not a number"}]:
            with self.assertRaises(ValueError):
                read_report(archive(files))

    def test_missing_summary_is_not_reported_as_a_pass(self):
        self.assertEqual(read_report(archive({"pr-number.txt": "9"})), (9, ""))
        for conclusion in ["failure", "cancelled", "timed_out"]:
            body = comment_body(workflow_run(conclusion=conclusion), "")
            self.assertIn("Benchmark incomplete.", body)
            self.assertIn(f"· {conclusion.replace('_', ' ')} ·", body)
            self.assertEqual(body.splitlines()[2], "## Performance report")

    def test_each_attempt_has_its_own_marker_and_link(self):
        for attempt in [1, 2]:
            body = comment_body(workflow_run(run_attempt=attempt), "**PASS — no confirmed regression**")
            self.assertIn(f"<!-- performance-report:42:{attempt} -->", body)
            self.assertIn(f"/attempts/{attempt})", body)
            self.assertIn("No confirmed regressions.", body)

    def test_quiet_run_is_one_line_without_methodology_or_duplicate_headings(self):
        summary, _, _ = compare([report([100] * 3)] * 2, [report([100] * 3, revision="head")] * 2)
        body = comment_body(workflow_run(), summary)
        self.assertIn("1 checked · **0 improved** · **0 regressed**", body)
        self.assertEqual(body.count("[Full report]"), 1)
        self.assertEqual(body.count("#"), 2)
        self.assertNotIn("noise allowance", body)
        self.assertNotIn("without a confirmed change", body)
        self.assertNotIn("| Metric |", body)
        self.assertLess(len(body), 300)

    def test_changed_rows_retain_measurements_but_omit_per_round_detail(self):
        base = report([100] * 3)
        candidate = report([60] * 3, revision="head")
        base["metrics"].update(report([100] * 3, name="render-code-100k-wall")["metrics"])
        candidate["metrics"].update(report([140] * 3, name="render-code-100k-wall")["metrics"])
        summary, _, _ = compare([base] * 2, [candidate] * 2)
        compact = compact_summary(summary)
        self.assertIn("2 checked · **1 improved** · **1 regressed**", compact)
        self.assertIn("| render-prose-100k-wall | 100.00 ms | 60.00 ms | -40.0% | **Improved** |", compact)
        self.assertIn("| render-code-100k-wall | 100.00 ms | 140.00 ms | +40.0% | **Regressed** |", compact)
        self.assertNotIn("Rounds 1 / 2", compact)
        self.assertNotIn("Floors:", compact)

    def test_warning_count_stays_visible_without_long_warning_text(self):
        summary, _, _ = compare([report([100] * 3)] * 2,
                                 [report([140] * 3, revision="head"), report([100] * 3, revision="head")])
        compact = compact_summary(summary)
        self.assertEqual(compact, "1 checked · **0 improved** · **0 regressed** · **1 warning**")

    def test_error_report_and_missing_report_remain_incomplete(self):
        for summary in ["", "# Performance comparison\n\n**ERROR — no valid comparison**\n\nMissing metrics"]:
            self.assertEqual(compact_summary(summary), "Benchmark incomplete.")

    def test_old_passing_rows_do_not_reappear_in_compact_table(self):
        summary = "**PASS — no confirmed regression**\n| metric | 100 | 100 | +0.0% | +0% / +0% | ms | pass |"
        self.assertEqual(compact_summary(summary), "No confirmed regressions.")

    def test_validates_fork_destination_and_allows_a_newer_pr_head(self):
        validate_pull(pull_request(), workflow_run(pull_requests=[]), "owner/repo")
        for field in ["base", "repository", "branch", "number"]:
            pull = copy.deepcopy(pull_request())
            if field == "base":
                pull["base"]["repo"]["full_name"] = "another/repo"
            elif field == "repository":
                pull["head"]["repo"]["id"] = 3
            elif field == "branch":
                pull["head"]["ref"] = "another-branch"
            else:
                pull["number"] = 10
            with self.assertRaises(ValueError):
                validate_pull(pull, workflow_run(), "owner/repo")

    def exercise_post(self, *, run=None, artifacts=(), comments=(), summary="**PASS**"):
        def request(endpoint, *, body=None, raw=False):
            if "/attempts/" in endpoint:
                return run or workflow_run()
            if "/artifacts?" in endpoint:
                return {"artifacts": list(artifacts)}
            if "/artifacts/" in endpoint:
                self.assertEqual(endpoint, "repos/owner/repo/actions/artifacts/123/zip")
                self.assertTrue(raw)
                return archive({"pr-number.txt": "9", "summary.md": summary})
            if "/pulls?" in endpoint:
                return [pull_request()]
            if endpoint.endswith("/pulls/9"):
                return pull_request()
            if body:
                return {"html_url": "https://github.com/owner/repo/pull/9#issuecomment-1"}
            return list(comments)

        with patch("post_performance_report.api", side_effect=request) as mocked:
            post_report("owner/repo", 42, (run or workflow_run())["run_attempt"])
        return [call.kwargs["body"]["body"] for call in mocked.call_args_list if call.kwargs.get("body")]

    def test_posts_table_for_a_failed_regression(self):
        bodies = self.exercise_post(run=workflow_run(conclusion="failure"), summary="**FAIL — confirmed regression**",
                                    artifacts=[{"name": "performance-pr-report-1", "expired": False,
                                                "size_in_bytes": 100, "id": 123}])
        self.assertEqual(len(bodies), 1)
        self.assertIn("Performance regression detected.", bodies[0])

    def test_early_fork_failure_without_an_artifact_still_comments(self):
        bodies = self.exercise_post(run=workflow_run(conclusion="failure", pull_requests=[]))
        self.assertEqual(len(bodies), 1)
        self.assertIn("Benchmark incomplete.", bodies[0])

    def test_later_attempt_cannot_reuse_an_earlier_report(self):
        bodies = self.exercise_post(run=workflow_run(run_attempt=2, conclusion="cancelled"),
                                    artifacts=[{"name": "performance-pr-report-1", "expired": False}])
        self.assertIn("Benchmark incomplete.", bodies[0])
        self.assertIn("performance-report:42:2", bodies[0])

    def test_retrying_reporter_does_not_duplicate_a_bot_comment(self):
        comment = {"user": {"login": "github-actions[bot]"},
                   "body": comment_body(workflow_run(), "**PASS**"), "html_url": "https://example.com/comment"}
        self.assertEqual(self.exercise_post(comments=[comment]), [])
        comment["user"]["login"] = "contributor"
        self.assertEqual(len(self.exercise_post(comments=[comment])), 1)

    def test_refuses_non_pr_and_unrelated_workflow_runs(self):
        for changes in [{"event": "push"}, {"path": ".github/workflows/other.yml"}, {"status": "in_progress"}]:
            with self.assertRaises(ValueError):
                self.exercise_post(run=workflow_run(**changes))


if __name__ == "__main__":
    unittest.main()
