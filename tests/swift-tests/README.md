# Swift and WebKit tests

Run all tests on macOS:

```sh
swift test --package-path tests/swift-tests
```

## Editor/read-mode layout parity

```sh
swift test --package-path tests/swift-tests --filter EditorPreviewLayoutTests
```

These tests load the production `MarkdownHTML` and `EditorHTML` pages into two
real `WKWebView` instances. The editor uses the checked-in CodeMirror bundle;
images are local data URLs and DOMPurify is loaded from the vendored script.
There is no network dependency or duplicate test stylesheet.

Nine fixtures run at 500, 900, and 1280 points, including a 1280-point full-width
column. Both editor scrolling configurations are covered. The fixtures check:

- Paragraphs, ATX/Setext headings, and wrapped text.
- Plain, linked, repeated, and oversized images, plus paragraphs before and after
  them. Cumulative vertical positions catch gaps that grow after each image.
- Bullet/ordered list text, quote boundaries, hard line breaks, and quotes at the
  start of the document.
- Replacing editor content and resizing an existing view.

The assertions compare column origins/widths, visible text lines, and image
rectangles within **1 CSS pixel**. They compare both horizontal and vertical
positions, widths, heights, and wrapped line counts. Text probes ignore invisible
trailing spaces and zero-width caret rectangles at wrapped boundaries.

### Readiness and diagnostics

Navigation completion is insufficient. The harness waits for the renderer,
`document.fonts.ready`, decoded images, and stable geometry across several samples.
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
unfocused live-preview blocks. It does not establish parity for every Markdown
construct, custom font/reader-spacing preference, caret-active source syntax,
native toolbar/sidebar offsets, or Quick Look. Add a fixture at the real boundary
when extending coverage.

Exploratory checks at 125% page zoom found remaining differences at a 900-point
viewport: wrapped paragraphs can break at a different word, and ordered-list text
can differ horizontally by about 3.4 CSS pixels. These are not covered by the
passing default matrix. Run the same geometry checks at another zoom with
`MDP_LAYOUT_ZOOM=1.25` in the environment to investigate them. CodeMirror's
`break-spaces` wrapping differs from read mode's normal whitespace handling;
the ordered-list offset still needs a separate diagnosis.

### Regression proof

During development, removing the image parser's `depth--` balance (the historical
post-image spacing bug) made the paired image test fail on paragraph/image Y
positions. Restoring the fix made it pass again. The suite also exposed missing
quote-edge padding, which is now applied once per quote boundary in the editor.

### Research references

- [Apple: asynchronous JavaScript in WKWebView](https://developer.apple.com/documentation/webkit/wkwebview/callasyncjavascript(_:arguments:in:contentworld:))
- [Apple: inactive scheduling policy](https://developer.apple.com/documentation/webkit/wkpreferences/inactiveschedulingpolicy-swift.property)
- [Apple: WKWebView snapshots](https://developer.apple.com/documentation/webkit/wkwebview/takesnapshot(with:completionhandler:))
- [CodeMirror: DOM updates and layout measurement](https://codemirror.net/docs/guide/)
- [MDN: viewport-relative element geometry](https://developer.mozilla.org/en-US/docs/Web/API/Element/getBoundingClientRect)
- [MDN: font readiness](https://developer.mozilla.org/en-US/docs/Web/API/FontFaceSet/ready)
- [MDN: image decoding](https://developer.mozilla.org/en-US/docs/Web/API/HTMLImageElement/decode)
