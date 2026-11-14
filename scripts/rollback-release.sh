#!/usr/bin/env bash
#
# Roll back a Markdown Preview release.
#
# Default action: unpublish the release on Amore (reversible) and delete the
# matching GitHub release + tag. Use --delete to permanently remove from Amore.
#
# Usage:
#   scripts/rollback-release.sh <version>            Roll back a specific version
#   scripts/rollback-release.sh --latest             Roll back the most recent release
#   scripts/rollback-release.sh 0.0.2 --delete       Permanently delete on Amore
#   scripts/rollback-release.sh 0.0.2 --keep-github  Leave GitHub release in place
#   scripts/rollback-release.sh --latest --yes       Skip confirmation prompt
#
# To re-publish after a non-destructive rollback:
#   amore releases update <version> -b sh.pluk.md-preview --published true

set -euo pipefail

BUNDLE_ID="sh.pluk.md-preview"

VERSION=""
USE_LATEST=false
DELETE=false
KEEP_GH=false
YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)      USE_LATEST=true;  shift;;
        --delete)      DELETE=true;      shift;;
        --keep-github) KEEP_GH=true;     shift;;
        --yes|-y)      YES=true;         shift;;
        -h|--help)     sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //;s/^#//'; exit 0;;
        -*)            echo "unknown flag: $1" >&2; exit 2;;
        *)             VERSION="$1";     shift;;
    esac
done

amore_bin() {
    if command -v amore >/dev/null 2>&1; then command -v amore
    elif [[ -x /usr/local/bin/amore ]]; then echo /usr/local/bin/amore
    else echo "error: amore CLI not found" >&2; return 1
    fi
}

AMORE="$(amore_bin)"

if ! "$AMORE" whoami >/dev/null 2>&1; then
    echo "✗ amore not logged in — run: amore login" >&2
    exit 1
fi

# ── Resolve target version ─────────────────────────────────────────────────
LIST="$("$AMORE" releases list --bundle-id "$BUNDLE_ID" 2>&1)"

# Parse the table — strip borders, drop header, take rows that contain a UUID
ROWS="$(echo "$LIST" | grep -E '[0-9A-F]{8}-[0-9A-F]{4}-' | sed 's/[│├┤]//g')"

if [[ -z "$ROWS" ]]; then
    echo "✗ no releases found for $BUNDLE_ID" >&2
    exit 1
fi

if $USE_LATEST; then
    # First row is most recent
    ROW="$(echo "$ROWS" | head -1)"
    VERSION="$(echo "$ROW" | awk '{print $2}')"
fi

if [[ -z "$VERSION" ]]; then
    echo "error: pass a version (e.g. 0.0.2) or --latest" >&2
    exit 2
fi

# Find the row matching $VERSION
ROW="$(echo "$ROWS" | awk -v v="$VERSION" '$2 == v {print; exit}')"
if [[ -z "$ROW" ]]; then
    echo "✗ no release found for version $VERSION" >&2
    echo "$LIST"
    exit 1
fi

BUILD="$(echo "$ROW" | awk '{print $3}')"
STATUS="$(echo "$ROW" | awk '{print $4}')"
TAG="v$VERSION"

# ── Confirm ────────────────────────────────────────────────────────────────
echo "▸ Target: $VERSION (build $BUILD), currently $STATUS"
if $DELETE; then
    echo "  Action: permanently DELETE from Amore"
else
    echo "  Action: UNPUBLISH from Amore (reversible)"
fi
if ! $KEEP_GH; then
    echo "  Action: delete GitHub release + tag $TAG"
fi
echo ""

if ! $YES; then
    read -rp "Continue? [y/N] " ans
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) echo "aborted"; exit 1;; esac
fi

# ── Roll back on Amore ─────────────────────────────────────────────────────
if $DELETE; then
    echo "▸ Deleting release $VERSION on Amore"
    "$AMORE" releases delete "$VERSION" --bundle-id "$BUNDLE_ID" --yes
else
    echo "▸ Unpublishing release $VERSION on Amore"
    "$AMORE" releases update "$VERSION" --bundle-id "$BUNDLE_ID" --published false
fi

# ── Roll back on GitHub ────────────────────────────────────────────────────
if ! $KEEP_GH; then
    if command -v gh >/dev/null && git remote get-url origin >/dev/null 2>&1; then
        if gh release view "$TAG" >/dev/null 2>&1; then
            echo "▸ Deleting GitHub release $TAG"
            gh release delete "$TAG" --yes --cleanup-tag 2>/dev/null \
                || gh release delete "$TAG" --yes
        else
            echo "  ⚠ no GitHub release for $TAG"
        fi
        # Best-effort tag cleanup if --cleanup-tag was unsupported
        if git rev-parse "$TAG" >/dev/null 2>&1; then
            git tag -d "$TAG" >/dev/null
            git push origin ":refs/tags/$TAG" >/dev/null 2>&1 || true
            echo "▸ Removed local + remote tag $TAG"
        fi
    else
        echo "  ⚠ skipping GitHub cleanup (no gh / no origin remote)"
    fi
fi

echo "✓ Rolled back $VERSION (build $BUILD)"
if ! $DELETE; then
    echo "  To re-publish: amore releases update $VERSION -b $BUNDLE_ID --published true"
fi
