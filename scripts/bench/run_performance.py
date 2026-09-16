#!/usr/bin/env python3
"""Benchmark two git revisions in Release on one Mac using identical fixtures/harness."""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def run(command: list[str], *, log: Path | None = None, **kwargs) -> subprocess.CompletedProcess:
    print("+", " ".join(map(str, command)), flush=True)
    if log:
        with log.open("w") as stream:
            return subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True, **kwargs)
    return subprocess.run(command, check=True, text=True, **kwargs)


def revision(value: str) -> str:
    return subprocess.check_output(["git", "rev-parse", "--verify", value + "^{commit}"], cwd=ROOT, text=True).strip()


def legacy_editor(snapshot: Path) -> str:
    """Adapt the pre-extraction page for this PR's first baseline, preserving its HTML/CSS/JS."""
    old = (snapshot / "md-preview/Features/Editor/EditorViewController.swift").read_text()
    template = (ROOT / "md-preview/Features/Editor/EditorHTML.swift").read_text()
    start = '        return """\n        <!DOCTYPE html>'
    end = '\n        """\n    }'
    old_start = old.index(start, old.index("private static func editorHTML("))
    old_end = old.index(end, old_start)
    body = old[old_start:old_end]
    replacements = {
        "ThemeColorsSetting.current.editorOverrideCSS": "configuration.themeOverrideCSS",
        "EditorBridge.name": "configuration.bridgeName",
    }
    for previous, replacement in replacements.items():
        if body.count(previous) != 1:
            raise ValueError(f"Legacy editor adapter no longer matches {previous}")
        body = body.replace(previous, replacement)
    current_start = template.index(start)
    current_end = template.index(end, current_start)
    return template[:current_start] + body + template[current_end:]


def prepare(label: str, commit: str, out: Path) -> tuple[Path, Path]:
    snapshot = out / "work" / label / "repo"
    package = out / "work" / label / "probe"
    snapshot.mkdir(parents=True)
    archive = out / f"{label}.tar"
    run(["git", "archive", "--format=tar", "--output", str(archive), commit], cwd=ROOT)
    run(["tar", "-xf", str(archive), "-C", str(snapshot)])
    archive.unlink()
    sources = package / "Sources"
    sources.mkdir(parents=True)
    for source in (ROOT / "tests/swift-tests/Sources/MarkdownHelpers").glob("*.swift"):
        destination = sources / source.name
        if source.is_symlink():
            relative = source.resolve().relative_to(ROOT)
            production = snapshot / relative
            if production.exists():
                # Older checkouts need only the test bundle lookup. Production
                # rendering code and assets otherwise come from that revision.
                text = production.read_text()
                if source.name == "MarkdownHTML+Utils.swift":
                    if "moduleSubdir" not in text:
                        lookup = '\n'.join([
                            '        let moduleSubdir = subdir.hasPrefix("Vendor/") ? String(subdir.dropFirst(7)) : subdir',
                            '        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: moduleSubdir) { return url }',
                            '',
                        ])
                        text, count = re.subn(r"(?m)^        (?:var|let) bundles =", lambda match: lookup + match[0], text, count=1)
                        if count != 1:
                            raise ValueError("Vendor resource lookup changed")
                    destination.write_text(text)
                else:
                    destination.symlink_to(production)
            elif source.name == "EditorHTML.swift":
                destination.write_text(legacy_editor(snapshot))
            else:
                raise ValueError(f"Production source missing: {production}")
        else:
            shutil.copy2(source, destination)
    (sources / "Vendor").symlink_to(snapshot / "md-preview/Vendor", target_is_directory=True)
    shutil.copy2(ROOT / "tests/performance/Benchmark.swift", sources / "Benchmark.swift")
    # The app currently ignores Package.resolved. Keep explicit parser pins in
    # this suite; use each revision's pins once the gate exists on both sides.
    pins_file = snapshot / "tests/performance/dependencies.json"
    if not pins_file.exists():
        pins_file = ROOT / "tests/performance/dependencies.json"
    pins = json.loads(pins_file.read_text())["pins"]
    parser_pins = {pin["identity"]: pin for pin in pins if pin["identity"] in {"swift-markdown", "swift-cmark"}}
    if set(parser_pins) != {"swift-markdown", "swift-cmark"}:
        raise ValueError("Benchmark parser dependencies are not pinned")
    dependencies = ",\n".join(
        f'.package(url: {json.dumps(pin["location"])}, revision: {json.dumps(pin["state"]["revision"])})'
        for pin in parser_pins.values()
    )
    (package / "Package.swift").write_text('''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "PerformanceProbe", platforms: [.macOS(.v15)], dependencies: [
''' + dependencies + '''], targets: [
.executableTarget(name: "PerformanceProbe", dependencies: [.product(name: "Markdown", package: "swift-markdown")],
                  path: "Sources", resources: ["CodeMirror", "DOMPurify", "Highlight", "KaTeX", "Mermaid", "Morphdom"].map { .copy("Vendor/\\($0)") })
])
''')
    run(["swift", "build", "-c", "release", "--package-path", str(package), "--product", "PerformanceProbe"],
        log=out / f"{label}-build.log", timeout=900)
    binary_dir = subprocess.check_output(["swift", "build", "-c", "release", "--package-path", str(package), "--show-bin-path"], text=True).strip()
    return snapshot, Path(binary_dir) / "PerformanceProbe"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True, help="PR base SHA, or previous main SHA")
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--out", type=Path, required=True, help="New output directory")
    parser.add_argument("--samples", type=int, default=7)
    args = parser.parse_args()
    if args.samples < 3:
        parser.error("--samples must be at least 3")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out / "work").exists():
        parser.error("Use a new output directory; previous benchmark work exists")
    refs = {"baseline": revision(args.base), "candidate": revision(args.candidate)}
    (out / "revisions.json").write_text(json.dumps(refs, indent=2))
    (out / "environment.json").write_text(json.dumps({
        "platform": platform.platform(), "architecture": platform.machine(),
        "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    }, indent=2))
    summary = out / "summary.md"
    summary.write_text("# Performance comparison\n\n**ERROR — benchmark did not finish**\n\nInspect the build/run logs in the artifact.\n")
    try:
        executables = {label: prepare(label, commit, out) for label, commit in refs.items()}
        fixture = out / "mixed.md"
        shutil.copy2(ROOT / "tests/performance/mixed.md", fixture)
        # ABBA balances warm caches / runner drift. Never measure both builds
        # concurrently. Both use the exact same harness and fixture bytes.
        for label, round_number in [("baseline", 1), ("candidate", 1), ("candidate", 2), ("baseline", 2)]:
            snapshot, executable = executables[label]
            environment = {**os.environ, "MDP_BENCH_ROOT": str(snapshot), "MDP_BENCH_FIXTURE": str(fixture),
                           "MDP_BENCH_REVISION": refs[label], "MDP_BENCH_SAMPLES": str(args.samples),
                           "MDP_BENCH_OUTPUT": str(out / f"{label}-{round_number}.json")}
            run([str(executable)], env=environment, log=out / f"{label}-{round_number}.log", timeout=240)
        run([sys.executable, str(ROOT / "scripts/bench/compare_performance.py"),
             "--baseline", str(out / "baseline-1.json"), str(out / "baseline-2.json"),
             "--candidate", str(out / "candidate-1.json"), str(out / "candidate-2.json"),
             "--summary", str(summary)])
    finally:
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as stream:
                stream.write(summary.read_text())


if __name__ == "__main__":
    main()
