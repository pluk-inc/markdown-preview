# md4c

The Markdown parser of the core: https://github.com/mity/md4c, commit
`f9e5eb232b95b737373ae706648cb75bd259ed1a` (0.6.0 development), MIT license
(`LICENSE.md`).

Only the files the core needs are here: `md4c.c`, `md4c.h`, and the
entity table `entity.c`, `entity.h`. They are the files of that commit
with one change, `block-offset.patch`: the parser says where in the
source each block starts (a new optional callback, `block_offset`, at the
end of `MD_PARSER`). The parser knows the lines of each block, but
upstream gives them to no callback, and the core needs them: a block must
know its range of the source. There is no other change, and there must be
none without the same reason: something that only the parser knows. `build.sh` compiles them into
`libmdcore.a` with the two public names changed (`mdcore_md_parse`,
`mdcore_entity_lookup`), so a host app that links another copy has no
symbol conflict.

To update: copy the same four files from a newer commit, apply the patch
(`patch -p1 < block-offset.patch` in this folder), make the patch file
again from the two new pairs of files, and change the commit above. The
tests of the core check each block's place (`markdown-core/test.sh`).
