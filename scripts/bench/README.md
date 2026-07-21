# Benchmark harness

Pragmatic CPU/memory/first-paint benchmarking for the Markdown Preview app
and its Quick Look extension. Built for the morphdom/first-paint performance
experiment — baseline vs candidate comparisons, not CI.

## What's here

| File | Purpose |
|---|---|
| `bench-app.sh` | Launches the app cold per sample, samples RSS/CPU of the app + its WebContent process(es) every 500 ms, parses debug perf logs (FCP, Swift render, `MdPreview.update`) into a CSV. |
| `bench-ql.sh` | Resets Quick Look, opens `qlmanage -p <sample>`, samples RSS/CPU of `qlmanage`, `QuickLookUIService`, and the `quick-look` appex; captures the appex's provide wall-time from debug logs. |
| `report.py` | Joins two CSV directories on (sample, metric) and prints a markdown comparison table. Stdlib python3 only. |
| `../../samples/mermaid-heavy.md` | Stress sample: ~10 Mermaid diagrams, Swift/TypeScript/Bash code fences, `$...$` / `$$...$$` math — exercises all three renderers at once. |

All log-derived metrics (`fcp_ms`, `render_ms`, `update_ms`, `ql_provide_ms`)
require a **Debug** build — the perf instrumentation is compiled out of
Release. RSS/CPU sampling works with any build.

## Baseline vs candidate workflow

```bash
# 1. Baseline: on main (or the pre-change commit)
scripts/bench/bench-app.sh --label baseline --out /tmp/bench/baseline

# 2. Candidate: check out the experiment branch, rebuild, rerun
scripts/bench/bench-app.sh --label candidate --out /tmp/bench/candidate

# 3. Compare
scripts/bench/report.py --baseline /tmp/bench/baseline --candidate /tmp/bench/candidate
```

`bench-app.sh` builds Debug via xcodebuild by default; pass
`--app <path/to/Markdown Preview.app>` to reuse an existing build. Default
samples are `samples/navigation.md` (small/plain), `samples/full.md`
(math + code), and `samples/mermaid-heavy.md`; pass sample paths as
positional args to override. `--duration` (default 20 s) controls the
sampling window per sample.

CSV rows are `label,sample,metric,value` with metrics:
`fcp_ms`, `render_ms`, `update_ms` (mean), `update_count`,
`rss_peak_kb_app`, `rss_mean_kb_app`, `rss_peak_kb_webcontent`,
`rss_mean_kb_webcontent`, `cpu_mean_app`, `cpu_mean_webcontent`.

## Quick Look runs

```bash
scripts/bench/bench-ql.sh --label baseline --out /tmp/bench-ql/baseline samples/full.md
```

The just-built app must be registered with LaunchServices so its appex
serves `.md` previews. Open the built app once, or:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f <path/to/Markdown Preview.app>
pluginkit -m -p com.apple.quicklook.preview | grep md-preview   # verify
```

(`qlmanage -m plugins` only lists legacy generators — appex-based extensions
show up in `pluginkit`.) A `+` marks the elected extension. If an installed
Release copy is elected instead of the Debug build (bundle id
`doc.md-preview.dev.quick-look`), elect the Debug appex for the run:

```bash
pluginkit -e use -i doc.md-preview.dev.quick-look
# …and restore afterwards:
pluginkit -e default -i doc.md-preview.dev.quick-look
```

If no `[mdp-perf-ql]` lines are captured, the elected appex is either a
Release build (instrumentation compiled out) or a different copy than the
one you just built. Beware: every Debug build of this project registers an
appex with the same bundle id (`doc.md-preview.dev.quick-look`), so multiple
worktrees/DerivedData folders compete and LaunchServices picks one
arbitrarily. Verify which binary actually served the preview with
`ps -axo pid,comm | grep quick-look.appex` while the panel is open, and
`lsregister -u` stale copies if the wrong one wins.

## Manual edit-cycle procedure

Measures the innerHTML-swap (or morphdom) update path under repeated edits:

1. Start a long sampling window:
   `scripts/bench/bench-app.sh --duration 60 --label edit-cycle samples/mermaid-heavy.md`
2. While it samples, in the app window that opens: enter edit mode, change
   one paragraph, exit edit mode. Repeat 5 times at a steady pace.
3. The `MdPreview.update (+Nms)` log lines are the per-cycle timing source —
   the CSV reports their mean as `update_ms` and the count as
   `update_count`. CPU/RSS means over the window capture the cost of the
   cycles themselves.
4. Repeat on the candidate branch with a different `--out`, then compare
   with `report.py`.

## Caveats

- **Quit other WebKit-based apps** (Safari, Mail, Notes, anything with a web
  view) during runs. WebContent attribution works by diffing
  `com.apple.WebKit.WebContent` pids before/after launch — another app
  spawning one mid-run gets misattributed.
- `fcp_ms` and `render_ms` take the **last** matching entry in the window:
  the launch-time vendor warmup and any restored windows emit earlier ones,
  and the freshly opened sample always renders after them. Don't interact
  with the app during timed opens.
- `bench-app.sh` deletes the app's saved window state (in its sandbox
  container) before each launch so macOS window restoration doesn't reopen
  the previous sample and pollute RSS/CPU and update timings.
- `footprint` snapshots usually need sudo; the script degrades to ps-only
  RSS when unavailable.
- `update_ms` blends in one small launch-warmup `MdPreview.update` that the
  log can't distinguish from the sample's own updates. On cold-open runs
  (update_count ≈ 2) treat it as indicative only; edit-cycle runs dilute the
  warmup to noise. Always compare `update_count` between baseline and
  candidate to make sure you're averaging the same population.
- `ps pcpu` is a decaying average, not an instantaneous reading — treat
  `cpu_mean_*` as relative between runs, not absolute utilization.
- `bench-ql.sh` finds the appex via `pgrep -f quick-look`, which can match
  unrelated processes whose command line contains that string (e.g. an
  editor with this repo open). Close those first.
- Runs are single-shot per invocation. For less noise, run each side 3× into
  the same `--out` dir — `report.py` averages duplicate (sample, metric)
  keys within a directory.
