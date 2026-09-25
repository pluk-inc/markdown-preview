//
//  MarkdownHTML+ColorfulHeaders.swift
//  md-preview
//
//  Colorful heading render extension.
//

import Foundation

nonisolated extension MarkdownHTML {
  static let colorfulHeaderStylesheet = """
    :root {
      --mdp-heading-h1: #d14f6a;
      --mdp-heading-h2: #b97839;
      --mdp-heading-h3: #548e6f;
      --mdp-heading-h4: #527ecb;
      --mdp-heading-h5: #7665c4;
      --mdp-heading-h6: #9d7145;
    }
    :root[data-mdp-color-scheme="dark"] {
      --mdp-heading-h1: #ff7893;
      --mdp-heading-h2: #e7a45f;
      --mdp-heading-h3: #77bd94;
      --mdp-heading-h4: #7da9ff;
      --mdp-heading-h5: #a99aff;
      --mdp-heading-h6: #d5a575;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-mdp-color-scheme="light"]) {
        --mdp-heading-h1: #ff7893;
        --mdp-heading-h2: #e7a45f;
        --mdp-heading-h3: #77bd94;
        --mdp-heading-h4: #7da9ff;
        --mdp-heading-h5: #a99aff;
        --mdp-heading-h6: #d5a575;
      }
    }
    .markdown-body h1 { color: var(--mdp-heading-h1); }
    .markdown-body h2 { color: var(--mdp-heading-h2); }
    .markdown-body h3 { color: var(--mdp-heading-h3); }
    .markdown-body h4 { color: var(--mdp-heading-h4); }
    .markdown-body h5 { color: var(--mdp-heading-h5); }
    .markdown-body h6 { color: var(--mdp-heading-h6); }
    """

  struct ColorfulHeadersExtension: MarkdownRenderExtension {
    let id = "colorful-headings"

    func transform(_ context: RenderContext) -> RenderResult {
      let hasHeading = context.html.range(
        of: #"<h[1-6]\b"#,
        options: .regularExpression
      ) != nil
      return RenderResult(html: context.html, active: hasHeading)
    }

    func assets(mode _: VendorLoading) -> RenderAssets {
      RenderAssets(css: colorfulHeaderStylesheet)
    }
  }
}
