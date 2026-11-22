#!/bin/sh
# Builds libmdcore.a, the Markdown core: the Odin source in src/ and the
# parser in pkg/md4c.
#
#   markdown-core/build.sh <output directory>
#
# The "Build Markdown Core" phase of the app target runs this before the
# link, with Xcode's ARCHS and MACOSX_DEPLOYMENT_TARGET in the environment.
# It needs the Odin compiler (`brew install odin`) and Xcode's C and Metal
# compilers.
set -eu

OUT="${1:?usage: build.sh <output directory>}"
SRC="$(cd "$(dirname "$0")" && pwd)"
LIB="$OUT/libmdcore.a"
ARCHS="${ARCHS:-$(uname -m)}"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
STAMP="$OUT/libmdcore.stamp"
# The file list is part of the stamp, so a deleted source file also rebuilds.
STATE="$ARCHS $MIN_OS $(cd "$SRC" && find src pkg -type f | sort | tr '\n' ' ')"

# Skip the build when nothing changed: same sources, same architectures.
if [ -f "$LIB" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$STATE" ] &&
   [ -z "$(find "$SRC/src" "$SRC/pkg" "$SRC/include" "$SRC/build.sh" -newer "$LIB" -print -quit)" ]; then
    exit 0
fi

# Xcode runs build phases without Homebrew on the PATH.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v odin >/dev/null; then
    echo "error: the Odin compiler is required to build the Markdown core. Install it with: brew install odin" >&2
    exit 1
fi

# The Metal backend embeds the compiled shaders, so they are built into a
# copy of the source folder and the repository stays free of build output.
WORK="$OUT/mdcore-build"
rm -rf "$WORK"
mkdir -p "$WORK"
cp -R "$SRC/src" "$WORK/src"
xcrun -sdk macosx metal -O2 -mmacosx-version-min="$MIN_OS" \
    "$SRC/src/renderer/shaders/quad.metal" -o "$WORK/src/renderer/quad.metallib"

set --
for arch in $ARCHS; do
    case "$arch" in
        arm64) target=darwin_arm64 ;;
        x86_64) target=darwin_amd64 ;;
        *) echo "error: the Markdown core has no build for $arch" >&2; exit 1 ;;
    esac
    odin build "$WORK/src" -build-mode:static -no-entry-point -o:speed \
        -target:"$target" -minimum-os-version:"$MIN_OS" -out:"$WORK/odin-$arch.a"
    # The parser, with its two public names changed so that a host app with
    # its own copy has no symbol conflict.
    for file in md4c entity; do
        xcrun -sdk macosx clang -c -O2 -arch "$arch" -mmacosx-version-min="$MIN_OS" \
            -Dmd_parse=mdcore_md_parse -Dentity_lookup=mdcore_entity_lookup \
            "$SRC/pkg/md4c/$file.c" -o "$WORK/$file-$arch.o"
    done
    libtool -static -no_warning_for_no_symbols -o "$WORK/libmdcore-$arch.a" \
        "$WORK/odin-$arch.a" "$WORK/md4c-$arch.o" "$WORK/entity-$arch.o"
    set -- "$@" "$WORK/libmdcore-$arch.a"
done
lipo -create "$@" -output "$LIB"
echo "$STATE" > "$STAMP"
