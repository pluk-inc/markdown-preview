#!/usr/bin/env python3
"""Static smoke checks for Mermaid diagram support in the MarkdownHTML renderer."""
from pathlib import Path
import sys

source = "\n".join(
    Path(path).read_text()
    for path in (
        "md-preview/Rendering/MarkdownHTML+Mermaid.swift",
        "md-preview/Rendering/MarkdownHTML+Stylesheet.swift",
    )
)
checks = {
    "detects mermaid code fences": "language-mermaid" in source and "mermaidRegex" in source,
    "loads bundled Pele renderer": "Vendor/Pele" in source and "pele.global" in source,
    "does not load a renderer from a CDN": "cdn.jsdelivr.net" not in source,
    "renders diagrams with Pele after page load": "pele.render" in source and "bootstrap" in source,
    "maps diagram colours to the theme": "--pele-fg: var(--text)" in source,
    "styles Mermaid containers": ".mermaid" in source,
    "centers rendered diagrams": (
        "justify-content: center" in source
        and "svg.setAttribute('preserveAspectRatio', 'xMidYMid meet')" in source
        and "s.surface.style.transform" in source
    ),
    "toggles full-width diagrams": (
        'data-mm-act="width"' in source
        and "classList.toggle('mermaid-width-expanded')" in source
        and ".mermaid-figure.mermaid-width-expanded" in source
    ),
    "opens diagram popup with measured size": (
        'data-mm-act="popup"' in source
        and "kind: 'mermaidPopup'" in source
        and "openPopup" in source
    ),
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("Mermaid HTML checks failed:")
    for name in failed:
        print(f"- {name}")
    sys.exit(1)
print("Mermaid HTML checks passed")
