# md4c

The Markdown parser of the core: https://github.com/mity/md4c, commit
`f9e5eb232b95b737373ae706648cb75bd259ed1a` (0.6.0 development), MIT license
(`LICENSE.md`).

Only the files the core needs are here: `md4c.c`, `md4c.h`, and the
entity table `entity.c`, `entity.h`. They are the files of that commit
with one change, `source-offsets.patch`: the parser says where things
are in the source, through five new optional callbacks at the end of
`MD_PARSER`. `block_offset` gives the start of each block and where its
lines end (the closing fence of code and the line under a heading are
lines of the block; the blank lines after it are not), `ref_def` the
range of each definition of a link, `ref_def_use` each use of a
definition with what it counts for in the parser's limit for such uses,
`mark_offset` the range of each mark of the inline syntax (the two
marks of bold text, of code, of a link) with the range of its element,
and `line_offset` each line of the text of a heading and of a
paragraph with the start of its line of the source (what is between the two is the marks of the
line).
The parser knows these, but upstream gives them to no callback, and the
core needs them: a block must know its range of the source and its lines, and a parse
of a piece of the source must have the definitions of the rest of it
and must know that the limit, which is of the size of the text that is
parsed, cuts no use in the piece that a parse of all would keep; and an
edit that takes text out must know the two marks of each style, to keep
the one whose text stays, and an editor shows the marks of the element
that its caret is in. There is no other change, and
there must be none without the same reason: something that only the
parser knows. `build.sh` compiles them into
`libmdcore.a` with the two public names changed (`mdcore_md_parse`,
`mdcore_entity_lookup`), so a host app that links another copy has no
symbol conflict.

To update: copy the same four files from a newer commit, apply the patch
(`patch -p1 < source-offsets.patch` in this folder), make the patch file
again from the two new pairs of files, and change the commit above. The
tests of the core check each block's place and each definition
(`markdown-core/test.sh`).
