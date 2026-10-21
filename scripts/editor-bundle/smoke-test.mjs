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
  // Native selection: no drawSelection() layers, so WebKit paints only text
  // once the host lays .cm-content out as a flex column.
  check("documents use the native selection, not CodeMirror's layers",
    dom.window.document.querySelector(".cm-selectionLayer") == null
      && dom.window.document.querySelector(".cm-cursorLayer") == null)
  editor.exec("bold")
  check("exec('bold') inserts markers", editor.getMarkdown().startsWith("****"))
}

const highlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(highlightHost)
const highlightSource = "before ==Highlighted text== after"
const highlightEditor = dom.window.MDEditor.create(highlightHost, highlightSource, {})
const highlightContent = highlightHost.querySelector(".cm-content")
check("highlight syntax keeps the source unchanged",
  highlightEditor.getMarkdown() === highlightSource)
check("highlight syntax decorates the content",
  highlightHost.querySelector(".cm-md-highlight") != null)
check("inactive highlight delimiters are hidden",
  !(highlightContent?.textContent ?? "").includes("=="))
highlightEditor.focus()
highlightEditor.select(highlightSource.indexOf("Highlighted") + 2)
check("active highlight reveals its delimiters",
  (highlightContent?.textContent ?? "").includes("==Highlighted text=="))

const codeHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(codeHighlightHost)
const codeHighlightEditor = dom.window.MDEditor.create(
  codeHighlightHost, "```\n==literal==\n```", {})
check("highlight syntax stays literal inside fenced code",
  (codeHighlightHost.querySelector(".cm-content")?.textContent ?? "").includes("==literal=="))

const nestedHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(nestedHighlightHost)
const nestedHighlightSource = "==**bold** and *italic*=="
const nestedHighlightEditor = dom.window.MDEditor.create(nestedHighlightHost, nestedHighlightSource, {})
check("nested Markdown stays inside a highlight",
  nestedHighlightHost.querySelector(".cm-md-highlight") != null
    && nestedHighlightHost.querySelector(".cm-md-strong") != null
    && !(nestedHighlightHost.querySelector(".cm-content")?.textContent ?? "").includes("=="))

const inlineCodeHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inlineCodeHighlightHost)
dom.window.MDEditor.create(inlineCodeHighlightHost, "`==code==` and ==visible==", {})
check("inline code is excluded from highlights",
  inlineCodeHighlightHost.querySelectorAll(".cm-md-highlight").length === 1
    && (inlineCodeHighlightHost.querySelector(".cm-content")?.textContent ?? "").includes("==code=="))

const invalidHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(invalidHighlightHost)
dom.window.MDEditor.create(invalidHighlightHost, "== open == and ==unclosed", {})
check("unmatched or whitespace-delimited markers stay literal",
  invalidHighlightHost.querySelector(".cm-md-highlight") == null
    && (invalidHighlightHost.querySelector(".cm-content")?.textContent ?? "").includes("== open =="))

const evenHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(evenHighlightHost)
const evenHighlightSource = "====hello===="
dom.window.MDEditor.create(evenHighlightHost, evenHighlightSource, {})
check("even highlight runs split into independent pairs",
  evenHighlightHost.querySelectorAll(".cm-md-highlight").length === 2
    && Array.from(evenHighlightHost.querySelectorAll(".cm-md-highlight"))
      .every((element) => element.textContent === "hello"))

const oddHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(oddHighlightHost)
const oddHighlightSource = "=====hello====="
dom.window.MDEditor.create(oddHighlightHost, oddHighlightSource, {})
check("odd highlight runs leave one literal equals before each pair",
  oddHighlightHost.querySelectorAll(".cm-md-highlight").length === 2
    && Array.from(oddHighlightHost.querySelectorAll(".cm-md-highlight"))
      .every((element) => element.textContent === "hello=")
    && (oddHighlightHost.querySelector(".cm-content")?.textContent ?? "")
      === "=hello=")

const linkHighlightHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(linkHighlightHost)
const linkHighlightSource = "[==label==](https://example.com/?a==b==c) and \\==literal\\== and ==visible=="
dom.window.MDEditor.create(linkHighlightHost, linkHighlightSource, {})
const linkHighlightText = Array.from(linkHighlightHost.querySelectorAll(".cm-md-highlight"))
  .map((element) => element.textContent)
  .join("|")
check("links and escapes keep delimiter parsing in text context",
  linkHighlightHost.querySelectorAll(".cm-md-highlight").length === 2
    && linkHighlightText.includes("label")
    && linkHighlightText.includes("visible"))

const highlightCommandHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(highlightCommandHost)
const highlightCommandEditor = dom.window.MDEditor.create(highlightCommandHost, "text", {})
highlightCommandEditor.select(0, 4)
highlightCommandEditor.exec("highlight")
check("exec('highlight') wraps the selected text", highlightCommandEditor.getMarkdown() === "==text==")

const indentationHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(indentationHost)
const indentationEditor = dom.window.MDEditor.create(
  indentationHost, "- Parent\n- Alpha\n- Beta", {})
const indentationContent = indentationHost.querySelector(".cm-content")
indentationEditor.select(9, 23)
const indentEvent = new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
})
indentationContent?.dispatchEvent(indentEvent)
check("Tab nests selected list items under their preceding sibling",
  indentEvent.defaultPrevented
    && indentationEditor.getMarkdown()
      === "- Parent\n    - Alpha\n    - Beta")
const outdentEvent = new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  shiftKey: true,
  bubbles: true,
  cancelable: true,
})
indentationContent?.dispatchEvent(outdentEvent)
check("Shift-Tab outdents every selected nested list item",
  outdentEvent.defaultPrevented
    && indentationEditor.getMarkdown() === "- Parent\n- Alpha\n- Beta")
indentationEditor.select(11)
indentationContent?.focus()
indentationContent?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
}))
check("Tab nests the current list item when there is no selection",
  indentationEditor.getMarkdown() === "- Parent\n    - Alpha\n- Beta")
check("active bullet source reserves the rendered marker width",
  indentationHost.querySelector(".cm-md-bullet-source")?.textContent === "-")
check("nested list layout uses semantic depth instead of source-space width",
  indentationHost.querySelector(".cm-md-list-depth-2") != null)
check("nested list source indentation does not occupy rendered layout",
  !indentationHost.querySelector(".cm-md-list-depth-2")?.textContent.startsWith(" "))
indentationContent?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
}))
indentationContent?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
}))
check("repeated Tab does not impose a maximum list indentation depth",
  indentationEditor.getMarkdown() === "- Parent\n            - Alpha\n- Beta")
check("deeply indented list source keeps list geometry across the parser boundary",
  indentationHost.querySelector(".cm-md-list-depth-4.cm-md-list-item") != null
    && indentationHost.querySelector(".cm-md-list-depth-4.cm-md-codeblock") == null)
check("deeply indented list source keeps normal list-item spacing",
  indentationHost.querySelector(".cm-md-list-depth-4.cm-md-list-item-gap") != null)
for (let step = 0; step < 3; step++) {
  indentationContent?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    code: "Tab",
    shiftKey: true,
    bubbles: true,
    cancelable: true,
  }))
}
check("repeated Shift-Tab returns a deeply indented list item to its original depth",
  indentationEditor.getMarkdown() === "- Parent\n- Alpha\n- Beta")
indentationEditor.destroy()

const bracketCases = [
  ["paragraph", "Hello", 5, "(", ")", "Hello()", "Hello(x)"],
  ["ATX heading", "# Heading", 9, "[", "]", "# Heading[]", "# Heading[x]"],
  ["Setext heading", "Heading\n=======", 7, "{", "}", "Heading{}\n=======", "Heading{x}\n======="],
  ["fenced code block", "```js\ncall\n```", 10, "(", ")", "```js\ncall()\n```", "```js\ncall(x)\n```"],
]
for (const [label, source, cursorPos, openBracket, closeBracket, expectedText, expectedAtCursor] of bracketCases) {
  const bracketHost = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(bracketHost)
  const bracketEditor = dom.window.MDEditor.create(bracketHost, source, {})
  bracketEditor.select(cursorPos)
  bracketEditor.insert(openBracket)
  check(`typing ${openBracket} in ${label} auto-closes with ${closeBracket}`,
    bracketEditor.getMarkdown() === expectedText)
  bracketEditor.insert("x")
  check(`cursor lands between ${openBracket}${closeBracket} in ${label}`,
    bracketEditor.getMarkdown() === expectedAtCursor)
  bracketEditor.destroy()
}

const inlineTabHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inlineTabHost)
const inlineTabEditor = dom.window.MDEditor.create(
  inlineTabHost, "Plain paragraph", {})
const inlineTabContent = inlineTabHost.querySelector(".cm-content")
inlineTabEditor.select(5)
const inlineTabEvent = new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
})
inlineTabContent?.dispatchEvent(inlineTabEvent)
check("Tab inserts a tab inside ordinary text",
  inlineTabEvent.defaultPrevented
    && inlineTabEditor.getMarkdown() === "Plain\t paragraph")
inlineTabEditor.select(0)
inlineTabContent?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
}))
check("Tab at a paragraph's leading edge preserves its Markdown block type",
  inlineTabEditor.getMarkdown() === "Plain\t paragraph")
inlineTabEditor.destroy()

const fencedTabHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(fencedTabHost)
const fencedTabEditor = dom.window.MDEditor.create(
  fencedTabHost, "intro\n```c\nint main() {\nreturn 0;\n}\n```", {})
const fencedTabContent = fencedTabHost.querySelector(".cm-content")
fencedTabEditor.select(fencedTabEditor.getMarkdown().indexOf("return"))
const fencedTabEvent = new dom.window.KeyboardEvent("keydown", {
  key: "Tab",
  code: "Tab",
  bubbles: true,
  cancelable: true,
})
fencedTabContent?.dispatchEvent(fencedTabEvent)
check("Tab indents from the leading edge of fenced code content",
  fencedTabEvent.defaultPrevented
    && fencedTabEditor.getMarkdown().includes("\n\treturn 0;"))
fencedTabEditor.destroy()

const topLevelBlockCases = [
  ["ATX heading", "# Heading"],
  ["Setext heading", "Heading\n======="],
  ["paragraph", "Plain paragraph"],
  ["blockquote", "> Quote"],
  ["fenced code", "```swift\nlet value = 1\n```"],
  ["indented code", "    let value = 1", "let value = 1"],
  ["table", "| A | B |\n| - | - |\n| 1 | 2 |"],
  ["horizontal rule", "---"],
  ["link paragraph", "[OpenAI](https://openai.com)"],
  ["YAML frontmatter", "---\ntitle: Example\n---"],
]
for (const [label, source, expectedAfterShiftTab = source] of topLevelBlockCases) {
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const blockEditor = dom.window.MDEditor.create(host, source, {})
  const content = host.querySelector(".cm-content")
  blockEditor.select(0, source.length)
  const tabEvent = new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    code: "Tab",
    bubbles: true,
    cancelable: true,
  })
  content?.dispatchEvent(tabEvent)
  check(`Tab preserves top-level ${label} Markdown`,
    tabEvent.defaultPrevented && blockEditor.getMarkdown() === source)
  const shiftTabEvent = new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    code: "Tab",
    shiftKey: true,
    bubbles: true,
    cancelable: true,
  })
  content?.dispatchEvent(shiftTabEvent)
  check(`Shift-Tab handles ${label} Markdown safely`,
    shiftTabEvent.defaultPrevented
      && blockEditor.getMarkdown() === expectedAfterShiftTab)
  blockEditor.destroy()
}

for (const [label, source] of [
  ["unordered", "- Item"],
  ["ordered", "1. Item"],
  ["task", "- [ ] Item"],
]) {
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const listEditor = dom.window.MDEditor.create(host, source, {})
  const content = host.querySelector(".cm-content")
  listEditor.select(0, source.length)
  content?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    code: "Tab",
    bubbles: true,
    cancelable: true,
  }))
  check(`Tab indents a first ${label} list item`,
    listEditor.getMarkdown() === `    ${source}`)
  content?.dispatchEvent(new dom.window.KeyboardEvent("keydown", {
    key: "Tab",
    code: "Tab",
    shiftKey: true,
    bubbles: true,
    cancelable: true,
  }))
  check(`Shift-Tab restores a first ${label} list item`,
    listEditor.getMarkdown() === source)
  listEditor.destroy()
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
headingEditor.focus()
headingEditor.select(4, 10)
check("ordinary heading range selection keeps source hidden",
  headingHost.querySelector(".cm-md-heading-source-hidden")?.textContent === "### ")
const headingContent = headingHost.querySelector(".cm-content")
headingContent.dispatchEvent(new dom.window.CompositionEvent("compositionstart", { bubbles: true }))
headingEditor.select(4, 9)
check("IME composition range reveals heading source",
  headingHost.querySelector(".cm-md-heading-source-hidden") == null)
headingContent.dispatchEvent(new dom.window.CompositionEvent("compositionend", { bubbles: true }))
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
check("blank source line before heading remains visible",
  inactiveHeadingHost.querySelector(".cm-md-line-collapsed") == null)
check("heading receives compact spacing above a visible blank line",
  inactiveHeadingHost.querySelector(".cm-md-heading-after-blank") != null)
inactiveHeadingEditor.destroy()

const headingFollowHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(headingFollowHost)
const headingFollowEditor = dom.window.MDEditor.create(
  headingFollowHost, "## Heading\n\nFollowing paragraph", {})
// The final blank of a run shrinks to blankGap plus the next block's margin
// (headless defaults: 4 + 12).
check("separator after heading is the blank gap plus the paragraph margin",
  Math.abs(
    parseFloat(headingFollowHost.querySelector(".cm-md-block-separator")?.style.height)
      - 16
  ) < 0.01)
headingFollowEditor.destroy()

const paragraphGapHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(paragraphGapHost)
const paragraphGapEditor = dom.window.MDEditor.create(
  paragraphGapHost, "First paragraph.\n\nSecond paragraph.\n\n\nThird paragraph.", {})
check("blank paragraph separators are the blank gap plus the paragraph margin",
  Array.from(paragraphGapHost.querySelectorAll(".cm-md-block-separator"))
    .every((line) => Math.abs(parseFloat(line.style.height) - 16) < 0.01))
paragraphGapEditor.destroy()

// A block right under a heading (no blank line) gets the preview's margin as
// bottom padding on the heading line.
const adjacentHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(adjacentHost)
const adjacentEditor = dom.window.MDEditor.create(
  adjacentHost, "## Heading\nParagraph right under it", {})
check("adjacent block adds the paragraph margin below the heading line",
  adjacentHost.querySelector(".cm-md-block-gap")?.style.paddingBottom === "12px")
adjacentEditor.destroy()

// Ordered markers share the bullet's hanging box; continuation lines drop the
// hanging indent; nested quotations carry their depth.
const structureHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(structureHost)
const structureEditor = dom.window.MDEditor.create(
  structureHost,
  "1. First\n2. Second\n\n- Item\n\n  Continuation line\n\n> outer\n>> inner",
  {})
const orderedMarkers = Array.from(structureHost.querySelectorAll(".cm-md-ordered"))
check("inactive ordered markers render in the hanging marker box",
  orderedMarkers.map((el) => el.textContent).join("|") === "1.|2.")
check("continuation line inside a list item drops the hanging indent",
  structureHost.querySelector(".cm-md-list-continuation")?.textContent.includes("Continuation line") === true)
const quoteLines = Array.from(structureHost.querySelectorAll(".cm-md-quote"))
check("nested quotation lines carry one rule per depth",
  quoteLines.length === 2
    && quoteLines[0].style.paddingInlineStart === "1.5em"
    && quoteLines[1].style.paddingInlineStart === "3em"
    && quoteLines[1].style.backgroundImage.split("linear-gradient").length === 3)
structureEditor.destroy()

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

const imageHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(imageHost)
const imageMarkdown = "Before\n\n![Preview](md-asset:///test-pictures/1.png)\n\nAfter"
let requestedImageRename = null
dom.window.__mdRequestImageRename = (source) => { requestedImageRename = source }
const imageEditor = dom.window.MDEditor.create(imageHost, imageMarkdown, {})
const imagePreview = imageHost.querySelector(".cm-md-image-preview")
const image = imagePreview?.querySelector("img")
const imageSource = imagePreview?.querySelector(".cm-md-image-source")
check("inactive Markdown image renders as a preview",
  image?.getAttribute("src") === "md-asset:///test-pictures/1.png")
check("standalone image uses a line without extra baseline spacing",
  imagePreview?.closest(".cm-line")?.classList.contains("cm-md-image-line"))
check("image preview retains the exact Markdown source",
  imageSource?.textContent === "![Preview](md-asset:///test-pictures/1.png)")
image?.dispatchEvent(new dom.window.MouseEvent("click", {
  bubbles: true,
  cancelable: true,
}))
check("clicking a local image requests its native rename flow",
  requestedImageRename === "md-asset:///test-pictures/1.png")
imageSource?.dispatchEvent(new dom.window.MouseEvent("mousedown", {
  bubbles: true,
  cancelable: true,
}))
check("clicking image source restores editable Markdown without changing it",
  imageHost.querySelector(".cm-md-image-preview") == null
    && imageHost.querySelector(".cm-md-image-line") == null
    && imageEditor.getMarkdown() === imageMarkdown)
imageEditor.destroy()
delete dom.window.__mdRequestImageRename

const inlineImageHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(inlineImageHost)
const inlineImageMarkdown = "Before ![Preview](image.png) after"
const inlineImageEditor = dom.window.MDEditor.create(inlineImageHost, inlineImageMarkdown, {})
check("an image surrounded by text keeps its inline alignment",
  inlineImageHost.querySelector(".cm-md-image-preview") != null
    && inlineImageHost.querySelector(".cm-md-image-line") == null
    && inlineImageEditor.getMarkdown() === inlineImageMarkdown)
inlineImageEditor.destroy()

for (const imageSource of [
  "![Preview](image.png)",
  "[![Preview](image.png)](https://example.com)",
  "Before ![Preview](image.png) after",
  "![Preview][reference]\n\n[reference]: image.png",
  "![Preview](//example.com/image.png)",
  "> ![Preview](image.png)",
]) {
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const source = `Before\n\n${imageSource}\n\nAfter image\n\nFinal paragraph`
  const instance = dom.window.MDEditor.create(host, source, {})
  const lines = Array.from(host.querySelectorAll(".cm-line"))
  for (const text of ["After image", "Final paragraph"]) {
    const line = lines.find((line) => line.textContent === text)
    check(`paragraph spacing survives ${imageSource.split("\n")[0]} before ${text}`,
      parseFloat(line?.previousElementSibling?.style.height) === 16)
  }
  instance.destroy()
}

const renameHistoryHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(renameHistoryHost)
const renameHistoryEditor = dom.window.MDEditor.create(
  renameHistoryHost, "![Preview](test-pictures/1.png)", {})
renameHistoryEditor.replaceMarkdown("![Preview](test-pictures/hero.png)")
const renameHistoryContent = renameHistoryHost.querySelector(".cm-content")
renameHistoryContent?.focus()
// jsdom reports a non-macOS platform, so Mod maps to Ctrl in this test.
const renameUndoEvent = new dom.window.KeyboardEvent("keydown", {
  key: "z",
  code: "KeyZ",
  ctrlKey: true,
  bubbles: true,
  cancelable: true,
})
renameHistoryContent?.dispatchEvent(renameUndoEvent)
check("Undo after image rename does not restore the old path",
  renameUndoEvent.defaultPrevented
    && renameHistoryEditor.getMarkdown() === "![Preview](test-pictures/hero.png)")
renameHistoryEditor.destroy()

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

const nativeCodeHost = document.createElement('div')
document.body.appendChild(nativeCodeHost)
const nativeCodeSource = 'Before\n\n```text\nfirst\nsecond\n```\n\nBetween\n\n```\nthird\n```\n\nAfter'
const nativeCodeEditor = dom.window.MDEditor.create(nativeCodeHost, nativeCodeSource, {})
const nativeCards = [...nativeCodeHost.querySelectorAll('.cm-md-code-card')]
check('each editable code block has one native scroll wrapper',
  nativeCards.length === 2 && nativeCards[0].querySelectorAll('.cm-md-codeblock').length === 2)
check('native code wrappers exclude surrounding paragraphs and separators',
  nativeCards.every(card => !/Before|Between|After/.test(card.textContent)
    && card.querySelector('.cm-md-block-separator') == null))
nativeCodeEditor.select(nativeCodeSource.indexOf('second') + 3)
nativeCodeEditor.insert('X')
check('editing inside a native code wrapper preserves source positions',
  nativeCodeEditor.getMarkdown() === nativeCodeSource.replace('second', 'secXond'))
nativeCodeHost.querySelector('.cm-content').dispatchEvent(new dom.window.KeyboardEvent('keydown', {
  key: 'z', code: 'KeyZ', ctrlKey: true, bubbles: true, cancelable: true,
}))
check('native code wrapper editing supports undo', nativeCodeEditor.getMarkdown() === nativeCodeSource)
nativeCodeEditor.destroy()

const listLikeCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(listLikeCodeHost)
const listLikeCodeEditor = dom.window.MDEditor.create(
  listLikeCodeHost, "    - literal code output", {})
check("standalone indented code that starts with a dash remains code",
  listLikeCodeHost.querySelector(".cm-md-codeblock") != null
    && listLikeCodeHost.querySelector("[class*='cm-md-list-depth-']") == null)
listLikeCodeEditor.destroy()

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

const markerHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(markerHost)
const markerSource = "## [Unreleased]\n\n- **Bold** and *italic*\n\n[Real link](https://example.com)"
const markerEditor = dom.window.MDEditor.create(markerHost, markerSource, {})
for (const position of [0, markerSource.indexOf("Bold"), markerSource.indexOf("Real link")]) {
  markerEditor.select(position)
  check(`Markdown markers do not inherit code metadata colors at ${position}`,
    markerHost.querySelector(".hl-meta") == null)
}
check("actual Markdown links retain link styling", markerHost.querySelector(".cm-md-link") != null)
check("marker styling preserves Markdown source", markerEditor.getMarkdown() === markerSource)
markerEditor.destroy()

const preprocessorHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(preprocessorHost)
const preprocessorSource = "```c\n#include <stdio.h>\nint answer = 42;\n```"
const preprocessorEditor = dom.window.MDEditor.create(preprocessorHost, preprocessorSource, {})
for (const position of [0, preprocessorSource.indexOf("include")]) {
  preprocessorEditor.select(position)
  check(`code preprocessors keep metadata highlighting at ${position}`,
    preprocessorHost.querySelector(".hl-meta")?.textContent.includes("#include"))
}
preprocessorEditor.destroy()

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

const detectedCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(detectedCodeHost)
let detectedCodeDirtyCount = 0
const detectedCodeSource = "intro\n```\nconst answer = 42\n```"
const detectedCodeEditor = dom.window.MDEditor.create(
  detectedCodeHost,
  detectedCodeSource,
  { onDirty: () => { detectedCodeDirtyCount++ } },
)
const detectedLanguageInput = detectedCodeHost.querySelector(
  ".cm-md-code-language-input"
)
check("detected language is shown as the language input value",
  detectedLanguageInput != null
    && detectedLanguageInput.value === "javascript"
    && detectedLanguageInput.placeholder === "language")
check("detected language applies its CodeMirror highlighting rules",
  detectedCodeHost.querySelector(".hl-keyword")?.textContent === "const")
check("automatic language rendering leaves Markdown byte-faithful",
  detectedCodeEditor.getMarkdown() === detectedCodeSource
    && detectedCodeDirtyCount === 0)
detectedLanguageInput?.focus()
detectedLanguageInput?.blur()
check("focusing and blurring a detected language does not write the fence",
  detectedCodeEditor.getMarkdown() === detectedCodeSource
    && detectedCodeDirtyCount === 0)
const editableDetectedLanguageInput = detectedCodeHost.querySelector(
  ".cm-md-code-language-input"
)
editableDetectedLanguageInput?.focus()
if (editableDetectedLanguageInput) {
  editableDetectedLanguageInput.value = "typescript"
  editableDetectedLanguageInput.dispatchEvent(
    new dom.window.Event("change", { bubbles: true })
  )
}
check("language input writes the explicit fence language",
  detectedCodeEditor.getMarkdown() === "intro\n```typescript\nconst answer = 42\n```")
detectedCodeEditor.destroy()

const detectedCHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(detectedCHost)
const detectedCSource = "intro\n```\nint main(){\nreturn 0;\n}\n```"
const detectedCEditor = dom.window.MDEditor.create(
  detectedCHost, detectedCSource, {})
const detectedCInput = detectedCHost.querySelector(".cm-md-code-language-input")
check("C code is automatically marked as c",
  detectedCInput?.value === "c"
    && detectedCInput.placeholder === "language")
check("automatically detected C uses the bundled C parser",
  Array.from(detectedCHost.querySelectorAll(".hl-keyword"))
    .some((node) => node.textContent === "int" || node.textContent === "return"))
check("automatic C rendering does not rewrite the opening fence",
  detectedCEditor.getMarkdown() === detectedCSource)
detectedCEditor.destroy()

const metadataCodeHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(metadataCodeHost)
const metadataCodeEditor = dom.window.MDEditor.create(
  metadataCodeHost, "```js title=\"answer.js\"\nconst answer = 42\n```", {})
const metadataInput = metadataCodeHost.querySelector(".cm-md-code-language-input")
metadataInput?.focus()
if (metadataInput) {
  metadataInput.value = "typescript"
  metadataInput.dispatchEvent(new dom.window.Event("change", { bubbles: true }))
}
check("language edits preserve fence metadata",
  metadataCodeEditor.getMarkdown() ===
    "```typescript title=\"answer.js\"\nconst answer = 42\n```")
metadataCodeEditor.destroy()

const autoFenceHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(autoFenceHost)
const autoFenceEditor = dom.window.MDEditor.create(autoFenceHost, "intro\n", {})
autoFenceEditor.select(autoFenceEditor.getMarkdown().length)
for (const character of "```") autoFenceEditor.insert(character)
check("typing an opening fence inserts its own closing fence",
  autoFenceEditor.getMarkdown() === "intro\n```\n\n```")
const emptyCodeLine = autoFenceHost.querySelector(".cm-md-codeblock-first")
check("auto-closed empty code line keeps its caret buffer after the language widget",
  emptyCodeLine?.querySelector(".cm-md-code-language + .cm-widgetBuffer") != null)
check('empty code block keeps its editable line in a native scroll wrapper',
  emptyCodeLine?.closest('.cm-md-code-card') != null)
autoFenceEditor.insert("body")
check("auto-closed fence leaves the cursor in its content",
  autoFenceEditor.getMarkdown() === "intro\n```\nbody\n```")
autoFenceEditor.destroy()

const authoredCHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(authoredCHost)
const authoredCEditor = dom.window.MDEditor.create(authoredCHost, "intro\n", {})
authoredCEditor.select(authoredCEditor.getMarkdown().length)
for (const character of "```") authoredCEditor.insert(character)
authoredCEditor.insert("int main(){\nreturn 0;\n}")
check("newly authored C code is detected and highlighted immediately",
  authoredCHost.querySelector(".cm-md-code-language-input")?.value === "c"
    && Array.from(authoredCHost.querySelectorAll(".hl-keyword"))
      .some((node) => node.textContent === "int" || node.textContent === "return")
    && authoredCEditor.getMarkdown() ===
      "intro\n```\nint main(){\nreturn 0;\n}\n```")
authoredCEditor.destroy()

const unclosedFenceHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(unclosedFenceHost)
const unclosedFenceEditor = dom.window.MDEditor.create(
  unclosedFenceHost, "```\nbody\n", {})
unclosedFenceEditor.select(unclosedFenceEditor.getMarkdown().length)
for (const character of "```") unclosedFenceEditor.insert(character)
check("typing an existing block's closing fence does not pair it again",
  unclosedFenceEditor.getMarkdown() === "```\nbody\n```")
unclosedFenceEditor.destroy()

const emptyFenceHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(emptyFenceHost)
const emptyFenceEditor = dom.window.MDEditor.create(
  emptyFenceHost, "intro\n```\n```", {})
check("empty fenced blocks keep their language input visible",
  emptyFenceHost.querySelector(".cm-md-code-language-input") != null
    && emptyFenceHost.querySelector(".cm-md-code-language-input")
      .closest(".cm-line")?.classList.contains("cm-md-line-collapsed") !== true)
emptyFenceEditor.destroy()

const hclSource = `terraform {
  required_providers {
    random = { source = "hashicorp/random", version = "~> 3.0" }
    local  = { source = "hashicorp/local",  version = "~> 2.0" }
  }
}

resource "random_pet" "name" {
  length = 2
}`
for (const language of ["hcl", "terraform", "tf"]) {
  const hclHost = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(hclHost)
  const hclEditor = dom.window.MDEditor.create(
    hclHost, `intro\n\`\`\`${language}\n${hclSource}\n\`\`\``, {})
  check(`${language} fence highlights HCL block keywords`,
    Array.from(hclHost.querySelectorAll(".hl-keyword"))
      .some((node) => node.textContent === "resource"))
  check(`${language} fence highlights HCL strings`,
    Array.from(hclHost.querySelectorAll(".hl-string"))
      .some((node) => node.textContent.includes("hashicorp/random")))
  check(`${language} fence highlights HCL numbers`,
    Array.from(hclHost.querySelectorAll(".hl-number"))
      .some((node) => node.textContent === "2"))
  hclEditor.destroy()
}

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
mermaidEditor.select(0, mermaidEditor.getMarkdown().length)
check("select all keeps the open Mermaid source open",
  mermaidHost.querySelector(".cm-md-mermaid-preview") == null)
mermaidEditor.select(0, 3)
check("a range selection outside the open block closes it",
  mermaidHost.querySelector(".cm-md-mermaid-preview") != null)
mermaidEditor.destroy()

// Clicking a diagram opens its source with the caret at the end of its last
// source line (an empty block gets one); typing must edit the diagram, not a
// ``` marker, and leave the other diagram drawn.
async function clickFirstDiagramAndType(markdown, text) {
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const editor = dom.window.MDEditor.create(host, markdown, {})
  host.querySelector(".cm-md-mermaid-preview")
    .dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1 }))
  dom.window.document.dispatchEvent(new dom.window.MouseEvent("mouseup", { bubbles: true, button: 0 }))
  await new Promise((resolve) => setTimeout(resolve, 10))
  editor.insert(text)
  const result = {
    markdown: editor.getMarkdown(),
    previews: host.querySelectorAll(".cm-md-mermaid-preview").length,
  }
  editor.destroy()
  return result
}
const clickedDiagram = await clickFirstDiagramAndType(
  "intro\n\n```mermaid\nflowchart LR\n  A --> B\n```\n\nafter\n\n```mermaid\npie\n```", "x")
check("typing after clicking a diagram keeps its fence intact",
  clickedDiagram.markdown === "intro\n\n```mermaid\nflowchart LR\n  A --> Bx\n```\n\nafter\n\n```mermaid\npie\n```")
check("typing after clicking a diagram keeps the other diagram drawn", clickedDiagram.previews === 1)
const clickedEmpty = await clickFirstDiagramAndType(
  "intro\n\n```mermaid\n```\n\nafter\n\n```mermaid\nflowchart LR\n  A --> B\n```", "g")
check("one click on an empty diagram block leaves the caret inside it",
  clickedEmpty.markdown === "intro\n\n```mermaid\ng\n```\n\nafter\n\n```mermaid\nflowchart LR\n  A --> B\n```")
check("typing into an empty diagram block keeps the next diagram drawn", clickedEmpty.previews === 1)
const clickedQuoted = await clickFirstDiagramAndType("intro\n\n> ```mermaid\n> ```\n\nafter", "g")
check("an empty diagram in a quote gets a quoted source line",
  clickedQuoted.markdown === "intro\n\n> ```mermaid\n> g\n> ```\n\nafter")
{
  // Quote bars and indent are drawn by the widget, with no code card around
  // it: the card would draw a second box.
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const editor = dom.window.MDEditor.create(host, "> quote\n>\n> ```mermaid\n> ```\n\nafter", {})
  const nest = host.querySelector(".cm-md-mermaid-nest")
  check("a diagram in a quote is nested with its quote bar",
    nest != null && nest.querySelector(".cm-md-mermaid-preview") != null
    && nest.style.backgroundImage.includes("--quote-border"))
  check("a diagram widget is not wrapped in a code card",
    host.querySelector(".cm-md-code-card .cm-md-mermaid-preview") == null)
  editor.destroy()
}
{
  // A diagram under item "100." takes the list's extra digit width, like the
  // item's own continuation lines.
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const editor = dom.window.MDEditor.create(host, "100. item\n\n     ```mermaid\n     ```\n", {})
  const nest = host.querySelector(".cm-md-mermaid-nest")
  check("a diagram in a wide ordered list keeps the extra digit indent",
    nest != null && /1ch/.test(nest.style.paddingInlineStart))
  editor.destroy()
}
for (const [markdown, marker] of [
  ["- ```mermaid\n  flowchart LR\n    A --> B\n  ```\n\nafter", ".cm-md-bullet"],
  ["1. ```mermaid\n   flowchart LR\n     A --> B\n   ```\n\nafter", ".cm-md-ordered"],
]) {
  // A fence that starts on the list marker's line keeps the marker drawn.
  const host = dom.window.document.createElement("div")
  dom.window.document.body.appendChild(host)
  const editor = dom.window.MDEditor.create(host, markdown, {})
  check(`a diagram on a list marker's line keeps the marker (${marker})`,
    host.querySelector(marker) != null && host.querySelector(".cm-md-mermaid-preview") != null
    && host.querySelector(".cm-md-code-card .cm-md-mermaid-preview") == null)
  editor.destroy()
}
const clickedListed = await clickFirstDiagramAndType("intro\n\n- item\n\n  ```mermaid\n  ```\n\nafter", "g")
check("an empty diagram in a list keeps the list indent",
  clickedListed.markdown === "intro\n\n- item\n\n  ```mermaid\n  g\n  ```\n\nafter")

const authoredMermaidHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(authoredMermaidHost)
const authoredMermaidEditor = dom.window.MDEditor.create(
  authoredMermaidHost, "intro\n", {})
authoredMermaidEditor.select(authoredMermaidEditor.getMarkdown().length)
for (const character of "```") {
  authoredMermaidEditor.insert(character)
}
const authoredMermaidLanguage = authoredMermaidHost.querySelector(
  ".cm-md-code-language-input"
)
if (authoredMermaidLanguage) {
  authoredMermaidLanguage.value = "mermaid"
  authoredMermaidLanguage.dispatchEvent(
    new dom.window.Event("change", { bubbles: true })
  )
}
authoredMermaidEditor.insert("flowchart LR\n  A --> B")
check("newly typed Mermaid fence remains editable at the cursor",
  authoredMermaidHost.querySelector(".cm-md-mermaid-preview") == null
    && authoredMermaidHost.querySelector(".cm-md-code-fence-source-hidden") == null)
authoredMermaidEditor.select(authoredMermaidEditor.getMarkdown().length)
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

const countTableHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(countTableHost)
const reportedSelections = []
const countTableEditor = dom.window.MDEditor.create(
  countTableHost,
  "| Name | Status |\n| --- | --- |\n| Ada | Active |",
  { onFormattingChange: (state) => reportedSelections.push(state.selectedText) },
)
const countCell = countTableHost.querySelector('[data-table-row="1"][data-table-column="0"]')
// jsdom has no innerText and does not focus the editable cell, so stand in
// for both: the cell holds plain text, and the focus listener marks it active.
if (countCell) Object.defineProperty(countCell, "innerText", { get() { return this.textContent } })
countCell?.dispatchEvent(new dom.window.FocusEvent("focus"))
dom.window.getSelection()?.setBaseAndExtent(countCell.firstChild, 0, countCell.firstChild, 3)
dom.window.document.dispatchEvent(new dom.window.Event("selectionchange"))
check("a table cell selection reports its text for Inspector counts",
  reportedSelections.at(-1) === "Ada")
countCell?.dispatchEvent(new dom.window.MouseEvent("contextmenu", { bubbles: true, cancelable: true }))
countTableEditor.performTableContextAction(nativeTableContextRequest?.token, "selectRow")
check("Select Row clears the previous cell selection counts",
  reportedSelections.at(-1) === null)
countTableEditor.destroy()

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
    && selectedTopLeft?.classList.contains("is-table-part-selected")
    && selectedBottomRight?.classList.contains("is-table-part-selected"))
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
const nativeCellClickAllowed = dragStartCell?.dispatchEvent(new dom.window.MouseEvent("mousedown", {
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
check("an ordinary cell click allows native caret placement and selection",
  nativeCellClickAllowed === true)
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

const findHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(findHost)
const findSource = "# Needle\n\nneedle one\n\npinneedle two\n\nNEEDLE three\n\nliteral a.b [x]\n\nİ needle after unicode\n"
let lastFindResult
let searchDirtyCount = 0
const findEditor = dom.window.MDEditor.create(findHost, findSource, {
  onDirty: () => searchDirtyCount++,
  onSearchChange: (result) => { lastFindResult = result },
})
const findResult = (query, backwards = false, beginsWith = false) =>
  findEditor.find(query, backwards, beginsWith)
check("editor search counts case-insensitive source matches", findResult("needle").total === 5)
check("editor search highlights without editor focus", findHost.querySelectorAll(".cm-find-match").length === 5)
check("next match advances", findResult("needle").index === 2)
check("previous match goes backwards", findResult("needle", true).index === 1)
check("previous wraps to last match", findResult("needle", true).index === 5)
check("next wraps to first match", findResult("needle").index === 1)
check("begins-with excludes mid-word matches and resets index",
  JSON.stringify(findResult("needle", false, true)) === JSON.stringify({ index: 1, total: 4 }))
check("search treats regex characters literally", findResult("a.b [x]").total === 1)
findResult("needle")
findResult("needle", true)
check("Unicode before a match preserves highlight offsets",
  findHost.querySelector(".cm-find-current")?.textContent === "needle")
check("search navigation preserves document and does not mark dirty",
  findEditor.getMarkdown() === findSource && searchDirtyCount === 0)
check("no-match query clears highlights", findResult("absent").total === 0
  && findHost.querySelector(".cm-find-match") == null)
findResult("needle")
findEditor.insertTextAt("needle new\n", findSource.length, findSource.length)
check("unsaved edits update search count", lastFindResult?.total === 6)
findResult("")
check("clearing search removes all decorations", findHost.querySelector(".cm-find-match") == null)
findEditor.destroy()

const blockFindHost = dom.window.document.createElement("div")
dom.window.document.body.appendChild(blockFindHost)
const blockFindSource = "| Heading |\n| --- |\n| needle |\n\n```mermaid\ngraph LR\nneedle-->end\n```\n"
const blockFindEditor = dom.window.MDEditor.create(blockFindHost, blockFindSource, {})
check("search finds text inside a rendered table", blockFindEditor.find("needle").total === 2
  && blockFindHost.querySelector(".cm-find-current")?.textContent === "needle")
blockFindEditor.find("needle")
check("search reveals and highlights Mermaid source", blockFindHost.querySelector(".cm-find-current")?.textContent === "needle")
check("searching rendered blocks preserves source", blockFindEditor.getMarkdown() === blockFindSource)
blockFindEditor.destroy()


// Exercise the shipped KaTeX and the same rendering function used in both modes.
const { createRequire } = await import("node:module")
const require = createRequire(import.meta.url)
globalThis.katex = require("../../md-preview/Vendor/KaTeX/katex.min.js")
const mathSwift = readFileSync(new URL("../../md-preview/Rendering/MarkdownHTML+KaTeX.swift", import.meta.url), "utf8")
const renderFunctionMatch = mathSwift.match(/static let mathElementRenderer = """([\s\S]*?)"""/)
if (!renderFunctionMatch) throw new Error("Could not extract mathElementRenderer from MarkdownHTML+KaTeX.swift")
const renderFunction = renderFunctionMatch[1]
dom.window.__mdRenderMathElement = new Function(`${renderFunction}; return renderMathElement`)()
let mathLoads = 0
dom.window.__mdLoadMath = () => { mathLoads++; return Promise.resolve() }
const mathHost = document.createElement("div")
document.body.append(mathHost)
const mathSource = "Intro\n\nInline $x_1 + \\frac{1}{2}$ and $y^2$.\n\n$$ \\sum_{i=1}^n i $$\n\n$$\n\\begin{aligned}\nx &= 1 \\\\\n\ny &= 2\n\\end{aligned}\n$$\n\nEnd"
const mathEditor = dom.window.MDEditor.create(mathHost, mathSource, {})
await new Promise(resolve => setTimeout(resolve, 30))
check("inline and multiline dollar math render with bundled KaTeX", mathHost.querySelectorAll('.katex').length === 4)
check("display math uses KaTeX display mode", mathHost.querySelectorAll('.katex-display').length === 2)
check("math rendering preserves exact Markdown", mathEditor.getMarkdown() === mathSource)
const unchangedMath = mathHost.querySelector('.math')
const loadCount = mathLoads
mathEditor.select(mathSource.length)
mathEditor.insertTextAt('!', mathSource.length, mathSource.length)
await new Promise(resolve => setTimeout(resolve, 10))
check("unrelated typing retains math DOM without typesetting again", mathHost.querySelector('.math') === unchangedMath && mathLoads === loadCount)
mathEditor.focus()
mathEditor.select(mathSource.indexOf('frac') + 2)
check("entering a formula reveals editable TeX", mathHost.querySelectorAll('.math').length === 3 && mathHost.textContent.includes('frac'))
check("active TeX is syntax highlighted", !!mathHost.querySelector('.hl-keyword, .hl-string, .hl-type, .hl-number'))
mathEditor.select(mathEditor.getMarkdown().length)
await new Promise(resolve => setTimeout(resolve, 10))
check("leaving a formula restores its preview", mathHost.querySelectorAll('.katex').length === 4)
mathEditor.find('frac')
check("find reveals math source", mathHost.textContent.includes('frac') && !!mathHost.querySelector('.cm-find-current'))
mathEditor.destroy()

const literalDollarHost = document.createElement("div")
document.body.append(literalDollarHost)
const literalDollarEditor = dom.window.MDEditor.create(literalDollarHost, "Prices: $5 and $10. Escaped dollar: \\$x$.", {})
await new Promise(resolve => setTimeout(resolve, 10))
check("an escaped dollar never closes inline math", !literalDollarHost.querySelector('.math'))
literalDollarEditor.destroy()

const emptyMathHost = document.createElement("div")
document.body.append(emptyMathHost)
const emptyMathEditor = dom.window.MDEditor.create(emptyMathHost, "intro\n\n```math\n```", {})
emptyMathHost.querySelector(".math")
  ?.dispatchEvent(new dom.window.MouseEvent("mousedown", { bubbles: true, button: 0, detail: 1 }))
dom.window.document.dispatchEvent(new dom.window.MouseEvent("mouseup", { bubbles: true, button: 0 }))
await new Promise(resolve => setTimeout(resolve, 10))
emptyMathEditor.insert("x")
check("clicking an empty math fence opens a source line inside it",
  emptyMathEditor.getMarkdown() === "intro\n\n```math\nx\n```")
emptyMathEditor.destroy()

const quotedMathHost = document.createElement("div")
document.body.append(quotedMathHost)
const quotedMathSource = "> $$\n> x = 1\n> $$\n\nEnd"
const quotedMathEditor = dom.window.MDEditor.create(quotedMathHost, quotedMathSource, {})
quotedMathEditor.focus()
quotedMathEditor.select(quotedMathSource.indexOf('$$'))
await new Promise(resolve => setTimeout(resolve, 10))
const quotedMathLines = Array.from(quotedMathHost.querySelectorAll('.cm-md-codeblock')).map(line => line.textContent)
check("quoted math source hides the quote markers of its later lines",
  quotedMathLines.length === 3 && quotedMathLines.slice(1).every(text => !text.includes('>')))
quotedMathEditor.destroy()

for (const [label, source, count] of [
  ['inline without spaces', '$x^2$', 1],
  ['spaces inside both delimiters', '$ x^2 $', 0],
  ['space after opening delimiter', '$ x^2$', 0],
  ['space before closing delimiter', '$x^2 $', 0],
  ['tab after opening delimiter', '$\tx^2$', 0],
  ['tab before closing delimiter', '$x^2\t$', 0],
  ['adjacent inline formulas', '$x$$y$', 2],
  ['unclosed double delimiter', '$$x$', 0],
  ['currency', 'Pay $5 and $10', 0],
  ['escaped dollar', String.raw`\$x$`, 0],
  ['inline code', '`$x$` and ``$$x$$``', 0],
  ['fenced code', '```text\n$x$\n$$y$$\n```', 0],
  ['unclosed inline', 'Before $x_1 and after', 0],
  ['unclosed display', '$$\nx_1\n\nFollowing text', 0],
  ['empty delimiters', '$$$$', 0],
  ['invalid TeX', String.raw`$\notARealCommand{x}$`, 1],
  ['fenced math', '```math\nx^2\n```', 1],
  ['quoted display math', '> $$\n> x^2\n> $$', 1],
  ['unclosed fenced math', '```math\nx^2', 0],
  ['table math', '| Formula |\n| --- |\n| $x^2$ |', 1],
]) {
  const host = document.createElement('div')
  document.body.append(host)
  const instance = dom.window.MDEditor.create(host, source, {})
  await new Promise(resolve => setTimeout(resolve, 10))
  check(`math edge case: ${label}`, host.querySelectorAll('.katex, .katex-error').length === count
    && instance.getMarkdown() === source)
  instance.destroy()
  host.remove()
}

const firstMathHost = document.createElement('div')
document.body.append(firstMathHost)
window.__mdMathEditLabel = 'Localized math editing instructions'
const firstMath = window.MDEditor.create(firstMathHost, '$x^2$ after', {})
await new Promise(resolve => setTimeout(resolve, 10))
check('math uses the host-provided accessibility label',
  firstMathHost.querySelector('.math').getAttribute('aria-label') === window.__mdMathEditLabel)
delete window.__mdMathEditLabel
firstMathHost.querySelector('.math').dispatchEvent(new dom.window.MouseEvent('mousedown', {
  bubbles: true, cancelable: true,
}))
await new Promise(resolve => setTimeout(resolve, 20))
check('clicking a formula at document start reveals source safely', !firstMathHost.querySelector('.math')
  && firstMath.getMarkdown() === '$x^2$ after')
firstMath.destroy()
firstMathHost.remove()

for (const [formula, offset] of [
  ['$x$', 1], ['$$x$$', 2], ['$$ x $$', 2], ['$$\nx\n$$', 3], ['```math\nx\n```', 8],
]) {
  const host = document.createElement('div')
  document.body.append(host)
  const source = 'Before\n\n' + formula + '\n\nAfter'
  const editor = window.MDEditor.create(host, source, {})
  host.querySelector('.math').dispatchEvent(new window.MouseEvent('mousedown', {
    bubbles: true, cancelable: true,
  }))
  document.dispatchEvent(new window.MouseEvent('mouseup', { bubbles: true }))
  editor.insert('z')
  const caret = 'Before\n\n'.length + offset
  check(`clicking math preserves its opening delimiter: ${JSON.stringify(formula)}`,
    editor.getMarkdown() === source.slice(0, caret) + 'z' + source.slice(caret))
  editor.destroy()
  host.remove()
}

for (const opening of ['> $$\n> x', '- $$\n  x']) {
  const host = document.createElement('div')
  document.body.append(host)
  const source = opening + '\n\n# Outside\n\n$$\ny\n$$'
  const editor = window.MDEditor.create(host, source, {})
  await new Promise(resolve => setTimeout(resolve, 10))
  check(`unfinished math stops at its container: ${JSON.stringify(opening)}`,
    host.querySelectorAll('.katex').length === 1 && !host.querySelector('.katex-error')
    && host.querySelector('.cm-content').textContent.includes('Outside')
    && host.querySelector('.cm-content').textContent.includes('x')
    && editor.getMarkdown() === source)
  editor.destroy()
  host.remove()
}

const typedMathHost = document.createElement('div')
document.body.append(typedMathHost)
const typedMath = window.MDEditor.create(typedMathHost, 'Intro\n\n', {})
const noMathLoads = mathLoads
check('plain editor does not load KaTeX', !typedMathHost.querySelector('.math') && mathLoads === noMathLoads)
typedMath.insertTextAt('$$\nx^2\n$$\n\nEnd', 7, 7)
await new Promise(resolve => setTimeout(resolve, 10))
check('typing the first formula activates math without reload', typedMathHost.querySelectorAll('.katex').length === 1)
typedMath.focus()
await new Promise(resolve => setTimeout(resolve, 550))
typedMath.insertTextAt('', 14, 16)
check('deleting closing delimiters restores visible source', !typedMathHost.querySelector('.math')
  && typedMathHost.textContent.includes('End') && typedMath.getMarkdown().includes('x^2'))
typedMathHost.querySelector('.cm-content').dispatchEvent(new dom.window.KeyboardEvent('keydown', {
  key: 'z', code: 'KeyZ', ctrlKey: true, bubbles: true, cancelable: true,
}))
typedMath.select(typedMath.getMarkdown().length)
await new Promise(resolve => setTimeout(resolve, 10))
check('undo restores the formula preview', typedMathHost.querySelectorAll('.katex').length === 1)
typedMath.destroy()
typedMathHost.remove()


for (const [label, formula, card] of [
  ['multiline dollars', '$$\n\\frac{1}{x}\n$$', true],
  ['single-line dollars', '$$ \\frac{1}{x} $$', true],
  ['quoted dollars', '> $$\n> \\frac{1}{x}\n> $$', true],
  ['listed dollars', '- $$\n  \\frac{1}{x}\n  $$', true],
  ['inline math', 'Inline $\\frac{1}{x}$ text.', false],
  ['display math within prose', 'Before $$ \\frac{1}{x} $$ after.', false],
]) {
  const host = document.createElement('div')
  document.body.append(host)
  const source = formula + '\n\nAfter'
  const editor = window.MDEditor.create(host, source, {})
  editor.focus()
  editor.select(source.indexOf('frac') + 2)
  await new Promise(resolve => setTimeout(resolve, 20))
  check(`${label}: source uses the expected card`, !!host.querySelector('.cm-md-code-card') === card)
  check(`${label}: no language picker for dollar math`, !host.querySelector('.cm-md-code-language-input'))
  if (label === 'inline math') check('active inline math reuses the inline-code content span',
    host.querySelector('.cm-md-inline-code')?.textContent === '\\frac{1}{x}')
  if (card) check(`${label}: both delimiters stay visible`,
    [...host.querySelectorAll('.cm-md-fence-info')].map(node => node.textContent).join('') === '$$$$')
  check(`${label}: dollar source has no toolbar`, !host.querySelector('.cm-md-code-action'))
  const closing = source.lastIndexOf('$$')
  if (card) {
    editor.insertTextAt('', closing, closing + 2)
    check(`${label}: deleting the closer leaves editable source`, !host.querySelector('.math')
      && editor.getMarkdown() === source.slice(0, closing) + source.slice(closing + 2))
    host.querySelector('.cm-content').dispatchEvent(new dom.window.KeyboardEvent('keydown', {
      key: 'z', code: 'KeyZ', ctrlKey: true, bubbles: true, cancelable: true,
    }))
    check(`${label}: undo restores exact delimiters`, editor.getMarkdown() === source)
  }
  editor.select(source.length)
  await new Promise(resolve => setTimeout(resolve, 10))
  check(`${label}: leaving source restores only the equation`, !!host.querySelector('.katex')
    && !host.querySelector('.cm-md-code-card') && editor.getMarkdown() === source)
  editor.destroy()
  host.remove()
}

for (const [label, initial, position, expected] of [
  ['empty document', '', 0, '$$\n\n$$'],
  ['after prose', 'Intro\n\n', 7, 'Intro\n\n$$\n\n$$'],
  ['existing closer', '\nx\n$$', 0, '$$\n\nx\n$$'],
  ['closing an existing block', '$$\nx\n', 5, '$$\nx\n$$\n'],
  ['inside code', '```text\n\n```', 8, '```text\n$$\n\n```'],
  ['inside prose', 'Text ', 5, 'Text $$\n'],
]) {
  const host = document.createElement('div')
  document.body.append(host)
  const editor = window.MDEditor.create(host, initial, {})
  editor.select(position)
  for (const character of '$$') editor.insert(character)
  check(`typing dollars does not expand: ${label}`, editor.getMarkdown() === initial.slice(0, position) + '$$' + initial.slice(position))
  host.querySelector('.cm-content').dispatchEvent(new dom.window.KeyboardEvent('keydown', {
    key: 'Enter', code: 'Enter', bubbles: true, cancelable: true,
  }))
  check(`dollar completion: ${label}`, editor.getMarkdown() === expected)
  if (label === 'empty document') {
    editor.insert('x')
    check('dollar completion puts typing inside the delimiters', editor.getMarkdown() === '$$\nx\n$$')
    host.querySelector('.cm-content').dispatchEvent(new dom.window.KeyboardEvent('keydown', {
      key: 'z', code: 'KeyZ', ctrlKey: true, bubbles: true, cancelable: true,
    }))
    check('undoing math input retains the empty paired block', editor.getMarkdown() === '$$\n\n$$')
    host.querySelector('.cm-content').dispatchEvent(new dom.window.KeyboardEvent('keydown', {
      key: 'z', code: 'KeyZ', ctrlKey: true, bubbles: true, cancelable: true,
    }))
    check('undoing dollar completion leaves no orphan closer', editor.getMarkdown() === '$$')
  }
  editor.destroy()
  host.remove()
}

const singleMathHost = document.createElement('div')
document.body.append(singleMathHost)
const singleMath = window.MDEditor.create(singleMathHost, '', {})
for (const character of '$$ equation $$') singleMath.insert(character)
check('typing a complete single-line formula preserves its layout', singleMath.getMarkdown() === '$$ equation $$')
singleMath.destroy()
singleMathHost.remove()

// Exercise the production loader without requiring a network or duplicating it.
const editorSwift = readFileSync(new URL('../../md-preview/Features/Editor/EditorHTML.swift', import.meta.url), 'utf8')
const mathLoaderMatch = editorSwift.match(/window\.__mdLoadMath = function \(\) \{[\s\S]*?\n\s*\};/)
if (!mathLoaderMatch) throw new Error("Could not extract window.__mdLoadMath from EditorHTML.swift")
const mathLoader = mathLoaderMatch[0]
dom.window.eval(mathLoader
  .replace(/css.href = .*?;/, "css.href = 'math-test.css';")
  .replace(/script.src = .*?;/, "script.src = 'math-test.js';"))
const failedLoad = window.__mdLoadMath()
const caughtFailure = failedLoad.catch(error => error)
const loadError = new dom.window.Event('error')
document.querySelector('link[href="math-test.css"]').dispatchEvent(loadError)
check('math loader propagates asset failures', await caughtFailure === loadError)
check('math loader removes failed asset elements', !document.querySelector('[href="math-test.css"], [src="math-test.js"]'))
const retryLoad = window.__mdLoadMath()
check('math loader retries after failure', retryLoad !== failedLoad)
document.querySelector('link[href="math-test.css"]').dispatchEvent(new dom.window.Event('load'))
document.querySelector('script[src="math-test.js"]').dispatchEvent(new dom.window.Event('load'))
await retryLoad
check('math loader caches successful loads', window.__mdLoadMath() === retryLoad)

process.exit(failures ? 1 : 0)
