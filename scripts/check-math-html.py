#!/usr/bin/env python3
"""Static smoke checks for math (KaTeX) support in MarkdownHTML.swift."""
from pathlib import Path
import sys

source = Path("md-preview/MarkdownHTML.swift").read_text()
checks = {
    "extracts inline $...$ math": "inlineMathRegex" in source,
    "extracts block $$...$$ math": "blockMathRegex" in source,
    r"extracts inline \\(...\\) math": "parenthesizedInlineMathRegex" in source,
    r"extracts block \\[...\\] math": "bracketedBlockMathRegex" in source,
    "detects ```math fences": "codeFenceRegex" in source and 'info.language == "math"' in source,
    "skips math inside code spans/fences": "inlineCodeRegex" in source and "MdPreviewProtect" in source,
    "loads bundled KaTeX renderer": "Vendor/KaTeX" in source and "katex.min" in source,
    "does not load KaTeX from a CDN": "cdn.jsdelivr.net/npm/katex" not in source,
    "renders with katex.render": "katex.render" in source,
    "loads copy-tex extension": "copy-tex.min" in source,
    "styles math containers": ".math-display" in source,
    "renders inline math wrapper": 'class=\\"math math-inline\\"' in source,
    "unwraps block math from <p>": "mathTokenRegex" in source and "paragraph-wrapped block token" in source,
}
failed = [name for name, ok in checks.items() if not ok]
if failed:
    print("Math HTML checks failed:")
    for name in failed:
        print(f"- {name}")
    sys.exit(1)
print("Math HTML checks passed")
