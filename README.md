<h1 align="center">Markdown Preview</h1>

<p align="center">
  <img src="docs/markdown-logo.svg" width="128" alt="Markdown Preview logo" />
</p>

<p align="center">
  A fast, native macOS app for reading Markdown files.
</p>

<p align="center"><img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2015%2B-blue" />&nbsp;<img alt="Swift" src="https://img.shields.io/badge/swift-6.0-orange" />&nbsp;<img alt="License" src="https://img.shields.io/badge/license-MIT-green" />&nbsp;<img alt="Latest release" src="https://img.shields.io/github/v/release/pluk-inc/markdown-preview" />&nbsp;<img alt="Homebrew cask" src="https://img.shields.io/homebrew/cask/v/markdown-preview" /></p>

---

> Drop a `.md` on the icon (or set Markdown Preview as your default handler) and get a clean, scrollable preview with a real document outline — no Electron, no browser tab.

## Installation

Markdown Preview is available in the official [Homebrew cask repository](https://formulae.brew.sh/cask/markdown-preview):

```sh
brew install --cask markdown-preview
```

Or grab the latest signed and notarized DMG from the [Releases](https://github.com/pluk-inc/markdown-preview/releases) page.

## Screenshots

<p align="center">
  <img src="docs/screenshot-main.png" width="820" alt="Main window with document outline sidebar" />
</p>

<p align="center">
  <em>Edit Markdown directly with a native formatting toolbar:</em>
</p>

<p align="center">
  <img src="docs/screenshot-edit-mode.png" width="820" alt="Edit Mode with document outline and Markdown formatting toolbar" />
</p>

<p align="center">
  <em>Quick Look preview — spacebar a <code>.md</code> in Finder:</em>
</p>

<p align="center">
  <img src="docs/screenshot-quicklook.png" width="640" alt="Quick Look preview from Finder" />
</p>

<p align="center">
  <em>Customize the toolbar — drag in Print, Copy, Zoom and the rest from <em>View → Customize Toolbar…</em></em>
</p>

<p align="center">
  <img src="docs/screenshot-toolbar-customize.png" width="820" alt="Native macOS toolbar customization sheet showing draggable items" />
</p>

## Features

- **Native rendering** — `WKWebView` pipeline backed by [swift-markdown](https://github.com/swiftlang/swift-markdown), with heading anchors and link handling.
- **Edit Mode** — edit Markdown in place with a formatting toolbar for headings, emphasis, lists, quotes, code, and links. Toggle it from the toolbar or with <kbd>⌘E</kbd>, then save with <kbd>⌘S</kbd>.
- **Mermaid diagrams** — fenced `mermaid` code blocks render as diagrams in both the app and Quick Look previews, using a bundled renderer so previews work offline without a CDN request.
- **Math equations** — LaTeX inline (`$x_1 + x_2$`), display (`$$\int_0^1 x^2\,dx$$`), and fenced `math` blocks render with a bundled KaTeX. Selecting a rendered formula and copying yields the original LaTeX source (via the official `copy-tex` extension).
- **Document outline** — sidebar TOC that mirrors your headings; click to jump.
- **Inspector panel** — toggleable side panel with file metadata.
- **In-document search** — toolbar search field plus standard <kbd>⌘F</kbd> / <kbd>⌘G</kbd> / <kbd>⌘⇧G</kbd> for next/previous match.
- **Open With** — switch to your real editor (VS Code, Cursor, Zed, Sublime, BBEdit, Nova, CotEditor, TextMate, MacVim, Xcode, TextEdit) without leaving the preview. The list filters to apps that actually declare an editor role for Markdown, and remembers your pick.
- **Open in LLM** — send the current Markdown file to Codex, Claude, or ChatGPT from the toolbar. Supported apps open with file or folder context where possible, with a copy-and-open fallback for longer prompts.
- **Text zoom** — bump preview text up or down with trackpad pinch, the toolbar's <kbd>A A</kbd> control, or <kbd>⌘+</kbd> / <kbd>⌘−</kbd> / <kbd>⌘0</kbd>. Discrete Safari-style stops from 50% to 300%.
- **Customizable toolbar** — drag in the items you actually use (Print, Copy, Zoom, Sidebar, Open With, Inspector, Share, Search) via *View → Customize Toolbar…* Standard AppKit affordance, your layout sticks across launches.
- **Share = copy the source** — the share toolbar feeds the picker the Markdown text itself, so **Copy** writes the raw source to the clipboard (great for pasting into ChatGPT / Claude), and Mail, Messages, and Notes get the content in the body instead of a file URL.
- **Quick Look extension** — system-wide `.md` previews from Finder spacebar, Spotlight, and Mail attachments without launching the app.
- **Command line tools** — install `mdp`, `md-preview`, and `markdown-preview` from the app menu, then open files or folders from any shell with commands like `mdp README.md` or `mdp .`.
- **Default handler** — offers to register itself as the default `.md` opener on first launch.

## Supported file types

`.md`, `.markdown`, `.mdown`, `.txt`
UTI: `net.daringfireball.markdown`

## Requirements

- macOS 15 or later
- Apple Silicon or Intel

## Building from source

```sh
git clone git@github.com:pluk-inc/markdown-preview.git
cd markdown-preview
open markdown-preview.xcodeproj
```

Build and run the `markdown-preview` scheme. Swift Package Manager will resolve [Sparkle](https://github.com/sparkle-project/Sparkle), [Sentry](https://github.com/getsentry/sentry-cocoa), and [swift-markdown](https://github.com/swiftlang/swift-markdown) on first build.

### Crash reporting

Release builds submit native crash reports to the `pluk-inc/markdown-preview` Sentry project. The integration does not collect performance traces, session data, breadcrumbs, network requests, user information, document contents, or file paths. Users can turn reporting off directly from Markdown Preview > Send Anonymous Crash Reports; on later launches, the Sentry SDK will not initialize at all.

The committed DSN is a public client key. Release archives upload the app dSYM with `sentry-cli`; authenticate locally with `sentry-cli login` and keep that authentication token outside the repository.

## Project layout

```
md-preview/         Main app target (AppKit, WKWebView)
quick-look/         Quick Look extension (.appex)
scripts/            Release & rollback automation
Version.xcconfig    Marketing & build version (single source of truth)
appcast.xml         Sparkle update feed
```

## Releasing

Releases are driven by [Amore](http://amore.computer/) — it handles building, code signing, notarization, DMG creation, S3 upload, and Sparkle appcast publishing in one shot.

Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Version.xcconfig`, then:

```sh
./scripts/release.sh
```

Use `./scripts/rollback-release.sh` to revert the appcast pointer if a release misbehaves.

## Contributing

Pull requests are welcome. For larger changes, please open an issue first to discuss what you'd like to change.

1. Fork the repo and create your branch from `main`.
2. Run the app and verify the change end-to-end (UI changes need a manual smoke test — there's no UI test suite yet).
3. Keep PRs focused; one logical change per PR.
4. Match the existing Swift style (no formatter is enforced; mirror nearby code).

<h2 align="center" style="color: #8a8a8a;">Special Sponsor</h2>

<br />

<p align="center">
  <a href="https://pluk.sh">
    <img src="docs/sponsors/pluk-logo.png" height="54" alt="Pluk" />
  </a>
  &nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://amore.computer">
    <img src="docs/sponsors/amore-logo.png" height="54" alt="Amore" />
  </a>
</p>

## Acknowledgments
- [Amore](http://amore.computer/) — MacOS release automation (signing, notarization, DMG, hosting, appcast)
- [swift-markdown](https://github.com/swiftlang/swift-markdown) — Markdown parser (Apple, cmark-gfm-backed)
- [Mermaid](https://mermaid.js.org/) — Bundled diagram renderer for `mermaid` fenced code blocks
- [KaTeX](https://katex.org/) — Bundled math typesetter for inline `$…$`, display `$$…$$`, and ` ```math ` blocks
- [Sparkle](https://sparkle-project.org) — Auto-update framework
- [Sentry](https://sentry.io) — Privacy-filtered native crash reporting
- [LottieFiles](https://lottiefiles.com/) — Animated README logo

## License

[MIT](LICENSE)
