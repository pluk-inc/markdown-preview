#!/bin/sh
# Runs the unit tests of the Markdown core. They need no window and no GPU.
#
#   markdown-core/test.sh
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The parser as a library that the test programs link.
for file in md4c entity; do
    xcrun -sdk macosx clang -c -O2 \
        -Dmd_parse=mdcore_md_parse -Dentity_lookup=mdcore_entity_lookup \
        "$SRC/pkg/md4c/$file.c" -o "$WORK/$file.o"
done
libtool -static -o "$WORK/libmdcore_md4c.a" "$WORK/md4c.o" "$WORK/entity.o"

for package in document layout; do
    odin test "$SRC/src/$package" -out:"$WORK/$package-tests" \
        -extra-linker-flags:"-L$WORK"
done
