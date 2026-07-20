#!/bin/bash
#
# bench-app.sh — CPU/memory/first-paint benchmark for the Markdown Preview app.
#
# For each sample file it launches the built app cold, captures the debug
# perf log lines (subsystem doc.md-preview*, category perf), samples RSS/CPU
# of the app process and its WebKit WebContent process(es) every 500 ms, and
# writes one CSV of metrics per run.
#
# Usage:
#   scripts/bench/bench-app.sh [--app <path/to/Markdown Preview.app>]
#                              [--duration <sec>] [--out <dir>] [--label <name>]
#                              [sample.md ...]
#
# Without --app it builds Debug via xcodebuild and locates the product in
# DerivedData. Default samples: samples/navigation.md, samples/full.md,
# samples/mermaid-heavy.md. Log-derived metrics (fcp_ms, render_ms, update_ms)
# need a Debug build — Release compiles the perf instrumentation out.
#
# Tip: quit other WebKit-based apps (Safari, Mail previews, …) during runs so
# new com.apple.WebKit.WebContent processes attribute cleanly to this app.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_PATH=""
DURATION=20
OUT_DIR=""
LABEL="run"
SAMPLES=()
INTERVAL=0.5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)      APP_PATH="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        -h|--help)  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*)        echo "unknown option: $1" >&2; exit 2 ;;
        *)          SAMPLES+=("$1"); shift ;;
    esac
done

if [[ ${#SAMPLES[@]} -eq 0 ]]; then
    SAMPLES=(
        "$REPO_ROOT/samples/navigation.md"
        "$REPO_ROOT/samples/full.md"
        "$REPO_ROOT/samples/mermaid-heavy.md"
    )
fi
for s in "${SAMPLES[@]}"; do
    [[ -f "$s" ]] || { echo "sample not found: $s" >&2; exit 1; }
done

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$REPO_ROOT/bench-results/$LABEL-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/app.csv"
echo "label,sample,metric,value" > "$CSV"

# ---------------------------------------------------------------- build/locate

if [[ -z "$APP_PATH" ]]; then
    echo "==> Building Debug (pass --app to skip)…"
    xcodebuild -project "$REPO_ROOT/md-preview.xcodeproj" -scheme md-preview \
        -configuration Debug build -quiet || { echo "build failed" >&2; exit 1; }
    SETTINGS="$(xcodebuild -project "$REPO_ROOT/md-preview.xcodeproj" \
        -scheme md-preview -configuration Debug -showBuildSettings 2>/dev/null)"
    PRODUCTS_DIR="$(echo "$SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
    PRODUCT_NAME="$(echo "$SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME =/ {print $2; exit}')"
    APP_PATH="$PRODUCTS_DIR/$PRODUCT_NAME"
fi
[[ -d "$APP_PATH" ]] || { echo "app not found: $APP_PATH" >&2; exit 1; }
echo "==> App: $APP_PATH"
echo "==> Output: $OUT_DIR"

APP_PROC_NAME="Markdown Preview"
BUNDLE_ID="$(defaults read "$APP_PATH/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"

# Window restoration reopens documents from the previous run, polluting both
# the perf log and RSS/CPU attribution — wipe saved state for a clean cold open.
clear_saved_state() {
    [[ -n "$BUNDLE_ID" ]] || return 0
    rm -rf "$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Saved Application State/$BUNDLE_ID.savedState" \
           "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" 2>/dev/null
}

quit_app() {
    osascript -e "quit app \"$APP_PROC_NAME\"" >/dev/null 2>&1
    for _ in $(seq 1 10); do
        pgrep -x "$APP_PROC_NAME" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    pkill -x "$APP_PROC_NAME" 2>/dev/null
    sleep 1
}

webcontent_pids() {
    pgrep -f 'com.apple.WebKit.WebContent' 2>/dev/null || true
}

# not_in "list" pid → true when pid is absent from the whitespace-separated list
not_in() {
    local list="$1" pid="$2" p
    for p in $list; do [[ "$p" == "$pid" ]] && return 1; done
    return 0
}

# Extract metrics from a captured `log stream` file and the raw ps samples,
# append CSV rows. Args: sample-name, logfile, psfile.
emit_metrics() {
    local name="$1" logfile="$2" psfile="$3" v

    # FCP: last occurrence wins — the launch warmup page can also emit one,
    # and the real document's paint always comes after it.
    v="$(grep -oE 'paint:first-contentful-paint [0-9.]+ms' "$logfile" \
        | tail -1 | grep -oE '[0-9.]+')"
    [[ -n "$v" ]] && echo "$LABEL,$name,fcp_ms,$v" >> "$CSV"

    # Swift-side markdown→HTML render time for the displayed document. Last
    # occurrence wins: macOS window restoration re-renders previously open
    # documents first, and the freshly opened sample always renders after.
    v="$(grep -oE '\[mdp-perf-swift\] display render \+[0-9]+ms' "$logfile" \
        | tail -1 | grep -oE '[0-9]+')"
    [[ -n "$v" ]] && echo "$LABEL,$name,render_ms,$v" >> "$CSV"

    # JS-side MdPreview.update duration — mean across all occurrences
    # (initial populate + any fast-path/edit-cycle updates during the window).
    # Caveat: the launch-time warmup page fires one small update of its own
    # that can't be told apart in the log, so cold-open means blend it in —
    # compare update_count between runs and prefer edit-cycle runs (many
    # updates) when update_ms is the metric under test.
    grep -oE 'MdPreview\.update \(\+[0-9.]+ms\)' "$logfile" \
        | grep -oE '[0-9.]+' \
        | awk -v L="$LABEL" -v S="$name" '
            { sum += $1; n++ }
            END { if (n) printf "%s,%s,update_ms,%.1f\n%s,%s,update_count,%d\n",
                          L, S, sum/n, L, S, n }' >> "$CSV"

    # RSS / CPU stats from the ps samples (columns: role rss_kb pcpu).
    awk -v L="$LABEL" -v S="$name" '
        {
            role = $1; rss = $2; cpu = $3
            if (rss > peak[role]) peak[role] = rss
            rss_sum[role] += rss; cpu_sum[role] += cpu; n[role]++
        }
        END {
            for (r in n) {
                printf "%s,%s,rss_peak_kb_%s,%d\n", L, S, r, peak[r]
                printf "%s,%s,rss_mean_kb_%s,%d\n", L, S, r, rss_sum[r]/n[r]
                printf "%s,%s,cpu_mean_%s,%.1f\n", L, S, r, cpu_sum[r]/n[r]
            }
        }' "$psfile" >> "$CSV"
}

run_sample() {
    local sample="$1"
    local name; name="$(basename "$sample" .md)"
    local logfile="$OUT_DIR/$name.log"
    local psfile="$OUT_DIR/$name.ps.tsv"
    : > "$psfile"

    echo "==> Sample: $name (${DURATION}s)"
    quit_app
    clear_saved_state

    # WebContent pids that exist before launch belong to other apps.
    local baseline_wc; baseline_wc="$(webcontent_pids)"

    # Start the log capture before launch so early perf lines aren't missed.
    log stream --level debug --style compact \
        --predicate 'subsystem BEGINSWITH "doc.md-preview"' \
        > "$logfile" 2>/dev/null &
    local log_pid=$!
    sleep 1

    open -a "$APP_PATH" "$sample"

    local app_pid=""
    for _ in $(seq 1 20); do
        app_pid="$(pgrep -x "$APP_PROC_NAME" | head -1)"
        [[ -n "$app_pid" ]] && break
        sleep 0.5
    done
    if [[ -z "$app_pid" ]]; then
        echo "    app never launched, skipping" >&2
        kill "$log_pid" 2>/dev/null
        return 1
    fi

    # Sample every INTERVAL for DURATION. WebContent pids are re-diffed each
    # tick — WebKit may spawn them late or replace them mid-run.
    local ticks; ticks="$(awk -v d="$DURATION" -v i="$INTERVAL" 'BEGIN{printf "%d", d/i}')"
    local wc_pids="" t p line
    for ((t = 0; t < ticks; t++)); do
        line="$(ps -o rss=,pcpu= -p "$app_pid" 2>/dev/null)"
        [[ -n "$line" ]] && echo "app $line" >> "$psfile"

        # Sum RSS/CPU across all of this app's WebContent processes per tick,
        # so the "webcontent" role reflects total WebKit cost at that moment.
        wc_pids=""
        for p in $(webcontent_pids); do
            not_in "$baseline_wc" "$p" && wc_pids="$wc_pids $p"
        done
        wc_pids="${wc_pids# }"
        if [[ -n "$wc_pids" ]]; then
            # shellcheck disable=SC2086
            ps -o rss=,pcpu= -p ${wc_pids// / -p } 2>/dev/null \
                | awk '{ rss += $1; cpu += $2 } END { if (NR) print "webcontent", rss, cpu }' \
                >> "$psfile"
        fi
        sleep "$INTERVAL"
    done

    # One footprint snapshot at the end (best effort — usually needs sudo).
    if command -v footprint >/dev/null 2>&1; then
        footprint "$app_pid" > "$OUT_DIR/$name.footprint.txt" 2>/dev/null \
            || echo "    footprint unavailable (needs sudo?) — ps RSS only"
    fi

    quit_app
    sleep 1            # let trailing log lines flush
    kill "$log_pid" 2>/dev/null
    wait "$log_pid" 2>/dev/null

    emit_metrics "$name" "$logfile" "$psfile"
}

for sample in "${SAMPLES[@]}"; do
    run_sample "$sample"
done

echo "==> Done. CSV: $CSV"
column -s, -t < "$CSV"
