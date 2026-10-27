# Pele

Version: **1.12.0** (also recorded in `Pele-VERSION`).

`pele.global.js` and `Pele-LICENSE.txt` are copied without modification from the
official [`pele@1.12.0` npm package](https://registry.npmjs.org/pele/-/pele-1.12.0.tgz)
(`dist/pele.global.js` and `LICENSE`). The package SHA-512 integrity is:

```
sha512-3OdOK6rvkaTB569R4/I8U0H82MqPRxj7vfkbowa2rRhgSBPFhvWlfFy5eae0jP+2A6hE8abE17nsdyxJz2VBiQ==
```

Pele renders Mermaid syntax to SVG synchronously, with no dependencies
([pele.run](https://pele.run), [source](https://github.com/obsidianmd/pele)).
The app, the editor and Quick Look use this same offline renderer for
`mermaid` code fences. Its SVG takes colours from `--pele-*` CSS variables,
which `MarkdownHTML+Stylesheet.swift` maps to the theme tokens.
