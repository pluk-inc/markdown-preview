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
// Node 21+ exposes `navigator` as a getter-only global; plain assignment throws.
Object.defineProperty(globalThis, "navigator", {
  value: dom.window.navigator,
  configurable: true,
})
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
  check("virtualized documents use CodeMirror selection painting",
    dom.window.document.querySelector(".cm-cursorLayer") != null
      && dom.window.document.querySelector(".cm-selectionLayer") != null)
  editor.exec("bold")
  check("exec('bold') inserts markers", editor.getMarkdown().startsWith("****"))
}

const largeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(largeHost)
const largeDoc = [
  "# Large synthetic document",
  "",
  "```text",
  "PACKAGE VALIDATION PASS:",
  "1200 synthetic sections",
  "```",
  "",
  ...Array.from({ length: 1200 }, (_, index) =>
    `## Section ${index + 1}\nSynthetic paragraph ${index + 1} remains byte-faithful.`),
].join("\n")
const largeEditor = dom.window.MDEditor.create(largeHost, largeDoc, {})
largeEditor.focus()
const largeContent = largeHost.querySelector(".cm-content")
largeContent?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "a",
  code: "KeyA",
  ctrlKey: true,
  bubbles: true,
  cancelable: true,
}))
check("Cmd-A keeps hidden heading syntax in live-preview form",
  largeHost.querySelector(".cm-md-heading-source-hidden") != null)
check("Cmd-A keeps fenced-code markers in live-preview form",
  largeHost.querySelector(".cm-md-code-fence-source-hidden") != null)
largeEditor.insert("replacement")
check("Cmd-A replaces the complete virtualized document",
  largeEditor.getMarkdown() === "replacement")
largeEditor.destroy()

const bidiHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(bidiHost)
const bidiEditor = dom.window.MDEditor.create(
  bidiHost, "English line\nمرحبا بالعالم\nשלום עולם", {})
const bidiLines = Array.from(bidiHost.querySelectorAll(".cm-line"))
check("every editor line derives its direction from its own text",
  bidiLines.length === 3 && bidiLines.every((line) => line.getAttribute("dir") === "auto"))
bidiEditor.destroy()

const frontmatterHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(frontmatterHost)
const frontmatterDoc = "---\nname: \"openai-docs\"\ntags:\n  - links\n---\n# Body heading"
const frontmatterEditor = dom.window.MDEditor.create(frontmatterHost, frontmatterDoc, {})
check("frontmatter renders as a metadata card, not markdown blocks",
  frontmatterHost.querySelectorAll(".cm-md-frontmatter").length === 5
    && frontmatterHost.querySelector(".cm-md-frontmatter-first") != null
    && frontmatterHost.querySelector(".cm-md-frontmatter-last") != null
    && frontmatterHost.querySelector(".cm-md-h2") == null
    && frontmatterHost.querySelector(".cm-md-hr") == null)
check("frontmatter delimiters are dimmed",
  frontmatterHost.querySelectorAll(".cm-md-frontmatter-delim").length === 2)
check("body markdown still live-previews below frontmatter",
  frontmatterHost.querySelector(".cm-md-h1") != null)
check("frontmatter round-trips byte-faithfully",
  frontmatterEditor.getMarkdown() === frontmatterDoc)
frontmatterEditor.destroy()

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
check("normal separator before heading collapses",
  inactiveHeadingHost.querySelector(".cm-md-line-collapsed") != null)
inactiveHeadingEditor.destroy()

const headingFollowHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(headingFollowHost)
const headingFollowEditor = dom.window.MDEditor.create(
  headingFollowHost, "## Heading\n\nFollowing paragraph", {})
check("separator after heading resizes to the paragraph's margin",
  headingFollowHost.querySelector(".cm-md-block-separator") != null)
headingFollowEditor.destroy()

const paragraphGapHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(paragraphGapHost)
const paragraphGapEditor = dom.window.MDEditor.create(
  paragraphGapHost, "First paragraph.\n\nSecond paragraph.\n\n\nThird paragraph.", {})
check("single blank between paragraphs becomes one resized separator",
  paragraphGapHost.querySelectorAll(".cm-md-block-separator").length === 2)
paragraphGapEditor.destroy()

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

const indentedCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(indentedCodeHost)
const indentedCodeEditor = dom.window.MDEditor.create(
  indentedCodeHost, "    <script>\n        run()\n    </script>", {})
const indentedCodeLines = Array.from(indentedCodeHost.querySelectorAll(".cm-line"))
check("indented code block receives preview block styling",
  indentedCodeLines[0]?.classList.contains("cm-md-codeblock-first")
    && indentedCodeLines.at(-1)?.classList.contains("cm-md-codeblock-last"))
check("inactive indented code hides source indentation",
  indentedCodeLines[0]?.textContent === "<script>"
    && indentedCodeLines.at(-1)?.textContent === "</script>")
indentedCodeEditor.destroy()

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
check("implicit initial cursor keeps the leading code block in live preview",
  leadingCodeHost.querySelectorAll(".cm-md-line-collapsed").length === 2)
check("leading preview code block keeps syntax highlighting",
  leadingCodeHost.querySelector(".hl-keyword")?.textContent === "const")
leadingCodeEditor.select(18)
check("pointer click activates the code block",
  leadingCodeHost.querySelectorAll(".cm-md-line-collapsed").length === 2)
check("activated code block remains syntax highlighted",
  leadingCodeHost.querySelector(".hl-keyword")?.textContent === "const")
check("activated code block keeps raw fence lines visually hidden",
  leadingCodeHost.querySelectorAll(".cm-md-line-collapsed").length === 2)
leadingCodeEditor.destroy()

const inactiveCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inactiveCodeHost)
const inactiveCodeEditor = dom.window.MDEditor.create(
  inactiveCodeHost, "intro\n```javascript\nconst answer = 42\n```", {})
check("inactive code block hides both fence source lines",
  inactiveCodeHost.querySelectorAll(".cm-md-code-fence-source-hidden").length === 2)
check("inactive code block keeps syntax highlighting",
  inactiveCodeHost.querySelector(".hl-keyword")?.textContent === "const")
check("inactive fence source lines collapse to zero height",
  inactiveCodeHost.querySelectorAll(".cm-md-line-collapsed").length === 2)
check("interior code line carries the card styling when fences collapse",
  inactiveCodeHost.querySelector(".cm-md-codeblock-first.cm-md-codeblock-last") != null)
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
const stableMermaidPreview = mermaidHost.querySelector(".cm-md-mermaid-preview")
mermaidEditor.exec("bold")
check("unrelated edits preserve the Mermaid preview DOM",
  mermaidHost.querySelector(".cm-md-mermaid-preview") === stableMermaidPreview)
mermaidEditor.select(mermaidEditor.getMarkdown().indexOf("flowchart") + 2)
check("active Mermaid block reveals editable source",
  mermaidHost.querySelector(".cm-md-mermaid-preview") == null)
check("active Mermaid block preserves source",
  mermaidEditor.getMarkdown().includes("flowchart LR\n  A --> B"))
mermaidEditor.destroy()

const authoredMermaidHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(authoredMermaidHost)
const authoredMermaidEditor = dom.window.MDEditor.create(
  authoredMermaidHost, "intro\n", {})
authoredMermaidEditor.select(authoredMermaidEditor.getMarkdown().length)
for (const character of "```mermaid\nflowchart LR\n  A --> B\n```") {
  authoredMermaidEditor.insert(character)
}
check("newly typed Mermaid fence remains editable at the cursor",
  authoredMermaidHost.querySelector(".cm-md-mermaid-preview") == null
    && authoredMermaidHost.querySelector(".cm-md-code-fence-source-hidden") == null)
authoredMermaidEditor.insert("\n")
check("newly typed Mermaid fence previews after the cursor leaves",
  authoredMermaidHost.querySelector(".cm-md-mermaid-preview") != null)
authoredMermaidEditor.destroy()

const tableHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(tableHost)
const tableEditor = dom.window.MDEditor.create(
  tableHost,
  "| Name | Status |\n| --- | --- |\n| Ada | Active |",
  {},
)
check("Markdown table renders as an editable grid",
  tableHost.querySelectorAll(".cm-md-table-cell").length === 4
    && tableHost.querySelector(".cm-md-table-grid") != null)
check("visual table hides pipe-delimited source",
  !tableHost.querySelector(".cm-content")?.textContent.includes("| Name |"))
const lastTableCell = tableHost.querySelector(
  '[data-table-row="1"][data-table-column="1"]'
)
lastTableCell?.focus()
if (lastTableCell) lastTableCell.innerText = "Reviewing"
lastTableCell?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  bubbles: true,
  cancelable: true,
}))
await new Promise((resolve) => setTimeout(resolve, 30))
check("Tab saves the cell and appends a row from the final cell",
  tableEditor.getMarkdown().includes("Reviewing")
    && tableEditor.getMarkdown().split("\n").length === 4)
tableEditor.destroy()

const obsidianTableHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(obsidianTableHost)
const obsidianTableEditor = dom.window.MDEditor.create(
  obsidianTableHost,
  "| Name | Status |\n| --- | --- |\n| Ada | Active |",
  {},
)
check("table structure controls only appear in the native context menu",
  obsidianTableHost.querySelector(".cm-md-table-toolbar") == null
    && obsidianTableHost.querySelector(".cm-md-table-edge-action") == null)
const contextCell = obsidianTableHost.querySelector(
  '[data-table-row="1"][data-table-column="0"]'
)
let nativeTableContextRequest = null
dom.window.__mdRequestTableContextMenu = (details) => {
  nativeTableContextRequest = details
}
contextCell?.dispatchEvent(new dom.window.MouseEvent("contextmenu", {
  clientX: 40,
  clientY: 40,
  bubbles: true,
  cancelable: true,
}))
check("right-click requests the native table context menu",
  nativeTableContextRequest?.canInsertRowAbove === true
    && nativeTableContextRequest?.canDeleteRow === true
    && nativeTableContextRequest?.canDeleteColumn === true
    && nativeTableContextRequest?.showsDuplicateRow === true)
obsidianTableEditor.performTableContextAction(
  nativeTableContextRequest?.token,
  "insertColumnAfter",
)
await new Promise((resolve) => setTimeout(resolve, 30))
check("native context-menu action inserts relative to the clicked cell",
  obsidianTableHost.querySelectorAll(".cm-md-table-cell").length === 6)
const insertedHeader = obsidianTableHost.querySelector(
  '[data-table-row="0"][data-table-column="1"]'
)
check("an added column has a visible header placeholder without changing Markdown",
  insertedHeader?.dataset.placeholder === "Column 2"
    && insertedHeader?.textContent === ""
    && /\|\s*Name\s*\|\s*\|\s*Status\s*\|/.test(
      obsidianTableEditor.getMarkdown().split("\n")[0]
    ))
const insertedDataCell = obsidianTableHost.querySelector(
  '[data-table-row="1"][data-table-column="1"]'
)
insertedDataCell?.dispatchEvent(new dom.window.MouseEvent("contextmenu", {
  bubbles: true,
  cancelable: true,
}))
obsidianTableEditor.performTableContextAction(
  nativeTableContextRequest?.token,
  "selectColumn",
)
let selectedWidget = obsidianTableHost.querySelector(".cm-md-table-widget")
check("Select Column highlights the complete column",
  selectedWidget?.querySelectorAll(".is-table-part-selected").length === 2)
selectedWidget?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Delete",
  bubbles: true,
  cancelable: true,
}))
await new Promise((resolve) => setTimeout(resolve, 30))
check("Delete removes the selected column",
  /\|\s*Name\s*\|\s*Status\s*\|/.test(
    obsidianTableEditor.getMarkdown().split("\n")[0]
  ))
const selectedRowCell = obsidianTableHost.querySelector(
  '[data-table-row="1"][data-table-column="0"]'
)
selectedRowCell?.dispatchEvent(new dom.window.MouseEvent("contextmenu", {
  bubbles: true,
  cancelable: true,
}))
obsidianTableEditor.performTableContextAction(
  nativeTableContextRequest?.token,
  "selectRow",
)
selectedWidget = obsidianTableHost.querySelector(".cm-md-table-widget")
check("Select Row highlights the complete row",
  selectedWidget?.querySelectorAll(".is-table-part-selected").length === 2)
selectedWidget?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Backspace",
  bubbles: true,
  cancelable: true,
}))
await new Promise((resolve) => setTimeout(resolve, 30))
check("Backspace removes the selected row",
  obsidianTableEditor.getMarkdown().split("\n").length === 2)
obsidianTableEditor.destroy()

const dragTableHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(dragTableHost)
const dragTableEditor = dom.window.MDEditor.create(
  dragTableHost,
  "| Name | Status |\n| --- | --- |\n| Ada | Active |\n| Grace | Active |",
  {},
)
const dragStartCell = dragTableHost.querySelector(
  '[data-table-row="1"][data-table-column="0"]'
)
const dragEndCell = dragTableHost.querySelector(
  '[data-table-row="2"][data-table-column="1"]'
)
const nativeRange = dom.window.document.createRange()
if (dragStartCell && dragEndCell) {
  nativeRange.setStart(dragStartCell, 0)
  nativeRange.setEnd(dragEndCell, dragEndCell.childNodes.length)
  dom.window.getSelection()?.removeAllRanges()
  dom.window.getSelection()?.addRange(nativeRange)
}
dragStartCell?.dispatchEvent(new dom.window.MouseEvent("mousedown", {
  button: 0,
  buttons: 1,
  bubbles: true,
  cancelable: true,
}))
const originalElementFromPoint = dom.window.document.elementFromPoint
dom.window.document.elementFromPoint = () => dragEndCell
dragStartCell?.dispatchEvent(new dom.window.MouseEvent("mousemove", {
  button: 0,
  buttons: 1,
  clientX: 500,
  clientY: 300,
  bubbles: true,
  cancelable: true,
}))
dragStartCell?.dispatchEvent(new dom.window.MouseEvent("mouseup", {
  button: 0,
  buttons: 0,
  bubbles: true,
  cancelable: true,
}))
dom.window.document.elementFromPoint = originalElementFromPoint
const dragSelectedWidget = dragTableHost.querySelector(".cm-md-table-widget")
dragEndCell?.dispatchEvent(new dom.window.MouseEvent("click", {
  bubbles: true,
  cancelable: true,
}))
const selectedTopLeft = dragTableHost.querySelector(
  '[data-table-row="1"][data-table-column="0"]'
)
const selectedBottomRight = dragTableHost.querySelector(
  '[data-table-row="2"][data-table-column="1"]'
)
check("dragging across rows and columns selects the anchor-to-head rectangle",
  dragSelectedWidget?.querySelectorAll(".is-table-part-selected").length === 4
    && selectedTopLeft?.classList.contains("is-table-selection-top")
    && selectedTopLeft?.classList.contains("is-table-selection-left")
    && selectedBottomRight?.classList.contains("is-table-selection-bottom")
    && selectedBottomRight?.classList.contains("is-table-selection-right"))
check("cell-range selection persists after pointer release without native text selection",
  dragSelectedWidget?.classList.contains("is-table-range-selected")
    && dom.window.getSelection()?.rangeCount === 0)
dragSelectedWidget?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Escape",
  bubbles: true,
  cancelable: true,
}))
check("Escape clears a dragged cell range",
  dragSelectedWidget?.querySelectorAll(".is-table-part-selected").length === 0)
dragStartCell?.dispatchEvent(new dom.window.MouseEvent("mousedown", {
  button: 0,
  buttons: 1,
  clientX: 100,
  clientY: 100,
  bubbles: true,
  cancelable: true,
}))
dragStartCell?.dispatchEvent(new dom.window.MouseEvent("mouseup", {
  button: 0,
  buttons: 0,
  clientX: 100,
  clientY: 100,
  bubbles: true,
  cancelable: true,
}))
dragStartCell?.dispatchEvent(new dom.window.MouseEvent("click", {
  bubbles: true,
  cancelable: true,
}))
check("an ordinary cell click still restores the editing caret",
  dom.window.getSelection()?.rangeCount === 1
    && dragStartCell?.contains(dom.window.getSelection()?.anchorNode))
const dragHeaderCell = dragTableHost.querySelector(
  '[data-table-row="0"][data-table-column="1"]'
)
const dragBodyCell = dragTableHost.querySelector(
  '[data-table-row="2"][data-table-column="0"]'
)
dragHeaderCell?.dispatchEvent(new dom.window.MouseEvent("mousedown", {
  button: 0,
  buttons: 1,
  bubbles: true,
  cancelable: true,
}))
dom.window.document.elementFromPoint = () => dragBodyCell
dragHeaderCell?.dispatchEvent(new dom.window.MouseEvent("mousemove", {
  button: 0,
  buttons: 1,
  clientX: 100,
  clientY: 300,
  bubbles: true,
  cancelable: true,
}))
dragHeaderCell?.dispatchEvent(new dom.window.MouseEvent("mouseup", {
  button: 0,
  buttons: 0,
  bubbles: true,
  cancelable: true,
}))
dom.window.document.elementFromPoint = originalElementFromPoint
dragBodyCell?.dispatchEvent(new dom.window.MouseEvent("click", {
  bubbles: true,
  cancelable: true,
}))
check("dragging from a header into the body selects both directions",
  dragSelectedWidget?.querySelectorAll(".is-table-part-selected").length === 6
    && dragSelectedWidget?.getAttribute("aria-label") === "Selected 3 rows by 2 columns.")
dragTableEditor.destroy()

process.exit(failures ? 1 : 0)
