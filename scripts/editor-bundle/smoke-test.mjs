// Headless smoke test for the bundled editor: constructs the editor in
// jsdom, checks the join decorations don't throw, and verifies the buffer
// round-trips byte-faithfully. Run with `node smoke-test.mjs`.
import { JSDOM } from "jsdom"
import { readFileSync } from "node:fs"

const dom = new JSDOM("<!doctype html><body><div id='editor'></div></body>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
})
globalThis.window = dom.window
globalThis.document = dom.window.document
globalThis.navigator = dom.window.navigator
for (const key of ["MutationObserver", "ResizeObserver", "requestAnimationFrame",
                   "cancelAnimationFrame", "getComputedStyle", "Range", "Text", "Node",
                   "HTMLElement", "Element", "Document", "DOMParser", "Selection", "Window"]) {
  if (dom.window[key] && !globalThis[key]) globalThis[key] = dom.window[key]
}
if (!globalThis.ResizeObserver) {
  globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  dom.window.ResizeObserver = globalThis.ResizeObserver
}
if (!dom.window.Range.prototype.getClientRects) {
  dom.window.Range.prototype.getClientRects = () => []
}
if (!dom.window.Range.prototype.getBoundingClientRect) {
  dom.window.Range.prototype.getBoundingClientRect = () => ({
    left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0,
  })
}

const bundle = readFileSync(new URL("../../md-preview/Vendor/CodeMirror/mdedit.min.js", import.meta.url), "utf8")
dom.window.eval(bundle)

const doc = readFileSync(new URL("../../samples/full.md", import.meta.url), "utf8")

let failures = 0
const check = (label, ok) => {
  console.log((ok ? "PASS" : "FAIL") + "  " + label)
  if (!ok) failures++
}

let editor
try {
  editor = dom.window.MDEditor.create(dom.window.document.getElementById("editor"), doc, {})
  check("editor constructs without throwing", true)
} catch (error) {
  check("editor constructs without throwing (" + error + ")", false)
}

if (editor) {
  check("round-trip is byte-faithful", editor.getMarkdown() === doc)
  const text = dom.window.document.querySelector(".cm-content")?.textContent ?? ""
  check("document text renders", text.includes("Sample Markdown Cheat Sheet"))
  editor.exec("bold")
  check("exec('bold') inserts markers", editor.getMarkdown().startsWith("****"))
}

const headingHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(headingHost)
const headingEditor = dom.window.MDEditor.create(headingHost, "### Stable heading", {})
check("unfocused leading heading source stays hidden",
  headingHost.querySelector(".cm-md-heading-source-hidden")?.textContent === "### ")
headingEditor.exec("h0")
check("Normal Text removes the heading marker",
  headingEditor.getMarkdown() === "Stable heading")
headingEditor.destroy()

const inactiveHeadingHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inactiveHeadingHost)
const inactiveHeadingEditor = dom.window.MDEditor.create(
  inactiveHeadingHost, "intro\n\n### Stable heading", {})
check("inactive heading source reserves its width",
  inactiveHeadingHost.querySelector(".cm-md-heading-source-hidden")?.textContent === "### ")
check("inactive heading line receives visual offset class",
  inactiveHeadingHost.querySelector(".cm-md-heading-inactive") != null)
check("blank source line before heading collapses",
  inactiveHeadingHost.querySelector(".cm-md-blank-before-heading") != null)
inactiveHeadingEditor.destroy()

const inlineCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inlineCodeHost)
const inlineCodeEditor = dom.window.MDEditor.create(
  inlineCodeHost, "before `highlight` after", {})
const inlineCodeSpans = inlineCodeHost.querySelectorAll(".cm-md-inline-code")
check("inline code renders as one styled content span",
  inlineCodeSpans.length === 1 && inlineCodeSpans[0].textContent === "highlight")
check("inactive inline code hides both backtick markers",
  inlineCodeHost.querySelector(".cm-content")?.textContent === "before highlight after")
inlineCodeEditor.destroy()

const emphasisHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(emphasisHost)
const emphasisEditor = dom.window.MDEditor.create(
  emphasisHost, "plain\n**bold text** and *italic text* and ~~struck text~~", {})
check("inactive strong emphasis keeps bold decoration",
  emphasisHost.querySelector(".cm-md-strong")?.textContent === "bold text")
check("inactive emphasis keeps italic decoration",
  emphasisHost.querySelector(".cm-md-emphasis")?.textContent === "italic text")
check("inactive strikethrough keeps decoration",
  emphasisHost.querySelector(".cm-md-strikethrough")?.textContent === "struck text")
emphasisEditor.select(10)
check("unfocused selection does not reveal strong markers",
  emphasisHost.querySelector(".cm-md-strong")?.textContent === "bold text")
emphasisEditor.destroy()

const setextHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(setextHost)
const setextEditor = dom.window.MDEditor.create(setextHost, "Stable heading\n=====", {})
check("Setext marker stays visible without editor focus",
  setextHost.querySelector(".cm-md-heading-source-hidden") == null
  && setextHost.textContent.includes("====="))
check("Setext source line uses collapsed overlay styling",
  setextHost.querySelector(".cm-md-setext-marker-line") != null
  && setextHost.querySelector(".cm-md-setext-source")?.textContent === "=====")
setextEditor.destroy()

const leadingCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(leadingCodeHost)
const leadingCodeEditor = dom.window.MDEditor.create(
  leadingCodeHost, "```javascript\nconst answer = 42\n```", {})
check("implicit initial cursor does not activate a leading code block",
  leadingCodeHost.querySelectorAll(".cm-md-code-fence-source-hidden").length === 2)
check("leading preview code block keeps syntax highlighting",
  leadingCodeHost.querySelector(".hl-keyword")?.textContent === "const")
leadingCodeEditor.select(18)
check("pointer click activates the code block",
  leadingCodeHost.querySelector(".cm-md-code-fence-source-hidden") == null)
check("activated code block remains syntax highlighted",
  leadingCodeHost.querySelector(".hl-keyword")?.textContent === "const")
leadingCodeEditor.destroy()

const inactiveCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inactiveCodeHost)
const inactiveCodeEditor = dom.window.MDEditor.create(
  inactiveCodeHost, "intro\n```javascript\nconst answer = 42\n```", {})
check("inactive code block hides both fence source lines",
  inactiveCodeHost.querySelectorAll(".cm-md-code-fence-source-hidden").length === 2)
check("inactive code block keeps syntax highlighting",
  inactiveCodeHost.querySelector(".hl-keyword")?.textContent === "const")
inactiveCodeEditor.destroy()

const legacyCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(legacyCodeHost)
const legacyCodeEditor = dom.window.MDEditor.create(
  legacyCodeHost, "intro\n```swift\nlet answer = 42\n```", {})
check("bundled legacy language support constructs",
  legacyCodeHost.querySelectorAll(".cm-md-code-fence-source-hidden").length === 2)
check("bundled legacy language stays syntax highlighted",
  legacyCodeHost.querySelector(".hl-keyword")?.textContent === "let")
legacyCodeEditor.destroy()

const mermaidHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(mermaidHost)
const mermaidEditor = dom.window.MDEditor.create(
  mermaidHost, "intro\n```mermaid\nflowchart LR\n  A --> B\n```", {})
check("inactive Mermaid block uses diagram preview widget",
  mermaidHost.querySelector(".cm-md-mermaid-preview") != null)
mermaidEditor.select(20)
check("active Mermaid block reveals editable source",
  mermaidHost.querySelector(".cm-md-mermaid-preview") == null)
check("active Mermaid block preserves source",
  mermaidEditor.getMarkdown().includes("flowchart LR\n  A --> B"))
mermaidEditor.destroy()

process.exit(failures ? 1 : 0)
