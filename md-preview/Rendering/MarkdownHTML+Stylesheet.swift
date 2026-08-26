//
//  MarkdownHTML+Stylesheet.swift
//  md-preview
//
//  The document stylesheet.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // Mirrors MarkdownUI's Theme.docC. Top-only margins (bottom: 0), Apple SF
    // palette (text #1d1d1f / #f5f5f7, link #0066cc / #2997ff, grid #d2d2d7 /
    // #424245, code bg #f5f5f7 / #2A2828, aside bg #f5f5f7 / #323232), 15px continuous container
    // radius, horizontal-only table borders.
    static let stylesheet = """
    :root {
        color-scheme: light dark;
        --text: #1d1d1f;
        --secondary: #6e6e73;
        --link: #0066cc;
        --aside-bg: #f5f5f7;
        --aside-border: #696969;
        --quote-border: #d2d2d7;
        --code-bg: #f5f5f7;
        --grid: #d2d2d7;
    }
    :root[data-mdp-color-scheme="light"] {
        color-scheme: light;
    }
    :root[data-mdp-color-scheme="dark"] {
        color-scheme: dark;
        --text: #f5f5f7;
        --secondary: #86868b;
        --link: #2997ff;
        --aside-bg: #323232;
        --aside-border: #9a9a9e;
        --quote-border: #6e6e73;
        --code-bg: #2A2828;
        --grid: #424245;
    }
    :root[data-mdp-color-scheme],
    :root[data-mdp-color-scheme] body {
        background: Canvas;
    }
    @media (prefers-color-scheme: dark) {
        :root:not([data-mdp-color-scheme="light"]) {
            --text: #f5f5f7;
            --secondary: #86868b;
            --link: #2997ff;
            --aside-bg: #323232;
            --aside-border: #9a9a9e;
            --quote-border: #6e6e73;
            --code-bg: #2A2828;
            --grid: #424245;
        }
    }

    * { box-sizing: border-box; }
    mark.md-search-highlight {
        background: #ffd84d;
        color: #1d1d1f;
        -webkit-box-decoration-break: clone;
    }
    mark.md-search-highlight-current {
        background: #ffbf00;
    }
    .md-search-burst {
        position: absolute;
        pointer-events: none;
        background: rgba(255, 191, 0, 0.5);
        border-radius: 6px;
        box-shadow: 0 0 4px rgba(0, 0, 0, 0.12),
                    0 2px 6px rgba(0, 0, 0, 0.15);
        z-index: 9999;
        transform-origin: center center;
        will-change: transform;
        animation: md-search-burst 250ms forwards;
    }
    /* Per-segment timing: accelerate into the peak (cubic-bezier ease-in),
       then decelerate out of it (strong ease-out). High matching velocity
       at the peak means the motion flows through without pausing — the
       "stuck" feel of multi-stop ease-out keyframes. */
    @keyframes md-search-burst {
        0% {
            transform: scale(1.0);
            animation-timing-function: cubic-bezier(0.55, 0, 1, 0.45);
        }
        50% {
            transform: scale(1.32);
            animation-timing-function: cubic-bezier(0, 0.55, 0.45, 1);
        }
        100% {
            transform: scale(1.0);
        }
    }
    @media (prefers-reduced-motion: reduce) {
        .md-search-burst { animation-duration: 1ms; }
    }
    html, body {
        margin: 0;
        padding: 0;
        overflow: hidden;
    }
    /* Hide inner scrollers' bars (tables, math) but never match the root:
       any custom ::-webkit-scrollbar style on <html>/<body> — including a
       later "restore" override — swaps the page's native macOS overlay
       scrollbar for WebKit's legacy one. Zero specificity (:where) keeps
       the pre::-webkit-scrollbar rules below winning for code blocks. */
    :where(:not(html):not(body))::-webkit-scrollbar {
        display: none;
        width: 0;
        height: 0;
    }
    body {
        font-family: var(--mdp-doc-font, \(bodyFontFamily));
        font-size: \(bodyFontSize)px;
        line-height: \(bodyLineHeight);
        color: var(--text);
        background: transparent;
        padding: \(pagePaddingTop)px \(pagePaddingHorizontal)px \(pagePaddingBottom)px;
        -webkit-font-smoothing: antialiased;
    }

    article.markdown-body {
        max-width: \(contentColumnWidth)px;
        margin-left: auto;
        margin-right: auto;
    }
    article.markdown-body > *:first-child { margin-top: 0 !important; }
    .md-inline-tab {
        white-space: pre;
        tab-size: 4;
    }
    .md-source-list-indent-step {
        display: block;
        box-sizing: border-box;
        padding-inline-start: 1.6em;
    }
    .md-source-list-line {
        display: block;
        margin-top: \(listItemSpacing)px;
    }
    .md-source-list-marker {
        display: inline-block;
        box-sizing: border-box;
        width: 1.6em;
        margin-inline-start: -1.6em;
        padding-inline-end: 0.45em;
        text-align: end;
    }
    .md-source-task-marker {
        text-align: center;
        padding-inline-end: 0.25em;
    }

    /* Frontmatter properties — a quiet metadata panel. Deliberately
       quieter than document content: no row borders (content tables own
       horizontal rules), a muted key column, and a single hairline that
       hands off to the document body. */
    .md-frontmatter {
        margin: 0 0 1.2em;
        padding: 0 0 1em;
        border-bottom: 1px solid var(--grid);
    }
    .md-frontmatter table {
        display: table;
        width: 100%;
        table-layout: fixed;
        margin: 0;
        overflow: visible;
        font-size: 0.92em;
        line-height: 1.5;
    }
    .md-frontmatter th,
    .md-frontmatter td {
        padding: 0.28em 0;
        border: 0;
        vertical-align: baseline;
        overflow-wrap: anywhere;
        text-align: left;
    }
    .md-frontmatter th {
        width: 26%;
        padding-right: 1.4em;
        font-weight: 500;
        color: var(--secondary);
    }
    .md-frontmatter td {
        white-space: pre-wrap;
    }
    .md-fm-pill {
        display: inline-block;
        margin: 0 0.4em 0.2em 0;
        padding: 0.08em 0.7em;
        border-radius: 999px;
        background: color-mix(in srgb, var(--link) 12%, transparent);
        color: var(--link);
        font-size: 0.95em;
        overflow-wrap: anywhere;
    }
    .md-fm-empty::before {
        content: "—";
        color: var(--secondary);
    }

    p {
        margin: \(paragraphSpacing)px 0 0;
    }
    /* The final blank of a run shrinks to a small gap so a single authored
       blank plus the next block's margin matches other renderers' paragraph
       rhythm. Earlier blanks in the run keep their natural line height, so
       extra authored blanks still grow the gap. */
    .md-source-blank-line {
        height: \(blankLineGap)px;
    }
    .md-source-blank-line:has(+ .md-source-blank-line) {
        height: \(sourceLineHeight)px;
    }

    h1, h2, h3, h4, h5, h6 {
        font-weight: 600;
        line-height: 1.18;
        margin: 1.6em 0 0;
    }
    /* Minor-third heading scale: each level steps down visibly, and only
       the document title carries the heavier weight. */
    h1 { font-size: 1.802em; font-weight: 700; margin-top: 0.8em; }
    h2 { font-size: 1.602em; line-height: 1.06; }
    h3 { font-size: 1.424em; line-height: 1.07; }
    h4 { font-size: 1.266em; line-height: 1.08; }
    h5 { font-size: 1.125em; line-height: 1.09; }
    h6 { font-size: 1em; line-height: 1.24; }
    /* The blank before a heading shrinks like every final blank; the
       heading's own margin restores the one-line gap, keeping the total at
       one source line plus the small breathing room (blank + margin). */
    .md-source-blank-line + h1,
    .md-source-blank-line + h2,
    .md-source-blank-line + h3,
    .md-source-blank-line + h4,
    .md-source-blank-line + h5,
    .md-source-blank-line + h6 {
        margin-top: \(sourceLineHeight)px;
    }

    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .footnote-ref {
        font-size: 0.75em;
        line-height: 0;
        vertical-align: super;
    }
    .footnote-ref a {
        padding: 0 0.12em;
    }
    .footnotes {
        margin-top: 2.35em;
        color: var(--text);
        font-size: 0.9em;
        line-height: 1.45;
    }
    .footnotes hr {
        margin: 0 0 1em;
    }
    .footnotes ol {
        margin-top: 0;
        padding-left: 1.45em;
    }
    .footnotes li {
        margin-top: 0.72em;
        padding-left: 0.12em;
    }
    .footnotes li:first-child {
        margin-top: 0;
    }
    .footnotes li > p:first-child {
        margin-top: 0;
    }
    .footnote-backrefs {
        display: inline-flex;
        gap: 0.28em;
        margin-left: 0.28em;
        white-space: nowrap;
    }
    .footnote-backref {
        font-size: 0.78em;
        opacity: 0.65;
        vertical-align: baseline;
    }
    .footnote-backref:hover {
        opacity: 1;
    }

    code {
        font-family: \(codeFontFamily);
        font-size: var(--mdp-code-font-size, 0.88em);
        padding: 0.18em 0.42em;
        background: var(--code-bg);
        border-radius: 6px;
    }
    :not(pre) > code {
        overflow-wrap: anywhere;
        -webkit-box-decoration-break: clone;
        box-decoration-break: clone;
    }
    pre {
        position: relative;
        margin: \(paragraphSpacing)px 0 0;
        padding: 10px 14px;
        background: var(--code-bg);
        border-radius: 15px;
        overflow-x: auto;
        line-height: 1.45;
    }
    pre::-webkit-scrollbar {
        display: block;
        height: 10px;
        width: 0;
    }
    pre::-webkit-scrollbar-track {
        background: transparent;
    }
    pre::-webkit-scrollbar-thumb {
        background-color: color-mix(in srgb, var(--text) 22%, transparent);
        border-radius: 10px;
        border: 3px solid transparent;
        background-clip: padding-box;
    }
    pre:hover::-webkit-scrollbar-thumb {
        background-color: color-mix(in srgb, var(--text) 38%, transparent);
    }
    pre::-webkit-scrollbar-thumb:hover,
    pre::-webkit-scrollbar-thumb:active {
        background-color: color-mix(in srgb, var(--text) 55%, transparent);
    }
    pre code {
        /* highlight.js adds display:block with the .hljs class after its
           deferred pass. Match that layout from first paint so syntax
           coloring cannot change the code block's line boxes. */
        display: block;
        padding: 0;
        background: transparent;
        font-size: var(--mdp-code-font-size, 0.88em);
    }
    .md-code-wrap {
        position: relative;
        margin: \(paragraphSpacing)px 0 0;
    }
    .md-code-wrap > pre { margin: 0; }
    .md-code-copy {
        position: absolute;
        top: 8px;
        right: 8px;
        appearance: none;
        min-width: 56px;
        height: 24px;
        padding: 0 10px;
        border: none;
        border-radius: 8px;
        color: var(--secondary);
        background: color-mix(in srgb, var(--text) 10%, var(--code-bg));
        font: 500 11px/1 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        cursor: pointer;
        opacity: 0;
        transition: opacity 120ms ease,
                    color 120ms ease,
                    background-color 120ms ease,
                    transform 120ms ease;
        user-select: none;
        -webkit-user-select: none;
        z-index: 2;
    }
    .md-code-wrap:hover .md-code-copy,
    .md-code-wrap:focus-within .md-code-copy,
    .md-code-copy.is-copied {
        opacity: 1;
    }
    .md-code-copy:hover {
        color: var(--text);
        background: color-mix(in srgb, var(--text) 16%, var(--code-bg));
    }
    .md-code-copy:active {
        background: color-mix(in srgb, var(--text) 22%, var(--code-bg));
        transform: scale(0.97);
    }
    .md-code-copy:focus-visible {
        outline: none;
        box-shadow: 0 0 0 3px color-mix(in srgb, AccentColor 60%, transparent);
    }
    @media (prefers-reduced-motion: reduce) {
        .md-code-copy { transition: none; }
        .md-code-copy:active { transform: none; }
    }
    .mermaid-figure {
        position: relative;
        margin: \(largeBlockSpacing)px auto 0;
        background: var(--code-bg);
        border-radius: 15px;
        overflow: hidden;
        outline: none;
        aspect-ratio: var(--mm-aspect, 4 / 3);
        max-height: min(70vh, 720px);
        contain: layout paint;
    }
    .mermaid-figure.mermaid-width-expanded {
        width: 100%;
        max-height: none;
    }
    .mermaid-figure:focus-visible {
        box-shadow: 0 0 0 3px color-mix(in srgb, AccentColor 60%, transparent);
    }
    .mermaid-stage {
        position: absolute;
        inset: 0;
        overflow: hidden;
        contain: strict;
    }
    .mermaid-figure .mermaid-stage { cursor: grab; }
    .mermaid-figure .mermaid-stage:active { cursor: grabbing; }
    .mermaid {
        position: absolute;
        inset: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 16px;
        box-sizing: border-box;
    }
    .mermaid svg {
        display: block;
        width: 100%;
        max-width: none !important;
        height: 100%;
    }
    .mermaid-hud {
        position: absolute;
        top: 8px;
        right: 8px;
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: 6px 8px;
        max-width: calc(100% - 16px);
        opacity: 0;
        pointer-events: none;
        transition: opacity 0.12s ease;
        z-index: 2;
        font-size: 12px;
        line-height: 1;
        color: var(--text);
    }
    .mermaid-hud-group {
        display: flex;
        gap: 2px;
        padding: 3px;
        border-radius: 9px;
        background: color-mix(in srgb, Canvas 75%, transparent);
        backdrop-filter: blur(20px) saturate(160%);
        -webkit-backdrop-filter: blur(20px) saturate(160%);
        box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12);
    }
    .mermaid-figure:hover .mermaid-hud,
    .mermaid-figure:focus-within .mermaid-hud {
        opacity: 1;
        pointer-events: auto;
    }
    .mermaid-hud-btn {
        appearance: none;
        border: none;
        background: transparent;
        color: inherit;
        font: inherit;
        font-weight: 500;
        padding: 5px 9px;
        border-radius: 6px;
        cursor: pointer;
        min-width: 26px;
        text-align: center;
    }
    .mermaid-hud-btn:hover {
        background: color-mix(in srgb, var(--text) 12%, transparent);
    }
    .mermaid-hud-btn:active {
        background: color-mix(in srgb, var(--text) 18%, transparent);
    }
    .mermaid-hud-level {
        min-width: 46px;
        font-variant-numeric: tabular-nums;
    }
    .mermaid-hud-width {
        line-height: 12px;
    }
    .mermaid-hud-width-symbol {
        display: inline-block;
        font-size: 22px;
        font-weight: 600;
    }
    .mermaid-hud-popup {
        font-size: 16px;
        line-height: 12px;
    }
    @media (prefers-reduced-motion: reduce) {
        .mermaid-hud { transition: none; }
    }
    .mermaid-error {
        position: static;
        aspect-ratio: auto;
        padding: 12px 16px;
        text-align: left;
        white-space: pre-wrap;
        font-family: \(codeFontFamily);
        font-size: 0.88em;
    }
    .math-display {
        margin: 1.2em 0 0;
        overflow-x: auto;
        overflow-y: hidden;
    }
    .math-display .katex-display {
        margin: 0;
    }
    .math-error {
        color: #b00020;
        background: var(--code-bg);
        padding: 4px 8px;
        border-radius: 6px;
        font-family: \(codeFontFamily);
        font-size: 0.88em;
        white-space: pre-wrap;
    }
    :root[data-mdp-color-scheme="dark"] .math-error {
        color: #ff6e6e;
    }
    @media (prefers-color-scheme: dark) {
        :root:not([data-mdp-color-scheme="light"]) .math-error { color: #ff6e6e; }
    }
    .katex { direction: ltr !important; unicode-bidi: isolate; }

    blockquote {
        margin: \(quoteSpacing)px 0 0;
        padding-inline-start: 1em;
        border-inline-start: 4px solid var(--quote-border);
        color: var(--secondary);
    }
    blockquote > *:first-child { margin-top: 0; }

    .markdown-alert {
        margin: \(largeBlockSpacing)px 0 0;
        padding: 12px 16px;
        background: var(--aside-bg);
        border-left: 4px solid var(--aside-border);
        border-radius: 6px;
        color: var(--text);
    }
    .markdown-alert > *:first-child { margin-top: 0; }
    .markdown-alert-title {
        font-weight: 600;
        margin: 0;
        display: flex;
        align-items: center;
        line-height: 1;
    }
    .markdown-alert-icon {
        width: 1em;
        height: 1em;
        margin-right: 0.5em;
        flex: 0 0 auto;
        fill: currentColor;
    }
    .markdown-alert-note { border-left-color: #0969da; }
    .markdown-alert-note .markdown-alert-title { color: #0969da; }
    .markdown-alert-tip { border-left-color: #1a7f37; }
    .markdown-alert-tip .markdown-alert-title { color: #1a7f37; }
    .markdown-alert-important { border-left-color: #8250df; }
    .markdown-alert-important .markdown-alert-title { color: #8250df; }
    .markdown-alert-warning { border-left-color: #9a6700; }
    .markdown-alert-warning .markdown-alert-title { color: #9a6700; }
    .markdown-alert-caution { border-left-color: #d1242f; }
    .markdown-alert-caution .markdown-alert-title { color: #d1242f; }

    ul, ol { margin: \(paragraphSpacing)px 0 0; padding-left: 1.6em; }
    ul { list-style-type: "•  "; }
    /* The text marker stays for copy/paste and for reserving the gutter,
       but renders transparent; a 0.4em circle is painted in its place.
       Drawn with a border, not a background, so PDF export keeps it even
       when backgrounds are not printed. */
    ul > li::marker { color: transparent; }
    ul > li { position: relative; }
    ul > li:not(.task-list-item)::before {
        content: "";
        position: absolute;
        inset-inline-start: -0.9em;
        top: 0.56em;
        width: 0;
        height: 0;
        border: 0.2em solid var(--text);
        border-radius: 50%;
    }
    li { margin-top: \(listItemSpacing)px; }
    li:first-child { margin-top: 0; }
    li > ul, li > ol { margin-top: \(listItemSpacing)px; }
    li > p:first-child { margin-top: 0; }

    li.task-list-item { list-style: none; }
    /* Completed tasks read as done — struck through and muted. */
    li.task-list-item:has(input.task-list-item-checkbox:checked) {
        color: var(--secondary);
        text-decoration: line-through;
    }
    li.task-list-item > p:first-of-type { display: inline; margin-top: 0; }
    .task-list-item-checkbox {
        -webkit-appearance: none;
        appearance: none;
        width: 1.55em;
        height: 1.55em;
        margin: 0 0.3em 0.1em -1.85em;
        vertical-align: middle;
        border: 1.5px solid var(--grid);
        border-radius: 50%;
        background: transparent;
        position: relative;
        flex: 0 0 auto;
    }
    .task-list-item-checkbox:checked {
        border-color: #007aff;
        background: #007aff;
    }
    .task-list-item-checkbox:not(:disabled) { cursor: pointer; }
    .task-list-item-checkbox:checked::after {
        content: "";
        position: absolute;
        inset: 0;
        background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M4.4 8.4 L7 11 L11.6 5.4" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>');
        background-repeat: no-repeat;
        background-position: center;
        background-size: 100% 100%;
    }

    table {
        margin: \(largeBlockSpacing)px 0 0;
        border-collapse: collapse;
        display: block;
        overflow-x: auto;
        max-width: 100%;
    }
    th, td {
        padding: 9px 10px;
        border-top: 1px solid var(--grid);
        border-bottom: 1px solid var(--grid);
        text-align: left;
    }
    th { font-weight: 600; }

    .md-table-editor {
        position: relative;
        display: inline-block;
        width: fit-content;
        margin: \(largeBlockSpacing)px 0 0;
        max-width: 100%;
        overflow: visible;
    }
    .md-table-scroll {
        width: fit-content;
        max-width: 100%;
        overflow-x: auto;
    }
    .md-table-scroll > table { margin-top: 0; }
    .md-table-editor:focus { outline: none; }
    .md-table-editor th,
    .md-table-editor td { cursor: text; }
    .md-table-editor th[data-placeholder]:empty::before {
        content: attr(data-placeholder);
        color: var(--secondary);
        font-weight: 400;
        opacity: 0.72;
        pointer-events: none;
    }
    .md-table-editor th.is-editing,
    .md-table-editor td.is-editing {
        outline: 2px solid #007aff;
        outline-offset: -2px;
        background: color-mix(in srgb, #007aff 8%, transparent);
        white-space: pre-wrap;
    }
    .md-table-editor .is-table-part-selected {
        --table-selection-top-edge: 0 0 transparent;
        --table-selection-right-edge: 0 0 transparent;
        --table-selection-bottom-edge: 0 0 transparent;
        --table-selection-left-edge: 0 0 transparent;
        background: color-mix(in srgb, #007aff 14%, Canvas);
        box-shadow:
            var(--table-selection-top-edge),
            var(--table-selection-right-edge),
            var(--table-selection-bottom-edge),
            var(--table-selection-left-edge);
    }
    .md-table-editor .is-table-selection-top {
        --table-selection-top-edge: inset 0 1px color-mix(in srgb, #007aff 52%, transparent);
    }
    .md-table-editor .is-table-selection-right {
        --table-selection-right-edge: inset -1px 0 color-mix(in srgb, #007aff 52%, transparent);
    }
    .md-table-editor .is-table-selection-bottom {
        --table-selection-bottom-edge: inset 0 -1px color-mix(in srgb, #007aff 52%, transparent);
    }
    .md-table-editor .is-table-selection-left {
        --table-selection-left-edge: inset 1px 0 color-mix(in srgb, #007aff 52%, transparent);
    }
    .md-table-editor.is-saving { opacity: 0.72; }

    hr {
        border: 0;
        height: 1px;
        background: var(--grid);
        margin: \(hrSpacing)px 0 0;
    }

    img {
        display: block;
        max-width: 100%;
        margin: 1.6em auto;
        border-radius: 10px;
    }
    /* Keep downscaled images proportional, but let explicit width/height
       attributes (e.g. GitHub-style <img height="54">) take effect. */
    img:not([width]):not([height]) {
        height: auto;
    }
    p img {
        display: inline-block;
        vertical-align: middle;
        margin: 0 0.35em 0.35em 0;
    }
    p > img:only-child {
        display: block;
        margin: 1.6em auto;
    }

    strong { font-weight: 600; }
    em { font-style: italic; }

    [dir="rtl"] { text-align: right; }

    /* ---------------------------------------------------------------------
       Paper-optimized printing.

       WebKit lays print out at a viewport of the printable width in CSS px
       (96px per inch), and 1 CSS px maps to exactly 0.75pt on paper. Sizing
       the body in `pt` here therefore lands at that literal point size, with
       no scaling factor to compensate for. `md-print-size` (injected by the
       app at print time) overrides the default below.

       The on-screen palette is dark-mode aware; paper is not, so regular
       printing restores the light values unconditionally. PDF export adds
       `previewPrintClass` before entering WebKit's print pipeline, which
       excludes these paper-only changes and preserves the read-only page.
       --------------------------------------------------------------------- */
    @media print {
        :root:not(.\(previewPrintClass)) {
            color-scheme: light;
            --text: #1d1d1f;
            --secondary: #6e6e73;
            --link: #0066cc;
            --aside-bg: #f5f5f7;
            --aside-border: #696969;
            --quote-border: #d2d2d7;
            --code-bg: #f5f5f7;
            --grid: #d2d2d7;
        }
        html,
        body {
            overflow: visible;
        }
        :root:not(.\(previewPrintClass)),
        :root:not(.\(previewPrintClass)) body {
            background: #fff;
        }
        @page {
            margin: \(printPageMarginTop) \(printPageMarginSide) \(printPageMarginBottom);
        }
        body {
            -webkit-print-color-adjust: exact;
            print-color-adjust: exact;
        }
        :root:not(.\(previewPrintClass)) body {
            font-size: \(defaultPrintPointSize)pt;
            padding: 0;
        }
        /* NSPrintInfo owns the page margins, and the print viewport is
           narrower than the on-screen measure, so the column just fills it. */
        :root:not(.\(previewPrintClass)) article.markdown-body {
            max-width: none;
            margin: 0;
        }

        /* Interaction affordances are screen-only. */
        .md-code-copy,
        .md-search-burst,
        .mermaid-hud { display: none !important; }
        mark.md-search-highlight,
        mark.md-search-highlight-current {
            background: transparent;
            color: inherit;
        }

        /* Splitting these across a page break loses the reading order. */
        :root:not(.\(previewPrintClass)) pre,
        :root:not(.\(previewPrintClass)) blockquote,
        :root:not(.\(previewPrintClass)) table,
        :root:not(.\(previewPrintClass)) figure,
        :root:not(.\(previewPrintClass)) .md-frontmatter,
        :root:not(.\(previewPrintClass)) .markdown-alert {
            break-inside: avoid;
        }
        :root:not(.\(previewPrintClass)) tr,
        :root:not(.\(previewPrintClass)) li { break-inside: avoid; }
        :root:not(.\(previewPrintClass)) h1,
        :root:not(.\(previewPrintClass)) h2,
        :root:not(.\(previewPrintClass)) h3,
        :root:not(.\(previewPrintClass)) h4,
        :root:not(.\(previewPrintClass)) h5,
        :root:not(.\(previewPrintClass)) h6 { break-after: avoid; }
        :root:not(.\(previewPrintClass)) pre {
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        /* Inner scrollers can't scroll on paper — let them wrap instead of
           clipping their overflow. */
        :root:not(.\(previewPrintClass)) .md-code-wrap,
        :root:not(.\(previewPrintClass)) .md-table-scroll,
        :root:not(.\(previewPrintClass)) table,
        :root:not(.\(previewPrintClass)) pre {
            overflow: visible !important;
        }
        :root:not(.\(previewPrintClass)) img,
        :root:not(.\(previewPrintClass)) svg {
            max-width: 100% !important;
            height: auto;
        }
        /* Anything wider than the printable area makes WebKit shrink the whole
           document to fit, which silently overrides the chosen point size — a
           request for 18pt came out at ~15pt. Keep every block inside the
           measure so the size stays honest. */
        :root:not(.\(previewPrintClass)) body { overflow-wrap: break-word; }
        :root:not(.\(previewPrintClass)) table { width: 100%; }
        :root:not(.\(previewPrintClass)) th,
        :root:not(.\(previewPrintClass)) td { overflow-wrap: anywhere; }
        :root:not(.\(previewPrintClass)) pre,
        :root:not(.\(previewPrintClass)) code { overflow-wrap: anywhere; }
    }

    """
}
