# Pele

Version: **1.6.0** (also recorded in `Pele-VERSION`).

`pele.global.js` and `Pele-LICENSE.txt` are copied without modification from the
official [`pele@1.6.0` npm package](https://registry.npmjs.org/pele/-/pele-1.6.0.tgz)
(`dist/pele.global.js` and `LICENSE`). The package SHA-512 integrity is:

```
sha512-VfAiVItsOGlGhvnBfphdT28VCG7mXMZxQNOwAGsCtxI2ztbUsT39MraEOYjsapLxVETkdUZscm0DdotYDQMLdw==
```

Pele renders Mermaid syntax to SVG synchronously, with no dependencies
([pele.run](https://pele.run), [source](https://github.com/obsidianmd/pele)).
The app, the editor and Quick Look use this same offline renderer for
`mermaid` code fences. Its SVG takes colours from `--pele-*` CSS variables,
which `MarkdownHTML+Stylesheet.swift` maps to the theme tokens.
