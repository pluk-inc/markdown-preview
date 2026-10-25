// Assembles the web viewer into public/s/_viewer/, which the Worker serves
// as static assets. Vendor scripts come straight from the app's
// md-preview/Vendor, so the page runs the same versions the app ships.
//
// The page loads three files: boot.js, one stylesheet, and one script
// (DOMPurify, the app's renderers, and main.js with its modules). Each file
// in assets/ carries a hash of its content in its name, so browsers can
// cache it for good: a changed file gets a new name, and an unchanged one
// (KaTeX across most deploys) keeps its name and stays cached.
import { build } from "esbuild";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { VIEWER_CSP } from "../src/viewer-csp.ts";
import { ENVELOPE_MARKER } from "../src/viewer-page.ts";

const here = dirname(fileURLToPath(import.meta.url));
const vendor = join(here, "../../../md-preview/Vendor");
const root = join(here, "../public");
const out = join(root, "s/_viewer");
rmSync(root, { recursive: true, force: true });
mkdirSync(join(out, "assets"), { recursive: true });

/** Writes `name` as name.<hash>.ext under assets/ and returns its URL. */
function emit(name, bytes) {
  const hash = createHash("sha256").update(bytes).digest("hex").slice(0, 12);
  const dot = name.indexOf(".");
  const file = `${name.slice(0, dot)}.${hash}${name.slice(dot)}`;
  writeFileSync(join(out, "assets", file), bytes);
  return `/s/_viewer/assets/${file}`;
}

// Loaded by main.js only for documents with code or math.
const vendorURLs = {
  "highlight.min.js": emit("highlight.min.js", readFileSync(join(vendor, "Highlight/highlight.min.js"))),
  "katex.min.js": emit("katex.min.js", readFileSync(join(vendor, "KaTeX/katex.min.js"))),
  "katex.min.css": emit("katex.min.css", readFileSync(join(vendor, "KaTeX/katex.min.css"))),
};
for (const license of ["DOMPurify/DOMPurify-LICENSE.txt", "Highlight/Highlight-LICENSE.txt", "KaTeX/KaTeX-LICENSE.txt"]) {
  writeFileSync(join(out, license.split("/")[1]), readFileSync(join(vendor, license)));
}

const main = await build({
  entryPoints: [join(here, "main.js")],
  bundle: true,
  format: "iife",
  minify: true,
  target: "es2022",
  define: { VENDOR_URLS: JSON.stringify(vendorURLs) },
  write: false,
});

const pageURLs = {
  "boot.js": emit("boot.js", readFileSync(join(here, "boot.js"))),
  "viewer.css": emit("viewer.css", Buffer.concat([
    readFileSync(join(here, "generated/markdown.css")), readFileSync(join(here, "viewer.css")),
  ])),
  "viewer.js": emit("viewer.js", Buffer.concat([
    readFileSync(join(vendor, "DOMPurify/purify.min.js")), Buffer.from("\n;\n"),
    readFileSync(join(here, "generated/renderers.js")), Buffer.from("\n;\n"),
    main.outputFiles[0].contents,
  ])),
  // The app icon (viewer/icons, made from md-preview/AppIcon.icon).
  "favicon.png": emit("favicon.png", readFileSync(join(here, "icons/favicon.png"))),
  "apple-touch-icon.png": emit("apple-touch-icon.png", readFileSync(join(here, "icons/apple-touch-icon.png"))),
};

const page = readFileSync(join(here, "index.html"), "utf8").replace(/\{\{([\w.-]+)\}\}/g, (_, name) => {
  if (!pageURLs[name]) throw new Error(`index.html names an unknown file: ${name}`);
  return pageURLs[name];
});
if (page.split(ENVELOPE_MARKER).length !== 2) throw new Error(`index.html needs exactly one ${ENVELOPE_MARKER}`);
writeFileSync(join(out, "index.html"), page);

// Opening the page file directly gets the same lockdown as /s/<id>.
writeFileSync(join(root, "_headers"), `/s/_viewer/index.html
  Content-Security-Policy: ${VIEWER_CSP}
  X-Frame-Options: DENY

/s/_viewer/assets/*
  Cache-Control: public, max-age=31536000, immutable
`);
