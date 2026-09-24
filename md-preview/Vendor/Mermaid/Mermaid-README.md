# Mermaid

Version: **11.15.0** (also recorded in `Mermaid-VERSION`).

`mermaid.min.js` and `LICENSE` are copied without modification from the official
[`mermaid@11.15.0` npm package](https://registry.npmjs.org/mermaid/-/mermaid-11.15.0.tgz)
(`dist/mermaid.min.js` and `LICENSE`). The package SHA-512 integrity is:

```
sha512-pTMbcf3rWdtLiYGpmoTjHEpeY8seiy6sR+9nD7LOs8KfUbHE4lOUAprTRqRAcWSQ6MQpdX+YEsxShtGsINtPtw==
```

The app and Quick Look use this same offline renderer. Version 11.15.0 includes
[upstream's block-arrow fix](https://github.com/mermaid-js/mermaid/pull/7633),
which preserves dotted strokes and arrowheads in `block-beta` diagrams.
The reproduction is `samples/mermaid-block-arrows.md`, covered by
`MermaidBlockArrowTests` using the production HTML in WebKit.
