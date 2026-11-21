#!/bin/sh
# Builds libmdcore.a, the Markdown core, from the Odin source in src/.
#
#   markdown-core/build.sh <output directory>
#
# The "Build Markdown Core" phase of the app target runs this before the
# link, with Xcode's ARCHS and MACOSX_DEPLOYMENT_TARGET in the environment.
# It needs the Odin compiler (`brew install odin`) and Xcode's Metal compiler.
set -eu

OUT="${1:?usage: build.sh <output directory>}"
SRC="$(cd "$(dirname "$0")" && pwd)"
LIB="$OUT/libmdcore.a"
ARCHS="${ARCHS:-$(uname -m)}"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
STAMP="$OUT/libmdcore.stamp"
# The file list is part of the stamp, so a deleted source file also rebuilds.
STATE="$ARCHS $MIN_OS $(cd "$SRC/src" && ls | tr '\n' ' ')"

# Skip the build when nothing changed: same sources, same architectures.
if [ -f "$LIB" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$STATE" ] &&
   [ -z "$(find "$SRC/src" "$SRC/include" "$SRC/build.sh" -newer "$LIB" -print -quit)" ]; then
    exit 0
fi

# Xcode runs build phases without Homebrew on the PATH.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v odin >/dev/null; then
    echo "error: the Odin compiler is required to build the Markdown core. Install it with: brew install odin" >&2
    exit 1
fi

# The Odin code embeds the compiled shaders, so they are built into a copy of
# the source folder and the repository stays free of build output.
WORK="$OUT/mdcore-build"
rm -rf "$WORK"
mkdir -p "$WORK/src"
cp "$SRC"/src/*.odin "$WORK/src/"
xcrun -sdk macosx metal -O2 -mmacosx-version-min="$MIN_OS" \
    "$SRC/src/shaders.metal" -o "$WORK/src/shaders.metallib"

set --
for arch in $ARCHS; do
    case "$arch" in
        arm64) target=darwin_arm64 ;;
        x86_64) target=darwin_amd64 ;;
        *) echo "error: the Markdown core has no build for $arch" >&2; exit 1 ;;
    esac
    odin build "$WORK/src" -build-mode:static -no-entry-point -o:speed \
        -target:"$target" -minimum-os-version:"$MIN_OS" -out:"$WORK/libmdcore-$arch.a"
    set -- "$@" "$WORK/libmdcore-$arch.a"
done
lipo -create "$@" -output "$LIB"
echo "$STATE" > "$STAMP"
