#!/usr/bin/env python3
"""Bundle KaTeX into self-contained vendor files.

Downloads katex.min.js, katex.min.css, copy-tex.min.js, LICENSE, and all woff2
fonts from jsDelivr, then rewrites the CSS so every font URL is replaced with a
base64 data: URI. Drops legacy woff/ttf fallbacks (WKWebView supports woff2).

Run from repo root:  ./scripts/bundle-katex.py [VERSION]
"""
import base64
import re
import subprocess
import sys
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "0.16.45"
CDN = f"https://cdn.jsdelivr.net/npm/katex@{VERSION}/dist"
LICENSE_URL = f"https://raw.githubusercontent.com/KaTeX/KaTeX/v{VERSION}/LICENSE"
DEST = Path("md-preview/Vendor/KaTeX")


def fetch(url: str) -> bytes:
    return subprocess.run(
        ["curl", "-fsSL", url],
        check=True,
        capture_output=True,
    ).stdout


def main() -> int:
    DEST.mkdir(parents=True, exist_ok=True)

    js = fetch(f"{CDN}/katex.min.js")
    copy_tex = fetch(f"{CDN}/contrib/copy-tex.min.js")
    css = fetch(f"{CDN}/katex.min.css").decode("utf-8")
    license_text = fetch(LICENSE_URL)

    fonts = sorted(set(re.findall(r"fonts/(KaTeX_[A-Za-z0-9_-]+)\.woff2", css)))
    if not fonts:
        print("No KaTeX font references found in CSS — aborting.", file=sys.stderr)
        return 1

    encoded: dict[str, str] = {}
    for name in fonts:
        data = fetch(f"{CDN}/fonts/{name}.woff2")
        encoded[name] = base64.b64encode(data).decode("ascii")

    def replace_src(match: re.Match[str]) -> str:
        woff2 = match.group(1)
        return (
            f'src:url(data:font/woff2;base64,{encoded[woff2]}) format("woff2")'
        )

    inlined = re.sub(
        r'src:url\(fonts/(KaTeX_[A-Za-z0-9_-]+)\.woff2\)\s*format\("woff2"\)'
        r'(?:,url\(fonts/[^)]+\)\s*format\("[^"]+"\))*',
        replace_src,
        css,
    )

    (DEST / "katex.min.js").write_bytes(js)
    (DEST / "copy-tex.min.js").write_bytes(copy_tex)
    (DEST / "katex.min.css").write_text(inlined, encoding="utf-8")
    # File name is intentionally distinct so it does not collide with
    # the other vendor license files in the bundle output directory.
    (DEST / "KaTeX-LICENSE.txt").write_bytes(license_text)
    (DEST / "VERSION").write_text(VERSION + "\n", encoding="utf-8")

    print(f"KaTeX {VERSION} bundled to {DEST}/")
    print(f"  katex.min.js     {(DEST / 'katex.min.js').stat().st_size:>9} bytes")
    print(f"  katex.min.css    {(DEST / 'katex.min.css').stat().st_size:>9} bytes (fonts inlined)")
    print(f"  copy-tex.min.js  {(DEST / 'copy-tex.min.js').stat().st_size:>9} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
