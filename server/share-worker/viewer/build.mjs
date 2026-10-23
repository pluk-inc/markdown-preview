// Assembles the web viewer into public/s/_viewer/, which the Worker serves
// as static assets. Vendor scripts come straight from the app's
// md-preview/Vendor, so the page runs the same versions the app ships.
import { cpSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { VIEWER_CSP } from "../src/viewer-csp.ts";

const here = dirname(fileURLToPath(import.meta.url));
const vendor = join(here, "../../../md-preview/Vendor");
const out = join(here, "../public/s/_viewer");

rmSync(join(here, "../public"), { recursive: true, force: true });
mkdirSync(join(out, "vendor"), { recursive: true });

for (const file of ["index.html", "main.js", "share-crypto.js", "payload.js", "strings.js", "viewer.css"]) {
  cpSync(join(here, file), join(out, file));
}
cpSync(join(here, "generated"), join(out, "generated"), { recursive: true });

for (const [folder, files] of Object.entries({
  DOMPurify: ["purify.min.js", "DOMPurify-LICENSE.txt"],
  Highlight: ["highlight.min.js", "Highlight-LICENSE.txt"],
  KaTeX: ["katex.min.js", "katex.min.css", "KaTeX-LICENSE.txt"],
})) {
  for (const file of files) cpSync(join(vendor, folder, file), join(out, "vendor", file));
}

// Opening the page file directly gets the same lockdown as /s/<id>.
writeFileSync(join(here, "../public/_headers"), `/s/_viewer/index.html
  Content-Security-Policy: ${VIEWER_CSP}
  X-Frame-Options: DENY
`);
