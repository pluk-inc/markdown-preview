# Swift and WebKit tests

Run all tests on macOS:

```sh
swift test --package-path tests/swift-tests
```

## Performance regression gate

Release performance comparisons run separately from correctness tests so neither
suite distorts the other's timings. See [performance coverage, thresholds, and
local commands](../performance/README.md).

## Editor/read-mode layout parity

```sh
swift test --package-path tests/swift-tests --filter EditorPreviewLayoutTests
```

These tests load the production `MarkdownHTML` and `EditorHTML` pages into two
real `WKWebView` instances. The editor, DOMPurify, syntax highlighting, Mermaid,
and KaTeX use the actual vendored resources. Images use local data URLs. There
is no network dependency, renderer stub, or duplicate test stylesheet.

**21 test cases run in four configurations: 84 paired WebKit runs.** The matrix
uses 500, 900, and 1280-point viewports, including a 1280-point full-width column,
and both editor scrolling configurations.

### Complete documents and focused regressions

The offline files in `tests/fixtures/layout/` are deliberately mixed documents.
The harness replaces `{{IMAGE}}` with an embedded SVG fixture:

| Fixture | Coverage |
| --- | --- |
| `mixed-common.md` | All six ATX heading levels, both Setext levels, paragraphs, combined bold/italic/strike/highlight/code/links, nested lists and quotes, fenced/unlabelled/indented code, aligned and wrapping tables, direct and linked images, real Mermaid, Unicode/RTL, escapes, hard/soft breaks, and authored blank lines. |
| `mixed-source-features.md` | YAML frontmatter, task lists, inline/display/fenced math, all five GitHub alerts, reference links/images, autolinks, repeated footnotes, raw HTML/details, explicit HTML image alignment/size, and formatted table cells. |
| `mixed-everything.md` | Both sets of features in one complete document, so renderer interactions and surrounding shared content are exercised together. |

Focused cases additionally cover loose list paragraphs, oversized/repeated images,
quotes at the document start, TOML frontmatter, source replacement, and resizing.
The common mixed document probes text throughout the file, not just its first
screen or a few images. Tall WebKit views keep the entire fixture materialized
instead of skipping content outside CodeMirror's virtualized viewport.

### What equality means

**18 cases (72 runs)** compare cumulative geometry: column origins/widths, visible
text lines, image rectangles, table rows, horizontal rules, and Mermaid figures
and SVGs, within **1 CSS pixel**. They compare X/Y, width/height, wrapped line
counts, and selected computed emphasis styles. Text probes cross DOM nodes, so
formatting and highlighting spans do not hide wrapping differences. Invisible
trailing spaces and zero-width caret rectangles are excluded.

Fenced code retains the editor's language-editing row. The tests account for
exactly its declared **20 CSS pixels per header** when comparing downstream Y
positions; they never subtract a measured discrepancy or relax other geometry.

**Three cases (12 runs)** also include features that intentionally remain source
in the editor: metadata, tasks, math, alerts, reference syntax, footnotes, HTML,
and formatting inside table cells. They assert actual reader feature counts,
visible editor source, unchanged Markdown, column alignment, and local alignment
and wrapping of shared text around those features. They do **not** claim equal
block heights for a rendered equation versus its editable source. Editor-only source cues (such as Setext underline markers) are not a claim of
pixel-identical screenshots. Every fixture also verifies that rendering preserves
the exact original Markdown.

### Readiness and diagnostics

Navigation completion is insufficient. The harness waits for completed editor
syntax parsing, the renderer,
`document.fonts.ready`, decoded images, expected rendered feature counts (including
async Mermaid/KaTeX output), and stable geometry across several samples.
CodeMirror schedules measurement in animation callbacks. WebKit can suspend those
callbacks in a command-line test's hidden view, so a test-only document-start script
queues them and the harness explicitly advances frames. **Only the frame clock is
controlled**: production callbacks and WebKit's actual layout engine still perform
the work. This tests settled geometry, not native animation timing or frame rate.

Failures save both pages' original HTML, rendered DOM, geometry JSON, and PNG
snapshots under `$TMPDIR/md-preview-layout-failures`. Set `MDP_LAYOUT_ARTIFACTS` to
choose another directory. CI uploads these files when the test job fails. Geometry
is the pass/fail signal; screenshots help diagnose failures without maintaining
fragile pixel baselines across macOS font-rendering changes.

### Scope and remaining gaps

The default suite covers the system font/default reader layout at 100% zoom and
unfocused live-preview blocks. The corpus covers supported syntax categories,
not every possible nesting/permutation. It does not establish parity for custom
font/reader-spacing preferences, caret-active syntax, long-document scrolling or
virtualization, native toolbar/sidebar offsets, or Quick Look.

Run the same geometry checks at another zoom with `MDP_LAYOUT_ZOOM=1.25` in the
environment. A follow-up check at 125% confirms wrapped paragraphs now match,
but ordered-list text is still about 3.4 CSS pixels farther right in the editor
at each viewport. Non-default zoom remains outside the passing default matrix.

### Regression proof

During development, removing the image parser's `depth--` balance (the historical
post-image spacing bug) made the paired image test fail on paragraph/image Y
positions. Restoring the fix made it pass again. The suite also exposed missing
quote-edge padding, which is now applied once per quote boundary in the editor.
Expanding to complete documents exposed and fixed trailing-space wrapping,
nested quote and loose-list gaps, code-card border offsets, horizontal-rule
height/position, narrow table sizing, Mermaid aspect/scale, and visible escape
markers. The comprehensive fixture also caught images staying as source after
background parsing completed; live-preview decorations now refresh when the
syntax tree changes. The focused cases retain each regression alongside the complete files.

### Research references

- [Apple: asynchronous JavaScript in WKWebView](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:))
- [Apple: inactive scheduling policy](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)
- [Apple: WKWebView snapshots](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:))
- [CodeMirror: DOM updates and layout measurement](https://codemirror.net/docs/guide/)
- [MDN: viewport-relative element geometry](https://developer.mozilla.org/en-US/docs/Web/API/Element/getBoundingClientRect)
- [MDN: font readiness](https://developer.mozilla.org/en-US/docs/Web/API/FontFaceSet/ready)
- [MDN: image decoding](https://developer.mozilla.org/en-US/docs/Web/API/HTMLImageElement/decode)
