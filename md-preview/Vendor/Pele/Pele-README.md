# Pele

Version: **1.13.0** (also recorded in `Pele-VERSION`).

`pele.global.js` and `Pele-LICENSE.txt` are copied without modification from the
official [`pele@1.13.0` npm package](https://registry.npmjs.org/pele/-/pele-1.13.0.tgz)
(`dist/pele.global.js` and `LICENSE`). The package SHA-512 integrity is:

```
sha512-Ie8UKY9x00MsuR3jO6AzUwzK2Z6MIV3Tf4EDdITiuk8Uaz8K7g0R082WqsqNaSU8DdgkrRvZThzhit83mi/uiw==
```

Pele renders Mermaid syntax to SVG synchronously, with no dependencies
([pele.run](https://pele.run), [source](https://github.com/obsidianmd/pele)).
The app, the editor and Quick Look use this same offline renderer for
`mermaid` code fences. Its SVG takes colours from `--pele-*` CSS variables,
which `MarkdownHTML+Stylesheet.swift` maps to the theme tokens.
