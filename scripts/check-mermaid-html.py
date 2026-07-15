#!/usr/bin/env python3
"""Static smoke checks for Mermaid support in MarkdownHTML.swift."""
from pathlib import Path
import sys

source = Path("md-preview/MarkdownHTML.swift").read_text()
checks = {
    "detects mermaid code fences": "language-mermaid" in source and "mermaidRegex" in source,
    "loads bundled Mermaid renderer": "Vendor/Mermaid" in source and "mermaid.min" in source,
    "does not load Mermaid from a CDN": "cdn.jsdelivr.net/npm/mermaid" not in source,
    "initializes Mermaid after page load": "mermaid.initialize" in source and "mermaid.run" in source,
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
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("Mermaid HTML checks failed:")
    for name in failed:
        print(f"- {name}")
    sys.exit(1)
print("Mermaid HTML checks passed")
