# Render extensions

Render extensions are small, compiled-in, individually toggleable Markdown
enhancements (currently Colorful headings and Collapsible headings) — not
installable plugins: app and Quick Look run the same registry, with only
vendor loading mode differing.

Mermaid, Math, and Callout are separate, unconditional built-ins. They
predate this registry, render directly from `MarkdownHTML.render(...)`
(`md-preview/Rendering/MarkdownHTML.swift`), and are not user-toggleable —
they're not `MarkdownRenderExtension`s and don't appear in Settings →
Extensions.

## Lifecycle

`MarkdownHTML` converts Markdown to HTML, then runs `renderExtensions` in order from `md-preview/Rendering/MarkdownRenderExtension.swift`.

Each `MarkdownRenderExtension` has:

- `id` — stable renderer name.
- `transform(_:)` — returns HTML and whether extension became active.
- `assets(mode:)` — returns CSS and trusted JS only for active documents.

CSS is emitted in document `<head>`. JavaScript may run in `<head>` or after document body. Dynamic DOM work should register with `window.MdPreview.registerRenderer({ id, render })`; `render` runs after initial render and incremental updates.

## Add extension

1. Create `md-preview/Rendering/MarkdownHTML+Example.swift`:

```swift
import Foundation

nonisolated extension MarkdownHTML {
  struct ExampleExtension: MarkdownRenderExtension {
    let id = "example"

    func transform(_ context: RenderContext) -> RenderResult {
      let active = context.html.contains("example-marker")
      return RenderResult(html: context.html, active: active)
    }

    func assets(mode _: VendorLoading) -> RenderAssets {
      RenderAssets(css: ".example-marker { color: var(--link); }")
    }
  }
}
```

2. Add it to `renderExtensions` in pipeline order. Earlier transforms feed later ones.
3. Add file to Quick Look membership exceptions in `md-preview.xcodeproj/project.pbxproj` and create matching `tests/swift-tests/Sources/MarkdownHelpers/` symlink.
4. Test registry order, inactive documents emit no assets, and extension behavior. Run `swift test --package-path tests/swift-tests` and app build.

Keep extensions deterministic and stateless. Treat Markdown-derived HTML as untrusted; only compiled-in CSS and JavaScript belongs in `RenderAssets`.
