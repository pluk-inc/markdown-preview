# Changelog

## [0.0.27] – 2026-06-01

Markdown Preview can now export the document you are viewing straight to a clean, print-ready PDF.

### Added

- **Export as PDF.** A new File ▸ Export as PDF… command (⌥⌘P), plus a customizable toolbar button, renders the open document to a paginated PDF and saves it wherever you choose. Export runs against a fresh off-screen copy of the document, so the result is unaffected by your current zoom, scroll position, or in-document search highlights.
- **Print-ready output.** Exported PDFs always use a light theme regardless of your system appearance, automatically use US Letter or A4 based on your region, and wait for math (KaTeX), Mermaid diagrams, and syntax highlighting to finish rendering before saving so nothing is captured half-drawn. On-screen extras like code-copy buttons and diagram zoom controls are left out of the page.

### Security

- **Isolated export rendering.** The off-screen view used to generate a PDF is restricted to the document's own local assets — it cannot load remote images, scripts, or other network resources while exporting.

## [0.0.26] – 2026-05-31

Markdown Preview now works more naturally as a multi-window document app, can browse Markdown folders directly, and includes app handoff and command-line installation tools for local workflows.

### Added

- **Native document windows.** Markdown files opened from Finder, File > Open, and Open Recent now use macOS document-window behavior, so multiple Markdown files can stay open as separate windows in one Markdown Preview process ([#131](https://github.com/pluk-inc/markdown-preview/pull/131), [#130](https://github.com/pluk-inc/markdown-preview/issues/130)).
- **Folder opening for Project Navigator.** The open panel can choose a folder as a Markdown workspace, mounting it as the Project Navigator root without eagerly loading every file in the tree ([#135](https://github.com/pluk-inc/markdown-preview/pull/135)).
- **Spacebar page scrolling.** Space and Shift-Space now page down and page up in the rendered preview, matching Preview-style reading behavior while leaving focused controls alone ([#132](https://github.com/pluk-inc/markdown-preview/pull/132), [#129](https://github.com/pluk-inc/markdown-preview/issues/129)).
- **Open in LLM toolbar action.** A toolbar menu can hand the current Markdown file to supported local LLM apps, including Codex, Claude, and ChatGPT, when they are installed ([#136](https://github.com/pluk-inc/markdown-preview/pull/136), [#140](https://github.com/pluk-inc/markdown-preview/pull/140)).
- **Command-line tool installer.** The app menu now includes an Install CLI command that installs `md-preview`, `mdp`, and `markdown-preview` launchers into a usable PATH directory ([#139](https://github.com/pluk-inc/markdown-preview/pull/139)).

### Contributors

Thanks to the external reporters who helped improve this release:

- [@tututuhehehe](https://github.com/tututuhehehe) — requested multiple document window support ([#130](https://github.com/pluk-inc/markdown-preview/issues/130))
- [@Ptujec](https://github.com/Ptujec) — requested Space and Shift-Space preview scrolling ([#129](https://github.com/pluk-inc/markdown-preview/issues/129))

## [0.0.25] – 2026-05-21

Markdown Preview now handles common editor save workflows more reliably, strips TOML frontmatter before rendering, and keeps code-copy output clean when selecting the whole preview.

### Changed

- **The preview keeps following the original file after atomic saves.** When editors save by replacing the file behind the scenes, Markdown Preview now reloads the new contents while staying attached to the original path instead of following the temporary replacement file ([#126](https://github.com/pluk-inc/markdown-preview/pull/126), [#119](https://github.com/pluk-inc/markdown-preview/issues/119)).

### Fixed

- **TOML frontmatter is hidden from rendered previews.** Files that start with `+++` frontmatter now render like YAML-frontmatter files, keeping metadata out of the preview body ([#125](https://github.com/pluk-inc/markdown-preview/pull/125), [#118](https://github.com/pluk-inc/markdown-preview/issues/118)).
- **Code copy buttons no longer leak into copied text.** Selecting the whole preview and copying now excludes the inline "Copy" / "Copied" button label from code block clipboard output ([#124](https://github.com/pluk-inc/markdown-preview/pull/124), [#120](https://github.com/pluk-inc/markdown-preview/issues/120)).

### Contributors

Thanks to the external reporters who helped improve this release:

- [@gglanzani](https://github.com/gglanzani) — reported TOML frontmatter rendering and atomic-save reload issues ([#118](https://github.com/pluk-inc/markdown-preview/issues/118), [#119](https://github.com/pluk-inc/markdown-preview/issues/119))
- [@OzzyCzech](https://github.com/OzzyCzech) — reported copy button text leaking into selected code copy output ([#120](https://github.com/pluk-inc/markdown-preview/issues/120))

## [0.0.24] – 2026-05-19

GitHub-style alert blockquotes now render with their intended labels, and the Open With menu finds more Markdown editors.

### Added

- **GitHub-style alert blockquotes render with labels and colors.** Blockquotes that start with `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, or `[!CAUTION]` now render as alert callouts, including custom titles after the marker ([#113](https://github.com/pluk-inc/markdown-preview/pull/113)).

### Fixed

- **More Markdown editors appear in Open With.** Trusted Markdown-first editors such as iA Writer, Typora, MacDown, and Obsidian are now included even when Launch Services exposes them through custom Markdown UTIs, while noisy non-editors are filtered out ([#116](https://github.com/pluk-inc/markdown-preview/pull/116), [#114](https://github.com/pluk-inc/markdown-preview/issues/114)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@jphastings](https://github.com/jphastings) — GitHub-style alert blockquotes ([#113](https://github.com/pluk-inc/markdown-preview/pull/113))

## [0.0.23] – 2026-05-18

Fenced code blocks that carry extra metadata after the language now render the way they should.

### Fixed

- **Fenced code blocks with info-string metadata render correctly.** Only the first word of a fenced code block's info string is treated as the language, so blocks like ` ```mermaid {theme=dark} ` or ` ```swift title="example.swift" ` are recognized properly and Mermaid diagrams and math decorators are no longer broken by trailing metadata ([#109](https://github.com/pluk-inc/markdown-preview/pull/109)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@jphastings](https://github.com/jphastings) — fenced code block info-string language handling ([#109](https://github.com/pluk-inc/markdown-preview/pull/109))

## [0.0.22] – 2026-05-14

Markdown Preview now sanitizes rendered HTML before it reaches the preview WebView, and Sparkle update checks point at the Amore-published appcast.

### Changed

- **Amore sponsor credit added.** The README now lists Amore among the project sponsors ([#105](https://github.com/pluk-inc/markdown-preview/pull/105)).

### Fixed

- **Sparkle feed URL now matches Amore hosting.** Update checks now use the Amore appcast path at `https://release.md-preview.app/v1/apps/doc.md-preview/appcast.xml`, so installed copies look at the feed that Amore publishes.

### Security

- **Rendered Markdown HTML is sanitized with DOMPurify.** The app and Quick Look extension now route generated article HTML through DOMPurify before inserting it into the WebView, blocking inline event handlers, executable tags, dangerous URL schemes, hidden style-based copy substitutions, and related raw-HTML injection attacks while preserving Markdown rendering, KaTeX, Mermaid, highlight.js, local images, links, task lists, footnotes, code copy buttons, find, scrollspy, and heading IDs ([#104](https://github.com/pluk-inc/markdown-preview/pull/104)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@luuccaaaa](https://github.com/luuccaaaa) — rendered Markdown HTML sanitization with DOMPurify ([#104](https://github.com/pluk-inc/markdown-preview/pull/104))
- [@lucasfischer](https://github.com/lucasfischer) — Amore sponsor credit ([#105](https://github.com/pluk-inc/markdown-preview/pull/105))

## [0.0.21] – 2026-05-11

The table of contents now follows your reading position, the Project Navigator reacts to folder changes, and code blocks are easier to copy.

### Added

- **Table of contents scrollspy.** The outline highlights the heading currently in view while you scroll, keeps click-selected headings stable, and resumes tracking naturally on the next scroll ([#101](https://github.com/pluk-inc/markdown-preview/pull/101)).
- **Live Project Navigator updates.** The navigator watches visible folders for Markdown file additions, renames, and deletes, updating the sidebar without reopening the document ([#101](https://github.com/pluk-inc/markdown-preview/pull/101)).
- **Copy buttons for code blocks.** Fenced code blocks now expose a hover-revealed Copy button that stays pinned while horizontally scrolling long snippets, writes through the native pasteboard bridge, and provides accessible copied-state feedback ([#102](https://github.com/pluk-inc/markdown-preview/pull/102)).

### Fixed

- **Project Navigator root stays stable.** Opening a deeper file from the navigator no longer narrows the root folder unexpectedly; opening an unrelated file still resets the navigator to the new folder ([#101](https://github.com/pluk-inc/markdown-preview/pull/101)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@luuccaaaa](https://github.com/luuccaaaa) — table of contents scrollspy, live Project Navigator updates, and stable navigator roots ([#101](https://github.com/pluk-inc/markdown-preview/pull/101))

## [0.0.20] – 2026-05-09

The sidebar toolbar menu now stays responsive and shows the correct selected mode after toolbar customization.

### Fixed

- **Sidebar mode menu survives toolbar customization.** The toolbar's Sidebar pull-down no longer lets Customize Toolbar palette copies steal the live menu reference, so Table of Contents and Project Navigator keep responding and their checkmarks stay in sync after closing the native customization sheet.

## [0.0.19] – 2026-05-09

Syntax highlighting is back without the Shiki startup cost, the sidebar can browse sibling Markdown files, and preview reading controls are easier to reach.

### Added

- **Project Navigator sidebar mode.** The sidebar picker now switches between Hide, Table of Contents, and Project Navigator; the navigator lazily browses sibling Markdown files in the current folder and includes contextual actions for opening, revealing, copying paths, and copying file contents ([#93](https://github.com/pluk-inc/md-preview.app/pull/93)).
- **Preview zoom controls.** A default toolbar zoom group and View-menu shortcuts (`⌘+`, `⌘-`, `⌘0`) resize the rendered preview from 50% to 300%, remember the chosen scale across launches, and use `WKWebView.pageZoom` so text, math, diagrams, and code scale together ([#96](https://github.com/pluk-inc/md-preview.app/pull/96), [#97](https://github.com/pluk-inc/md-preview.app/pull/97)).
- **Customizable Print and Copy toolbar items.** Print and Copy are available from View → Customize Toolbar, with Copy placing the current Markdown source on the clipboard and briefly swapping its icon on success ([#96](https://github.com/pluk-inc/md-preview.app/pull/96)).
- **Syntax highlighting returns via highlight.js.** Fenced code blocks are colored again in the app and Quick Look using a bundled highlight.js common-languages build, lazy-loaded after first paint and re-applied on fast-path document swaps so initial preview rendering stays responsive ([#90](https://github.com/pluk-inc/md-preview.app/pull/90)).

### Changed

- **Markdown rendering now runs off the main actor.** Pure Markdown-to-HTML work moved to background tasks with generation checks so large files and rapid file switches do not stall the UI or let stale renders overwrite newer content ([#95](https://github.com/pluk-inc/md-preview.app/pull/95)).
- **Sandbox folder access is simpler.** The app now uses the same read-only absolute-path temporary exception pattern as the Quick Look extension, removing the folder-access banner and bookmark-management flow while keeping writes behind the existing sandbox save path ([#93](https://github.com/pluk-inc/md-preview.app/pull/93)).

### Fixed

- **Launch warmup no longer flashes synthetic content.** The hidden warmup document still primes KaTeX, Mermaid, and highlight.js, but the synthetic Mermaid diagram cannot briefly appear before the first real document renders ([#94](https://github.com/pluk-inc/md-preview.app/pull/94)).
- **Zoom toolbar tooltips are reliable.** The toolbar group and its Zoom In / Zoom Out subitems now expose tooltip metadata at the toolbar-item level as well as on the segmented control ([#98](https://github.com/pluk-inc/md-preview.app/pull/98)).
- **TOC title alignment is flush again.** The table-of-contents title row no longer carries the extra leading inset that made it sit out of alignment with the rest of the sidebar ([#98](https://github.com/pluk-inc/md-preview.app/pull/98)).

### Contributors

Thanks to the external contributors who reported issues fixed in this release:

- [@amiramir](https://github.com/amiramir) — reported the preview zoom request ([#91](https://github.com/pluk-inc/md-preview.app/issues/91))
- [@MyCometG3](https://github.com/MyCometG3) — reported keyboard navigation improvements covered by the new scroll actions ([#92](https://github.com/pluk-inc/md-preview.app/issues/92))

## [0.0.18] – 2026-05-07

A faster cold launch, snappier file switches, and a temporary step back on syntax highlighting while a non-blocking solution is built.

### Added

- **Vendor JS warms up at launch.** A synthetic markdown doc renders into the WebView while the open panel is still on screen, so KaTeX and Mermaid finish parsing before the user picks a file. By the time the picked file lands, the renderers are already ready ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).

### Changed

- **Cold-open of a 4 KB markdown file dropped from ~400 ms to ~50 ms (5–8× faster perceived load).** Vendor JS used to be inlined in the HTML head, blocking the parser on every load. It now lazy-loads after first paint via the `md-asset:` scheme, so the article is visible before the bundles finish downloading. The asset-scheme handler caches vendor blobs in `NSCache` and resolves `__vendor/<file>` paths from the app bundle independently of the user-file base URL. Quick Look continues to use inline delivery because its `QLPreviewReply` payload model bundles HTML and attachments differently ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).
- **Switching files takes a fast path instead of a full WebView reload.** When the renderer mix matches what's already loaded, the article body is swapped in place via `MdPreview.update(articleHTML)` and each renderer's idempotent reapplier re-runs — no `loadHTMLString` reload, no vendor re-parse. A `RendererFingerprint.covers(_:)` check lets any subset of renderers fast-path into the all-true warmup state ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).
- **Stale content clears while sheets are dismissing.** Opening a new file now blanks the preview during sheet dismissal so the previous doc doesn't linger behind the open panel ([#84](https://github.com/pluk-inc/md-preview.app/pull/84)).

### Removed

- **Syntax highlighting (Shiki) removed for now.** Shiki was pinning the JS thread for ~1 s on a code block's first cold grammar compile (TypeScript was the worst offender), even after launch warmup, idle-defer, per-block IntersectionObserver, and post-paint background grammar warmups. The cost is inherent to TextMate-grammar regex compilation on the main thread, so the only viable fix is moving Shiki into a Web Worker, which warrants its own release. Code blocks now render with the existing monospace + rounded grey background, just without per-token color. The 2.5 MB `shiki.bundle.js` is no longer shipped in the app bundle.

## [0.0.17] – 2026-05-07

Two macOS 26 fixes — the window opens at full size again, and inline math renders correctly in RTL paragraphs.

### Fixed

- **Window no longer launches collapsed on macOS 26.** The find bar's bottom rule (an `NSBox` with `boxType = .separator`) inside a bottom `NSTitlebarAccessoryViewController` was triggering an AppKit layout regression that bypassed the window's `contentMinSize` and snapped the window to the toolbar's natural minimum width (~169 pt) on launch. Only vertical resizing worked, and toggling the sidebar made the window disappear. Replaced the find-bar separator and the access banner's separators with a 1 pt `NSView` filled with `NSColor.separatorColor` — same look, no regression ([#79](https://github.com/pluk-inc/md-preview.app/issues/79), [#81](https://github.com/pluk-inc/md-preview.app/pull/81)).
- **Inline KaTeX math stays LTR inside RTL paragraphs.** Math embedded in Hebrew / Arabic paragraphs was inheriting the surrounding RTL direction and rendering reversed (e.g. `$f(x)=x^2$` came out as `f(x) = ^2x`). The Markdown stylesheet now pins `.katex` to `direction: ltr` with `unicode-bidi: isolate`, so math renders LTR while the surrounding RTL text continues to flow right-to-left ([#76](https://github.com/pluk-inc/md-preview.app/pull/76)).

### Contributors

Thanks to the external contributors who shipped in this release:

- [@manemajef](https://github.com/manemajef) — inline KaTeX math direction fix in RTL paragraphs ([#76](https://github.com/pluk-inc/md-preview.app/pull/76))
- [@pryley](https://github.com/pryley) — reported the window-collapse bug on macOS 26 ([#79](https://github.com/pluk-inc/md-preview.app/issues/79))

## [0.0.16] – 2026-05-07

Mermaid diagrams you can pan and zoom, faster live-preview saves, and a polished find bar and sidebar.

### Added

- **Mermaid pan and zoom.** `⌘`+wheel or pinch zooms toward the cursor, drag pans at any zoom, and double-click toggles between 2× and fit. A hover HUD exposes `−` / `100%` / `+` controls, the diagram auto-recenters when you zoom back to 100%, and 100% is the floor (no shrinking below). Plain wheel still scrolls the page, so there's no scroll-jacking ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **`Match:` label with toggle buttons in the find bar.** The Contains / Begins With picker switched from a segmented control to two `NSButton` toggles fronted by a `Match:` label, matching macOS Preview's accessibility shape (`AXToggle` subrole). Re-clicking the active mode is a no-op so it doesn't trigger a redundant search ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).
- **Hard scroll-edge effect under the find bar on macOS 26.1+.** The find-bar titlebar accessory opts into `preferredScrollEdgeEffectStyle = .hard`, giving it an opaque, sharp boundary against scrolling content. macOS 15 and 26.0 keep their existing look ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).
- **Sidebar file name scrolls with the outline.** The file name moved out of a sticky header into the outline view itself as a non-selectable first row, so it scrolls away alongside the TOC instead of pinning to the top ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).

### Changed

- **Saves no longer reload the whole preview.** When the page is already loaded and the renderer mix (math / Mermaid / Shiki) hasn't changed, the article body is swapped via `evaluateJavaScript` and each renderer's idempotent reapplier re-runs in place — saves no longer reparse the 3 MB Mermaid bundle and 2.5 MB Shiki bundle. First load and renderer-mix changes still do a full HTML load, and `<base href="md-asset:///">` ships unconditionally so asset swaps don't force a reload ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **Mermaid diagrams render lazily with reserved layout space.** Each figure renders on intersection via `IntersectionObserver` instead of one big `mermaid.run`, and reserves space using `aspect-ratio` from its viewBox so the document height stops bouncing as diagrams stream in. `contain: strict` on the zoom stage isolates layout and paint ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **Web view height is now push-based.** A new `mdPreviewHost` script-message handler pushes content height from JS via `ResizeObserver` plus per-renderer done events, replacing the staggered Mermaid (`[0.6, 1.2, 2.4]s`), KaTeX / Shiki (`[0.15, 0.4, 0.9]s`), and inner-cascade polls. Height updates arrive exactly when layout changes ([#62](https://github.com/pluk-inc/md-preview.app/pull/62)).
- **Re-displaying the same file is a no-op in the sidebar.** When the file watcher fires with identical markdown and file name, the sidebar skips the parse + reload + re-expand cycle, preserving expansion state without flicker ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).

### Fixed

- **Native overlay scrollbar restored when scrolling is allowed.** Dropped a redundant `::-webkit-scrollbar { display: initial !important; … }` rule that was overriding the macOS overlay scrollbar; WebKit now falls back to the system scrollbar ([#77](https://github.com/pluk-inc/md-preview.app/pull/77)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@hailam](https://github.com/hailam) — Mermaid pan/zoom, lazy rendering, push-based height, and reload-free saves ([#62](https://github.com/pluk-inc/md-preview.app/pull/62))

## [0.0.15] – 2026-05-06

A proper find bar and right-to-left text support.

### Added

- **Find bar with match navigation, modes, and a burst highlight.** Searching now opens a slim bar below the toolbar with an `X of N` counter, prev/next chevrons, a Done button, and a Contains / Begins With mode toggle. Enter and Shift+Enter cycle forward and backward through matches (the original ask in [#72](https://github.com/pluk-inc/md-preview.app/issues/72)), and the current match scale-pulses with a yellow pill so it's easy to spot after a long scroll. The find pass skips scrolling when the match is already on screen, debounces keystrokes, gates Begins-With on the preceding character, and filters hidden subtrees so KaTeX MathML mirrors and Mermaid source nodes don't show up as phantom matches ([#73](https://github.com/pluk-inc/md-preview.app/pull/73)).
- **Automatic RTL text direction.** Paragraphs, list items, and headings whose first strong character is from an RTL script (Hebrew, Arabic, Syriac, etc.) now render with `dir="rtl"` and right alignment. Detection looks through inline markup (so `**שלום**` works), skips neutral characters like parentheses and punctuation, preserves any existing `dir` attribute, and leaves LTR-only documents unchanged ([#67](https://github.com/pluk-inc/md-preview.app/pull/67)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@manemajef](https://github.com/manemajef) — automatic RTL text direction support ([#67](https://github.com/pluk-inc/md-preview.app/pull/67))

## [0.0.14] – 2026-05-06

Quick Look now renders relative images.

### Added

- **Relative images render in Quick Look previews.** When a Markdown file references sibling assets like `![](images/local.png)`, the Quick Look extension now inlines each readable sibling as a `cid:` attachment on the preview reply and rewrites the `<img src>` to match, so local images appear in Finder/Spotlight previews instead of as broken-image glyphs. The extension gained a read-only `temporary-exception.files.absolute-path.read-only` entitlement so the sandboxed preview process can read sibling files (the main app already handles this through its `md-asset://` scheme). Per-image and cumulative byte budgets cap pathological folders; absolute URLs, fragment refs, host-absolute paths, and unreadable files pass through untouched ([#68](https://github.com/pluk-inc/md-preview.app/pull/68)).

### Contributors

Thanks to the external contributor who shipped in this release:

- [@DivineDominion](https://github.com/DivineDominion) — relative images in Quick Look previews ([#68](https://github.com/pluk-inc/md-preview.app/pull/68))

## [0.0.13] – 2026-05-05

Native printing, plus two rendering fixes.

### Added

- **Print the rendered Markdown.** File → Print (⌘P) now prints the previewed document through WKWebView with horizontal fit pagination, instead of falling through to AppKit's generic `print:` and printing the sidebar and window chrome. The app gained the `com.apple.security.print` entitlement so this works in the sandbox.

### Fixed

- **GFM task lists render inline without a duplicate bullet.** Task list items were drawing both a list marker and a checkbox with the label wrapping to a new line below. Task `<li>`s and their checkboxes are now tagged with GitHub's `task-list-item` / `task-list-item-checkbox` class names, so CSS suppresses the marker and the first paragraph stays inline next to the checkbox ([#63](https://github.com/pluk-inc/md-preview.app/issues/63)).
- **No placeholder content on launch.** Removed the leftover "WKWebView pipeline is live" sample that the split view rendered at startup, so the app opens with an empty preview area until you load a document.

## [0.0.12] – 2026-05-05

Code highlighting, richer Markdown heading and footnote rendering, and README sponsor updates.

### Added

- **Code blocks now use Shiki syntax highlighting.** Fenced code blocks render with bundled Shiki highlighting in both the app and Quick Look, so previews show language-aware colors without needing network access.

### Fixed

- **Footnotes now render correctly.** Markdown footnote definitions and references are collected, linked, and rendered as a proper footnotes section instead of appearing as plain paragraph content.
- **Inline markup works inside headings.** Emphasis, links, code spans, and other inline Markdown now render correctly inside heading text while keeping generated heading anchors stable.

## [0.0.11] – 2026-05-04

Homebrew install path and stronger default-handler claims for Markdown files.

### Added

- **Install via Homebrew.** `brew install --cask pluk-inc/tap/markdown-preview` is now the primary install method; the DMG remains as a fallback. The release script auto-bumps the [pluk-inc/homebrew-tap](https://github.com/pluk-inc/homebrew-tap) cask (version + sha256) after each successful `amore release`, so brew users pick up new versions on the same cadence as direct downloads.

### Fixed

- **Markdown Preview now wins as the default `.md` handler on more setups.** `LSHandlerRank` for the standard markdown UTI was promoted from `Default` to `Owner`, so LaunchServices prefers Markdown Preview over apps that only assert a weaker claim. Users who previously had to set "Always Open With" by hand should pick the app up automatically after a fresh install.
- **Long-tail markdown extensions are now claimed uncontested.** `.mdown`, `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, and `.mdtext` are exported under app-private UTIs (`doc.md-preview.*`) that conform to `net.daringfireball.markdown`. Because no other app declares UTIs in that namespace, LaunchServices has no competing candidate for these files and Markdown Preview opens them without requiring user intervention.

## [0.0.10] – 2026-05-04

LaTeX math rendering, broader Markdown file-format support, and a rendering fix for inline HTML in body text and code.

### Added

- **LaTeX math now renders via KaTeX.** Inline math (`$…$`, `\(…\)`) and display math (`$$…$$`, `\[…\]`) are typeset on load in both the app and the Quick Look extension. KaTeX ships inside the bundle, so previews work offline.
- **More Markdown file types open natively.** Added `.mkd`, `.mkdn`, `.mdwn`, `.mdtxt`, `.mdtext`, and `.rmd` alongside the existing `.md` / `.markdown` / `.mdown` / `.txt`. Quick Look and the Open With list pick the app up for these extensions too.

### Fixed

- **Math extraction skips code spans and fences.** Dollar signs and `\(…\)` sequences inside backticks or fenced code blocks are no longer mistaken for math, so snippets like `` `$PATH` `` and code samples render verbatim instead of being eaten by the math pass.
- **HTML in body text and code is now properly escaped.** `a < b`, `Tom & Jerry`, `` `<div>` ``, and fenced code containing `<`, `>`, or `&` previously rendered mangled or vanished entirely because swift-markdown's default `HTMLFormatter` doesn't escape those characters in text or code. A new `EscapingHTMLFormatter` walker handles escaping while still passing raw HTML blocks through verbatim per CommonMark.

### Contributors

Thanks to the external contributors who shipped in this release:

- [@dppeak](https://github.com/dppeak) — broader Markdown file-format support ([#31](https://github.com/pluk-inc/md-preview.app/pull/31))
- [@yaksher](https://github.com/yaksher) — reported the HTML-escape bug fixed in [#35](https://github.com/pluk-inc/md-preview.app/pull/35) ([#33](https://github.com/pluk-inc/md-preview.app/issues/33))

## [0.0.9] – 2026-05-03

Mermaid diagram rendering in the app and Quick Look.

- **Fenced `mermaid` code blocks now render as diagrams.** The Markdown pipeline detects `mermaid` fences, swaps them for diagram containers, and runs the Mermaid renderer on load — flowcharts, sequence diagrams, class diagrams, and the rest show up inline instead of as raw code.
- **Renderer is bundled, so previews work offline.** The Mermaid script ships inside the app bundle and is shared with the Quick Look extension; no CDN request is made when opening a document.
- **Diagrams follow the system appearance.** Mermaid initializes with the dark theme when the system is in dark mode and the default theme otherwise, and uses the SF system font so labels match the surrounding text.

## [0.0.8] – 2026-05-03

Tabbed Inspector with native segmented picker.

- **Inspector now has Document and Properties tabs.** A native segmented picker with SF Symbol icons (doc / info) splits the panel into a Document tab for file and content stats and a Properties tab for YAML frontmatter, instead of stacking everything in one scrolling list.
- **Empty Properties tab shows a placeholder.** Documents without frontmatter now display "No YAML frontmatter" filling the available space, so the tab doesn't collapse to nothing.
- **Picker matches Apple's pill-style segmented look on macOS 26 Tahoe.** Uses `.controlSize(.large)` plus `.buttonSizing(.flexible)` on Tahoe and falls back to `.fixedSize()` on macOS 15 Sequoia.

## [0.0.7] – 2026-05-03

YAML frontmatter rendering fix and Inspector metadata.

- **YAML frontmatter no longer collapses into a giant heading.** The CommonMark renderer was treating the closing `---` of a frontmatter block as a setext heading underline, turning `title:` / `date:` / `tags:` into one oversized H2 at the top of the document. The block is now stripped before parsing and the preview matches what GitHub, Obsidian, and VS Code show.
- **Frontmatter shows up in the Inspector.** A new **Properties** section at the top of the Inspector lists each key/value pair from the document's frontmatter, so the metadata is one click away even though it's hidden from the rendered preview. The Quick Look extension hides it too.
- **Word, line, and heading counts now reflect body content.** The Inspector's stats no longer include the frontmatter block in their totals.

## [0.0.6] – 2026-05-02

Toolbar, banner, and table-of-contents polish.

- **Search field collapses to a magnifying-glass button in narrow windows.** When the toolbar is too tight to fit the expanded search field, it now folds into an icon-only button matching the rest of the toolbar instead of being clipped.
- **Open With toolbar item shows the resolved editor.** When a default Markdown editor is set, the toolbar item now reads "Open in <Editor>" as both label and tooltip, and the menu lists apps by their Finder display name without the `.app` suffix. The chosen editor's location is also remembered alongside its bundle ID, so launches still resolve when the bundle ID is unavailable.
- **Folder-access banner no longer clips text on macOS 15.** The banner now advertises a fixed height to the titlebar accessory so descenders in the message label aren't cut off, and the redundant top/bottom separators are hidden on macOS 15 (where AppKit already draws system ones).
- **Folder-access banner stays until access is granted.** Removed the dismiss button so the prompt no longer disappears when accidentally clicked — it now goes away only after you grant read access to the folder.
- **TOC clicks scroll headings below the toolbar.** Jumping to a heading from the sidebar now accounts for the toolbar height plus a small breathing margin, so the target heading lands in view instead of behind the toolbar.
- **Share toolbar button is the right size.** The share item no longer renders an oversized icon next to the other toolbar buttons.

## [0.0.5] – 2026-05-02

Small fullscreen polish for the sidebar.

- **Sidebar title sits correctly in fullscreen.** The document title at the top of the table-of-contents pane no longer slides under the toolbar when the window enters fullscreen — it now anchors to the safe-area inset and stays put in both windowed and fullscreen modes.

## [0.0.4] – 2026-05-02

Relative images and links in Markdown files now render in the sandboxed app.

- **Render relative local assets via a folder-access banner.** When a document references images or files alongside it, Markdown Preview now shows an in-window banner offering to grant read access to the parent folder. Once granted, the access is remembered across launches and assets load through a dedicated `md-asset://` scheme so they appear inline in the preview.
- **Stable DMG filename for GitHub releases.** The DMG attached to each GitHub release is now `Markdown-Preview.dmg` without a version suffix, so download links stay valid across versions.

## [0.0.3] – 2026-05-02

Better Markdown rendering and a tidier **Open With** menu.

- **Switched the Markdown engine to swift-markdown (cmark-gfm).** Rendering is now CommonMark- and GitHub-Flavored-Markdown-compliant, so tables, task lists, strikethrough, and autolinks render the way you'd expect on GitHub.
- **Fixed the Open With list.** No more duplicate Markdown Preview entries from old build copies, and unrelated apps that only claim a generic plain-text association no longer show up — only apps that actually edit Markdown are listed.

## [0.0.2] – 2026-05-01

Compatibility release: Markdown Preview now runs on macOS 15 Sequoia in addition to macOS 26 Tahoe.

- **Lowered the minimum macOS version to 15.0 (Sequoia).** Previously required macOS 26 Tahoe.
- **Replaced the app icon with an Icon Composer `.icon` bundle.** Fixes the icon appearing oversized on Sequoia — the system now applies its own mask and the standard safe-area inset.

## [0.0.1] – 2026-04-30

First public build of Markdown Preview — a fast, native macOS reader for `.md` files.

### Highlights

- Native WKWebView rendering with heading anchors and external link handling
- Sidebar table of contents that mirrors document headings (click to jump)
- Toggleable inspector panel with file metadata
- In-document search via the toolbar field plus standard `⌘F` / `⌘G` / `⌘⇧G`
- Open With menu that filters to apps declaring an editor role for Markdown and remembers your pick
- Share menu that copies the Markdown source itself, so Copy / Mail / Notes / Messages get the content instead of a file URL
- Quick Look extension for system-wide `.md` previews from Finder, Spotlight, and Mail
- Offer to register as the default `.md` handler on first launch
- Supports `.md`, `.markdown`, `.mdown`, and `.txt`
