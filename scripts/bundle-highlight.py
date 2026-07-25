#!/usr/bin/env python3
"""Bundle highlight.js into self-contained vendor files.

Downloads highlight.min.js (the common-languages bundle from
@highlightjs/cdn-assets), the github + github-dark themes, and the LICENSE
from jsDelivr. Adds the third-party Terraform/HCL grammar, then combines the
two themes into a single CSS that gates dark rules behind
`prefers-color-scheme: dark`, so a single stylesheet covers both appearances.

Run from repo root:  ./scripts/bundle-highlight.py [VERSION]
"""
import re
import subprocess
import sys
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "11.10.0"
CDN = f"https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@{VERSION}"
LICENSE_URL = f"https://raw.githubusercontent.com/highlightjs/highlight.js/{VERSION}/LICENSE"
TERRAFORM_VERSION = "1.0.7"
TERRAFORM_CDN = (
    "https://cdn.jsdelivr.net/npm/@taga3s/highlightjs-terraform@"
    f"{TERRAFORM_VERSION}"
)
DEST = Path("md-preview/Vendor/Highlight")


def fetch(url: str) -> bytes:
    return subprocess.run(
        ["curl", "-fsSL", url],
        check=True,
        capture_output=True,
    ).stdout


def main() -> int:
    DEST.mkdir(parents=True, exist_ok=True)

    js = fetch(f"{CDN}/highlight.min.js")
    light = fetch(f"{CDN}/styles/github.min.css").decode("utf-8").strip()
    dark = fetch(f"{CDN}/styles/github-dark.min.css").decode("utf-8").strip()
    license_text = fetch(LICENSE_URL)
    terraform = fetch(f"{TERRAFORM_CDN}/dist/index.js").decode("utf-8").strip()
    terraform_license = fetch(f"{TERRAFORM_CDN}/LICENSE")

    # The maintained package publishes an ES module. Its definitions are
    # otherwise browser-ready, so remove the pinned release's export footer
    # before wrapping and registering the definer in the classic script.
    export_footer = """
export default function (hljs) {
    hljs.registerLanguage("terraform", hljsDefineTerraform);
}
export { hljsDefineTerraform as definer };
""".strip()
    if not terraform.endswith(export_footer):
        raise RuntimeError("Unexpected @taga3s/highlightjs-terraform export shape")
    terraform = terraform.removesuffix(export_footer).rstrip()

    # Keep the official UMD bundle usable both as a browser global and through
    # CommonJS. Isolate the grammar in an IIFE and pass the already-created
    # Highlight.js instance in before registering its terraform/tf/hcl aliases.
    terraform_addon = f"""
;(function(root, core) {{
{terraform}
var instance = root.hljs || core;
if (instance) instance.registerLanguage('terraform', hljsDefineTerraform);
}})(typeof globalThis !== 'undefined' ? globalThis : this,
   typeof module !== 'undefined' ? module.exports : null);
"""
    js += terraform_addon.encode("utf-8")

    combined_license = (
        license_text.rstrip()
        + b"\n\n---\n\n"
        + f"@taga3s/highlightjs-terraform {TERRAFORM_VERSION}\n\n".encode("utf-8")
        + terraform_license
    )

    # Strip leading comment headers so the merged stylesheet stays compact.
    light = re.sub(r"^/\*![\s\S]*?\*/\s*", "", light)
    dark = re.sub(r"^/\*![\s\S]*?\*/\s*", "", dark)

    # Cancel the theme background — the host page already paints a rounded
    # `pre` background; per-token colors come through fine without it.
    combined = (
        f"{light}\n"
        f"@media (prefers-color-scheme: dark) {{ {dark} }}\n"
        ".hljs { background: transparent !important; padding: 0 !important; }\n"
    )

    (DEST / "highlight.min.js").write_bytes(js)
    (DEST / "highlight.min.css").write_text(combined, encoding="utf-8")
    (DEST / "Highlight-LICENSE.txt").write_bytes(combined_license)
    # File name distinct so the synced-root-group resource copy doesn't
    # collide with md-preview/Vendor/KaTeX/VERSION in the bundle output.
    (DEST / "Highlight-VERSION").write_text(VERSION + "\n", encoding="utf-8")

    print(f"highlight.js {VERSION} bundled to {DEST}/")
    print(f"  highlight.min.js     {(DEST / 'highlight.min.js').stat().st_size:>9} bytes")
    print(f"  highlight.min.css    {(DEST / 'highlight.min.css').stat().st_size:>9} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
