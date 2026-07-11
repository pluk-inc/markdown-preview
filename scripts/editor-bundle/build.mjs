import { build } from "esbuild"
import { writeFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"

const outputURL = new URL("../../md-preview/Vendor/CodeMirror/mdedit.min.js", import.meta.url)
const result = await build({
  entryPoints: [fileURLToPath(new URL("entry-cm.js", import.meta.url))],
  bundle: true,
  minify: true,
  format: "iife",
  write: false,
})

// Some dependency completion snippets contain whitespace-only physical lines.
// Normalize line endings so the checked-in generated bundle passes diff checks
// and is byte-for-byte reproducible through `npm run build`.
const output = result.outputFiles[0].text.replace(/[ \t]+$/gm, "")
await writeFile(outputURL, output)
