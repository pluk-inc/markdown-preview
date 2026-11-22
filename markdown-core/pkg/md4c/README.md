# md4c

The Markdown parser of the core: https://github.com/mity/md4c, commit
`f9e5eb232b95b737373ae706648cb75bd259ed1a` (0.6.0 development), MIT license
(`LICENSE.md`).

Only the files the core needs are here, unchanged: `md4c.c`, `md4c.h`, and
the entity table `entity.c`, `entity.h`. `build.sh` compiles them into
`libmdcore.a` with the two public names changed (`mdcore_md_parse`,
`mdcore_entity_lookup`), so a host app that links another copy has no
symbol conflict.

To update: copy the same four files from a newer commit and change the
commit above.
