//
//  MarkdownHTML+CollapsibleHeaders.swift
//  md-preview
//  Click-to-collapse heading render extension.
//

import Foundation

nonisolated extension MarkdownHTML {
  static let collapsibleHeadersStylesheet = """
    .markdown-body > .mdp-collapsible-heading {
      position: relative;
      padding-inline-start: 26px;
    }
    .markdown-body > .mdp-collapsible-heading > .mdp-collapse-toggle {
      position: absolute;
      inset-inline-start: 0;
      top: 50%;
      width: 18px;
      height: 18px;
      margin: 0;
      padding: 0;
      border: none;
      border-radius: 4px;
      background: transparent;
      appearance: none;
      transform: translateY(-50%);
      cursor: pointer;
      transition: background 0.15s ease;
    }
    .markdown-body > .mdp-collapsible-heading > .mdp-collapse-toggle:hover,
    .markdown-body > .mdp-collapsible-heading > .mdp-collapse-toggle:focus-visible {
      background: color-mix(in srgb, var(--text) 7%, transparent);
    }
    .markdown-body > .mdp-collapsible-heading > .mdp-collapse-toggle::after {
      content: "";
      position: absolute;
      inset-inline-start: 6px;
      top: calc(50% - 3px);
      width: 5px;
      height: 5px;
      border-right: 1px solid color-mix(in srgb, var(--text) 55%, transparent);
      border-bottom: 1px solid color-mix(in srgb, var(--text) 55%, transparent);
      transform: rotate(45deg);
      transition: transform 0.15s ease;
    }
    .markdown-body > .mdp-collapsible-heading[data-mdp-collapsed="true"] > .mdp-collapse-toggle::after {
      transform: rotate(-45deg);
    }
    /* Collapsing is a viewing convenience, not a redaction: printed and
       exported documents show every section regardless of on-screen state. */
    @media screen {
      .markdown-body > .mdp-collapsed-section {
        display: none;
      }
    }
    @media print {
      .markdown-body > .mdp-collapsible-heading > .mdp-collapse-toggle {
        display: none;
      }
    }
    """

  static let collapsibleHeadersScript = """
    <script>
    (() => {
      const headingSelector = [
        'article.markdown-body > h1',
        'article.markdown-body > h2',
        'article.markdown-body > h3',
        'article.markdown-body > h4',
        'article.markdown-body > h5',
        'article.markdown-body > h6'
      ].join(',');

      function headingLevel(heading) {
        return Number(heading.tagName.slice(1));
      }

      function sectionNodes(heading) {
        const level = headingLevel(heading);
        const nodes = [];
        let node = heading.nextElementSibling;
        while (node) {
          if (/^H[1-6]$/.test(node.tagName) && headingLevel(node) <= level) break;
          nodes.push(node);
          node = node.nextElementSibling;
        }
        return nodes;
      }

      // A heading's own collapsed flag only says whether ITS content should
      // hide; whether the heading and its content are actually visible also
      // depends on any ancestor (lower-numbered-level, still-open) heading
      // being collapsed. Walking every heading once in document order with a
      // stack of currently-collapsed ancestors reconciles both in one pass,
      // instead of the previous per-toggle sibling walk that let expanding a
      // parent blow away a nested heading's own collapsed state.
      function reconcileVisibility(root) {
        const stack = [];
        for (const heading of root.querySelectorAll(headingSelector)) {
          const level = headingLevel(heading);
          while (stack.length && stack[stack.length - 1] >= level) stack.pop();
          const hiddenByAncestor = stack.length > 0;
          const collapsedHere = heading.dataset.mdpCollapsed === 'true';
          heading.classList.toggle('mdp-collapsed-section', hiddenByAncestor);
          heading.querySelector(':scope > .mdp-collapse-toggle')
            ?.setAttribute('aria-expanded', collapsedHere ? 'false' : 'true');
          for (const node of sectionNodes(heading)) {
            node.classList.toggle('mdp-collapsed-section', hiddenByAncestor || collapsedHere);
          }
          if (collapsedHere) stack.push(level);
        }
        window.MdPreviewHost?.pushHeight?.();
      }

      function toggle(heading) {
        heading.dataset.mdpCollapsed = heading.dataset.mdpCollapsed === 'true' ? 'false' : 'true';
        reconcileVisibility(document);
      }

      // MdPreview.update morphs or replaces the article without knowing
      // about collapsed-heading state: the incoming HTML never carries the
      // toggle button or data-mdp-collapsed, so a plain re-setup would treat
      // every heading as freshly expanded. Snapshot by heading id (stable
      // across a re-render of the same document) just before the swap so
      // setup() can restore it below instead of defaulting to expanded.
      let collapsedHeadingIDs = new Set();

      function captureCollapsedState(root) {
        collapsedHeadingIDs = new Set(
          Array.from(root.querySelectorAll(headingSelector))
            .filter((heading) => heading.id && heading.dataset.mdpCollapsed === 'true')
            .map((heading) => heading.id)
        );
      }

      function setup(root) {
        for (const heading of root.querySelectorAll(headingSelector)) {
          if (heading.dataset.mdpCollapseReady === 'true') continue;
          heading.dataset.mdpCollapseReady = 'true';
          heading.dataset.mdpCollapsed = collapsedHeadingIDs.has(heading.id) ? 'true' : 'false';
          heading.classList.add('mdp-collapsible-heading');

          const toggleButton = document.createElement('button');
          toggleButton.type = 'button';
          toggleButton.className = 'mdp-collapse-toggle';
          toggleButton.setAttribute('aria-label', `Toggle "${heading.textContent.trim()}" section`);
          toggleButton.addEventListener('click', () => toggle(heading));
          heading.prepend(toggleButton);
        }
        reconcileVisibility(root);
      }

      window.MdPreview?.registerRenderer({
        id: 'collapsible-headings',
        beforeUpdate: captureCollapsedState,
        render: setup
      });
      setup(document);
    })();
    </script>
    """

  struct CollapsibleHeadersExtension: MarkdownRenderExtension {
    let id = "collapsible-headings"

    func transform(_ context: RenderContext) -> RenderResult {
      let hasHeading = context.html.range(
        of: #"<h[1-6]\b"#,
        options: .regularExpression
      ) != nil
      return RenderResult(html: context.html, active: hasHeading)
    }

    func assets(mode _: VendorLoading) -> RenderAssets {
      RenderAssets(css: collapsibleHeadersStylesheet, bodyJS: collapsibleHeadersScript)
    }
  }
}
