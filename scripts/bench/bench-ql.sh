#!/bin/bash
#
# bench-ql.sh — CPU/memory benchmark for the Quick Look extension.
#
# Resets the Quick Look daemon + cache, opens a `qlmanage -p` preview of the
# sample, and samples RSS/CPU of qlmanage, QuickLookUIService, and the
# quick-look appex every 500 ms. If the Debug build's PreviewProvider perf
# logging is registered, provide start→finish wall-time is captured too.
#
# Usage:
#   scripts/bench/bench-ql.sh [--duration <sec>] [--out <dir>] [--label <name>] <sample.md>
#
# Prerequisite: the just-built app must be registered with LaunchServices so
# its appex serves .md previews — open the built app once, or:
#   /System/Library/Frameworks/CoreServices.framework/Frameworks/\
#     LaunchServices.framework/Support/lsregister -f <path/to/app>
# Verify with: pluginkit -m -p com.apple.quicklook.preview | grep md-preview
# ("+" marks the elected appex; `pluginkit -e use -i <appex-bundle-id>` to
# elect the Debug build. See README.md.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DURATION=15
OUT_DIR=""
LABEL="run"
SAMPLE=""
INTERVAL=0.5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="$2"; shift 2 ;;
        --out)      OUT_DIR="$2"; shift 2 ;;
        --label)    LABEL="$2"; shift 2 ;;
        -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --*)        echo "unknown option: $1" >&2; exit 2 ;;
        *)          SAMPLE="$1"; shift ;;
    esac
done

[[ -n "$SAMPLE" ]] || { echo "usage: bench-ql.sh [options] <sample.md>" >&2; exit 2; }
[[ -f "$SAMPLE" ]] || { echo "sample not found: $SAMPLE" >&2; exit 1; }

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="$REPO_ROOT/bench-results/$LABEL-ql-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUT_DIR"
NAME="$(basename "$SAMPLE" .md)"
CSV="$OUT_DIR/ql.csv"
LOGFILE="$OUT_DIR/$NAME.ql.log"
PSFILE="$OUT_DIR/$NAME.ql.ps.tsv"
echo "label,sample,metric,value" > "$CSV"
: > "$PSFILE"

echo "==> Resetting Quick Look daemon and cache"
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1
sleep 1

# Capture appex provide timings (Debug builds only) — start before qlmanage.
log stream --level debug --style compact \
    --predicate 'subsystem BEGINSWITH "doc.md-preview"' \
    > "$LOGFILE" 2>/dev/null &
LOG_PID=$!
sleep 1

echo "==> qlmanage -p $SAMPLE (${DURATION}s)"
qlmanage -p "$SAMPLE" >/dev/null 2>&1 &
QL_PID=$!

sample_role() {
    local role="$1"; shift
    local pids="$*"
    # Trim stray whitespace — a trailing space would leave a dangling `-p`
    # after the substitution below and make ps reject the whole invocation.
    pids="$(echo $pids)"
    [[ -n "$pids" ]] || return 0
    # shellcheck disable=SC2086
    ps -o rss=,pcpu= -p ${pids// / -p } 2>/dev/null \
        | awk -v r="$role" '{ rss += $1; cpu += $2 } END { if (NR) print r, rss, cpu }' \
        >> "$PSFILE"
}

TICKS="$(awk -v d="$DURATION" -v i="$INTERVAL" 'BEGIN{printf "%d", d/i}')"
for ((t = 0; t < TICKS; t++)); do
    sample_role qlmanage "$QL_PID"
    sample_role qluiservice "$(pgrep -f 'QuickLookUIService' 2>/dev/null | tr '\n' ' ')"
    sample_role appex "$(pgrep -f 'quick-look' 2>/dev/null | tr '\n' ' ')"
    sleep "$INTERVAL"
done

kill "$QL_PID" 2>/dev/null
sleep 1
kill "$LOG_PID" 2>/dev/null
wait "$QL_PID" "$LOG_PID" 2>/dev/null

# ------------------------------------------------------------------- metrics

# Provide wall-time comes straight from the finish line's +Nms suffix.
grep -oE '\[mdp-perf-ql\] provide finish \+[0-9]+ms' "$LOGFILE" \
    | grep -oE '[0-9]+' \
    | awk -v L="$LABEL" -v S="$NAME" '
        { sum += $1; n++ }
        END { if (n) printf "%s,%s,ql_provide_ms,%.0f\n", L, S, sum/n }' >> "$CSV"

awk -v L="$LABEL" -v S="$NAME" '
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
    }' "$PSFILE" >> "$CSV"

if ! grep -q 'mdp-perf-ql' "$LOGFILE"; then
    echo "note: no [mdp-perf-ql] lines captured — is the Debug appex elected?" >&2
    echo "      pluginkit -m -p com.apple.quicklook.preview | grep md-preview" >&2
    echo "      pluginkit -e use -i doc.md-preview.dev.quick-look" >&2
fi

echo "==> Done. CSV: $CSV"
column -s, -t < "$CSV"
