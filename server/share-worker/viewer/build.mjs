// Assembles the web viewer into public/s/_viewer/, which the Worker serves
// as static assets. Vendor scripts come straight from the app's
// md-preview/Vendor, so the page runs the same versions the app ships.
//
// The page loads three files: boot.js, one stylesheet, and one script
// (DOMPurify, the app's renderers, and main.js with its modules). They sit
// in a folder named by a hash of their content, so browsers can cache them
// for good: a change gets a new folder, and the page names the new one.
import { build } from "esbuild";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { VIEWER_CSP } from "../src/viewer-csp.ts";

const here = dirname(fileURLToPath(import.meta.url));
const vendor = join(here, "../../../md-preview/Vendor");
const main = await build({
  entryPoints: [join(here, "main.js")],
  bundle: true,
  format: "iife",
  minify: true,
  target: "es2022",
  write: false,
});

const files = {
  "boot.js": readFileSync(join(here, "boot.js")),
  "viewer.css": Buffer.concat([readFileSync(join(here, "generated/markdown.css")), readFileSync(join(here, "viewer.css"))]),
  "viewer.js": Buffer.concat([
    readFileSync(join(vendor, "DOMPurify/purify.min.js")), Buffer.from("\n;\n"),
    readFileSync(join(here, "generated/renderers.js")), Buffer.from("\n;\n"),
    main.outputFiles[0].contents,
  ]),
};
for (const [folder, names] of Object.entries({
  DOMPurify: ["DOMPurify-LICENSE.txt"],
  Highlight: ["highlight.min.js", "Highlight-LICENSE.txt"],
  KaTeX: ["katex.min.js", "katex.min.css", "KaTeX-LICENSE.txt"],
})) {
  for (const name of names) files[`vendor/${name}`] = readFileSync(join(vendor, folder, name));
}

const hash = createHash("sha256");
for (const [name, bytes] of Object.entries(files)) hash.update(name).update(bytes);
const version = hash.digest("hex").slice(0, 12);

const root = join(here, "../public");
const out = join(root, "s/_viewer");
rmSync(root, { recursive: true, force: true });
mkdirSync(join(out, version, "vendor"), { recursive: true });
for (const [name, bytes] of Object.entries(files)) writeFileSync(join(out, version, name), bytes);

// The Worker streams the envelope in at the marker (src/index.ts).
const page = readFileSync(join(here, "index.html"), "utf8").replaceAll("{{version}}", version);
if (page.split("<!--mdp-envelope-->").length !== 2) throw new Error("index.html needs exactly one <!--mdp-envelope-->");
writeFileSync(join(out, "index.html"), page);

// Opening the page file directly gets the same lockdown as /s/<id>.
writeFileSync(join(root, "_headers"), `/s/_viewer/index.html
  Content-Security-Policy: ${VIEWER_CSP}
  X-Frame-Options: DENY

/s/_viewer/${version}/*
  Cache-Control: public, max-age=31536000, immutable
`);
