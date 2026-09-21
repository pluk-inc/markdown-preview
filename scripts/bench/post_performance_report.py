#!/usr/bin/env python3
"""Post one performance comment per PR workflow run attempt, including failures."""
from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import zipfile
from urllib.parse import urlencode


def api(endpoint, *, body=None, raw=False):
    command = ["gh", "api", endpoint]
    if body is not None:
        command += ["--method", "POST", "--input", "-"]
    result = subprocess.run(command, input=json.dumps(body).encode() if body else None,
                            stdout=subprocess.PIPE, check=True).stdout
    return result if raw else json.loads(result)


def pages(endpoint, key=None):
    separator = "&" if "?" in endpoint else "?"
    page = 1
    while True:
        response = api(f"{endpoint}{separator}per_page=100&page={page}")
        items = response[key] if key else response
        yield from items
        if len(items) < 100:
            return
        page += 1


def read_report(archive):
    # Read only these two bounded files in memory, never extract or execute PR files.
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        def read(name, limit):
            if name not in zipped.namelist():
                return ""
            if zipped.getinfo(name).file_size > limit:
                raise ValueError(f"Report file is too large: {name}")
            return zipped.read(name).decode("utf-8").strip()

        number = read("pr-number.txt", 32)
        return int(number) if number else None, read("summary.md", 48_000)


def validate_pull(pull, run, repository):
    associated = {item["number"] for item in run["pull_requests"]}
    if (pull["base"]["repo"]["full_name"] != repository
            or (pull["head"]["repo"] or {}).get("id") != run["head_repository"]["id"]
            or pull["head"]["ref"] != run["head_branch"]
            or (associated and pull["number"] not in associated)):
        raise ValueError("PR does not match the performance run")


def compact_summary(summary):
    counts = re.search(r"(?m)^(\d+) metrics checked: \*\*(\d+) improved\*\*, \*\*(\d+) regressed\*\*", summary)
    if counts:
        total, improved, regressed = counts.groups()
        result = f"{total} checked · **{improved} improved** · **{regressed} regressed**"
    elif "**FAIL — confirmed regression**" in summary:
        result = "Performance regression detected."
    elif "**PASS — no confirmed regression**" in summary:
        result = "No confirmed regressions."
    else:
        result = "Benchmark incomplete."

    warnings = sum(line.startswith("- Warning:") for line in summary.splitlines())
    if warnings:
        result += f" · **{warnings} {'warning' if warnings == 1 else 'warnings'}**"

    rows = []
    for line in summary.splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if len(cells) == 7 and cells[-1].strip("*") in {"Improved", "Regressed", "REGRESSION"}:
            name, base, candidate, change, _, unit, status = cells
            rows.append(f"| {name} | {base} {unit} | {candidate} {unit} | {change} | {status} |")
    if rows:
        result += "\n\n" + "\n".join([
            "| Metric | Base | PR | Change | Result |",
            "| --- | ---: | ---: | ---: | --- |", *rows,
        ])
    return result


def comment_body(run, summary):
    attempt = run["run_attempt"]
    marker = f"<!-- performance-report:{run['id']}:{attempt} -->"
    conclusion = run["conclusion"].replace("_", " ")
    link = f"{run['html_url']}/attempts/{attempt}"
    return "\n\n".join([
        marker,
        "## Performance report",
        compact_summary(summary),
        f"`{run['head_sha'][:8]}` · {conclusion} · [Full report]({link})",
    ])


def post_report(repository, run_id, attempt):
    root = f"repos/{repository}"
    # Fetch the requested attempt so a later rerun cannot change this report's status.
    run = api(f"{root}/actions/runs/{run_id}/attempts/{attempt}")
    if (run["event"] != "pull_request" or run["status"] != "completed"
            or run["path"] != ".github/workflows/performance.yml"):
        raise ValueError("Expected a completed Performance pull-request run")

    number, summary = None, ""
    artifacts = pages(f"{root}/actions/runs/{run_id}/artifacts", "artifacts")
    artifact = next((item for item in artifacts
                     if item["name"] == f"performance-pr-report-{attempt}" and not item["expired"]), None)
    if artifact:
        if artifact["size_in_bytes"] > 1_000_000:
            raise ValueError("PR report artifact is too large")
        number, summary = read_report(api(f"{root}/actions/artifacts/{artifact['id']}/zip", raw=True))

    if number is None:
        # Early failures/cancellations may not upload an artifact. GitHub omits
        # pull_requests on some fork runs, so resolve the branch in that case.
        numbers = [item["number"] for item in run["pull_requests"]]
        if not numbers:
            query = urlencode({"state": "all", "head": f"{run['head_repository']['owner']['login']}:{run['head_branch']}"})
            numbers = [item["number"] for item in pages(f"{root}/pulls?{query}")
                       if (item["head"]["repo"] or {}).get("id") == run["head_repository"]["id"]]
        if len(numbers) != 1:
            raise ValueError("Cannot identify a single PR for the performance run")
        number = numbers[0]

    pull = api(f"{root}/pulls/{number}")
    validate_pull(pull, run, repository)
    body = comment_body(run, summary)
    marker = body.splitlines()[0]
    for comment in pages(f"{root}/issues/{number}/comments"):
        if (comment["user"]["login"] == "github-actions[bot]"
                and comment["body"].startswith(marker)):
            print(f"Report already posted: {comment['html_url']}")
            return
    result = api(f"{root}/issues/{number}/comments", body={"body": body})
    print(result["html_url"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    args = parser.parse_args()
    post_report(args.repository, args.run_id, args.attempt)
