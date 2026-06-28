#!/usr/bin/env bash
#
# Release Markdown Preview via Amore + create a GitHub release.
#
# Usage:
#   scripts/release.sh                    Use version + build from Version.xcconfig
#   scripts/release.sh --version 0.0.2    Set marketing version (and bump build)
#   scripts/release.sh --version 0.0.2 --build 7
#   scripts/release.sh --beta             Pass --beta to amore + GH prerelease
#   scripts/release.sh --draft            amore --draft, no GH release
#   scripts/release.sh --skip-github      Run amore release only
#
# Source of truth:
#   - Version.xcconfig  → MARKETING_VERSION, CURRENT_PROJECT_VERSION
#   - CHANGELOG.md      → release notes (## [X.Y.Z] – YYYY-MM-DD)
#
# After amore publishes, this also bumps the Homebrew tap at
# pluk-inc/homebrew-tap (Casks/markdown-preview.rb) so `brew upgrade
# --cask` users converge on the new version. Skipped on --beta / --draft.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_CONFIG="$PROJECT_ROOT/Version.xcconfig"
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"
SCHEME="md-preview"

VERSION_OVERRIDE=""
BUILD_OVERRIDE=""
DRAFT_FLAG=""
BETA_FLAG=""
SKIP_GH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION_OVERRIDE="$2"; shift 2;;
        --build)   BUILD_OVERRIDE="$2";   shift 2;;
        --draft)   DRAFT_FLAG="--draft";  SKIP_GH=true; shift;;
        --beta)    BETA_FLAG="--beta";    shift;;
        --skip-github) SKIP_GH=true;      shift;;
        -h|--help) sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //;s/^#//'; exit 0;;
        *) echo "Unknown option: $1" >&2; exit 2;;
    esac
done

amore_bin() {
    if command -v amore >/dev/null 2>&1; then command -v amore
    elif [[ -x /usr/local/bin/amore ]]; then echo /usr/local/bin/amore
    else echo "error: amore CLI not found" >&2; return 1
    fi
}

read_xcconfig() {
    grep "^$1" "$VERSION_CONFIG" | sed -E 's/^[A-Z_]+ *= *//'
}

write_xcconfig() {
    /usr/bin/sed -i '' -E "s|^$1 *=.*|$1 = $2|" "$VERSION_CONFIG"
}

extract_notes() {
    awk -v ver="$1" '
        $0 ~ "^## \\[" ver "\\]" { flag=1; next }
        flag && /^## \[/         { exit }
        flag                     { print }
    ' "$CHANGELOG" | awk 'NF{found=1} found' | sed -E '$ { /^[[:space:]]*$/d; }'
}

# ── Resolve version ────────────────────────────────────────────────────────
if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION="$VERSION_OVERRIDE"
else
    VERSION="$(read_xcconfig MARKETING_VERSION)"
fi

if [[ -n "$BUILD_OVERRIDE" ]]; then
    BUILD="$BUILD_OVERRIDE"
else
    CURRENT_BUILD="$(read_xcconfig CURRENT_PROJECT_VERSION)"
    if [[ -n "$VERSION_OVERRIDE" && "$VERSION_OVERRIDE" != "$(read_xcconfig MARKETING_VERSION)" ]]; then
        BUILD=$((CURRENT_BUILD + 1))
    else
        BUILD="$CURRENT_BUILD"
    fi
fi

[[ -z "$VERSION" ]] && { echo "error: could not resolve version" >&2; exit 1; }
[[ -z "$BUILD"   ]] && { echo "error: could not resolve build number" >&2; exit 1; }

echo "▸ Releasing $VERSION (build $BUILD)"

# ── Preflight ──────────────────────────────────────────────────────────────
echo "▸ Preflight checks"

git update-index --refresh >/dev/null 2>&1 || true
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo "  ✗ working tree is dirty — commit or stash first"
    git status --short
    exit 1
fi
echo "  ✓ working tree clean"

if ! grep -q "^## \[$VERSION\]" "$CHANGELOG"; then
    echo "  ✗ no CHANGELOG.md entry for [$VERSION]"
    echo "    add a section like:  ## [$VERSION] – $(date +%Y-%m-%d)"
    exit 1
fi
echo "  ✓ CHANGELOG.md entry found for $VERSION"

AMORE="$(amore_bin)"
if ! "$AMORE" whoami >/dev/null 2>&1; then
    echo "  ✗ amore not logged in — run: amore login"
    exit 1
fi
echo "  ✓ amore logged in"

if ! $SKIP_GH; then
    if ! command -v gh >/dev/null; then
        echo "  ✗ gh CLI not installed — brew install gh, or pass --skip-github"
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "  ✗ gh not authenticated — run: gh auth login"
        exit 1
    fi
    if ! git remote get-url origin >/dev/null 2>&1; then
        echo "  ⚠ no git remote 'origin' — GitHub release will be skipped"
        SKIP_GH=true
    else
        echo "  ✓ gh ready"
    fi
fi

# ── Sync Version.xcconfig ──────────────────────────────────────────────────
CURRENT_VERSION="$(read_xcconfig MARKETING_VERSION)"
CURRENT_BUILD="$(read_xcconfig CURRENT_PROJECT_VERSION)"

if [[ "$CURRENT_VERSION" != "$VERSION" || "$CURRENT_BUILD" != "$BUILD" ]]; then
    echo "▸ Updating Version.xcconfig: $CURRENT_VERSION ($CURRENT_BUILD) → $VERSION ($BUILD)"
    write_xcconfig MARKETING_VERSION "$VERSION"
    write_xcconfig CURRENT_PROJECT_VERSION "$BUILD"
    git add "$VERSION_CONFIG"
    git commit -m "Release $VERSION ($BUILD)" >/dev/null
    echo "  ✓ committed Version.xcconfig"
fi

# ── Extract release notes ──────────────────────────────────────────────────
NOTES="$(extract_notes "$VERSION")"
if [[ -z "$NOTES" ]]; then
    echo "error: empty CHANGELOG.md body for [$VERSION]" >&2
    exit 1
fi

# ── amore release ──────────────────────────────────────────────────────────
echo "▸ amore release"
if ! command -v jq >/dev/null; then
    echo "  ✗ jq not installed — brew install jq" >&2
    exit 1
fi
LOG="$(mktemp)"
"$AMORE" release --scheme "$SCHEME" --release-notes "$NOTES" $BETA_FLAG $DRAFT_FLAG \
    --format json \
    | tee "$LOG"

# amore --format json prints text progress, then a single JSON object at the end
DMG_URL="$(sed -n '/^{/,$p' "$LOG" | jq -er '.release.downloadURL' 2>/dev/null || true)"
if [[ -z "$DMG_URL" ]]; then
    echo "✗ no .release.downloadURL in amore JSON output (see $LOG)" >&2
    exit 1
fi
echo "▸ DMG: $DMG_URL"

# ── Download DMG (used by cask bump + GH release) ──────────────────────────
SHOULD_BUMP_CASK=true
[[ -n "$BETA_FLAG$DRAFT_FLAG" ]] && SHOULD_BUMP_CASK=false

DMG_PATH=""
if $SHOULD_BUMP_CASK || ! $SKIP_GH; then
    DMG_PATH="$(mktemp -d)/Markdown-Preview.dmg"
    echo "▸ Downloading DMG"
    curl -fsSL -o "$DMG_PATH" "$DMG_URL"
fi

# ── Bump pluk-inc/homebrew-tap ─────────────────────────────────────────────
if $SHOULD_BUMP_CASK; then
    echo "▸ Bumping pluk-inc/homebrew-tap"
    DMG_SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    TAP_DIR="$(mktemp -d)/homebrew-tap"
    if git clone --depth=1 --quiet git@github.com:pluk-inc/homebrew-tap.git "$TAP_DIR"; then
        CASK_FILE="$TAP_DIR/Casks/markdown-preview.rb"
        /usr/bin/sed -i '' -E "s|^  version \".*\"|  version \"$VERSION,$BUILD\"|" "$CASK_FILE" \
            || { echo "  ✗ cask version sed failed"; exit 1; }
        /usr/bin/sed -i '' -E "s|^  sha256 \".*\"|  sha256 \"$DMG_SHA\"|" "$CASK_FILE" \
            || { echo "  ✗ cask sha256 sed failed"; exit 1; }
        if ! grep -q "version \"$VERSION,$BUILD\"" "$CASK_FILE" || \
           ! grep -q "sha256 \"$DMG_SHA\""        "$CASK_FILE"; then
            echo "  ✗ cask sed didn't take — fix Casks/markdown-preview.rb manually"
            exit 1
        elif (cd "$TAP_DIR" && git diff --quiet); then
            echo "  ⚠ cask already at $VERSION,$BUILD — nothing to push"
        else
            (cd "$TAP_DIR" && \
                git -c user.name="$(git config user.name)" \
                    -c user.email="$(git config user.email)" \
                    commit -am "markdown-preview $VERSION,$BUILD" >/dev/null && \
                git push --quiet origin HEAD) \
                && echo "  ✓ pushed cask bump" \
                || echo "  ✗ push failed — fix manually in pluk-inc/homebrew-tap"
        fi
    else
        echo "  ⚠ failed to clone homebrew-tap — skipping cask bump"
    fi
    rm -rf "$(dirname "$TAP_DIR")"
fi

if $SKIP_GH; then
    echo "✓ Released $VERSION ($BUILD). GitHub step skipped."
    exit 0
fi

# ── GitHub release ─────────────────────────────────────────────────────────
TAG="v$VERSION"
echo "▸ Creating tag $TAG"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  ⚠ tag $TAG already exists locally — reusing"
else
    git tag -a "$TAG" -m "Release $VERSION ($BUILD)"
fi
git push origin "$TAG" 2>/dev/null || git push origin "$TAG"

PRERELEASE_FLAG=""
[[ -n "$BETA_FLAG" ]] && PRERELEASE_FLAG="--prerelease"

if gh release view "$TAG" >/dev/null 2>&1; then
    echo "  ⚠ GitHub release $TAG exists — uploading DMG as new asset"
    gh release upload "$TAG" "$DMG_PATH" --clobber
else
    echo "▸ Creating GitHub release $TAG"
    gh release create "$TAG" \
        --title "Markdown Preview $VERSION" \
        --notes "$NOTES" \
        $PRERELEASE_FLAG \
        "$DMG_PATH"
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo "✓ Released $VERSION ($BUILD)"
echo "  GitHub:  https://github.com/$REPO/releases/tag/$TAG"
echo "  Amore:   $DMG_URL"
