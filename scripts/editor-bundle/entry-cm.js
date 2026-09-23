// Typora-style live-preview markdown editor for Markdown Preview.app.
// Bundled with esbuild into a single self-contained IIFE exposing
// window.MDEditor. The document buffer IS the markdown source — saving
// is byte-faithful. Formatting syntax is styled live and marks hide
// themselves unless the cursor is inside the construct.

import {
  EditorView, keymap, ViewPlugin, Decoration, WidgetType, dropCursor,
} from "@codemirror/view"
import { Annotation, EditorState, EditorSelection, MapMode, Prec, StateEffect, StateField, Transaction } from "@codemirror/state"
import {
  defaultKeymap, history, historyKeymap, indentLess, insertTab,
} from "@codemirror/commands"
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete"
import { markdown, markdownLanguage, markdownKeymap } from "@codemirror/lang-markdown"
import { yamlFrontmatter } from "@codemirror/lang-yaml"
import {
  syntaxTree, syntaxTreeAvailable, ensureSyntaxTree, syntaxHighlighting, HighlightStyle,
  indentUnit, LanguageDescription, LanguageSupport, StreamLanguage,
} from "@codemirror/language"
import { highlightTree, tags as t } from "@lezer/highlight"
import { javascript } from "@codemirror/lang-javascript"
import { python } from "@codemirror/lang-python"
import { json } from "@codemirror/lang-json"
import { css } from "@codemirror/lang-css"
import { html } from "@codemirror/lang-html"
import { swift } from "@codemirror/legacy-modes/mode/swift"
import { shell } from "@codemirror/legacy-modes/mode/shell"
import { yaml } from "@codemirror/legacy-modes/mode/yaml"
import { go } from "@codemirror/legacy-modes/mode/go"
import { ruby } from "@codemirror/legacy-modes/mode/ruby"
import { rust } from "@codemirror/legacy-modes/mode/rust"
import { c, cpp, java, kotlin, objectiveC, csharp } from "@codemirror/legacy-modes/mode/clike"
import { sql } from "@codemirror/legacy-modes/mode/sql"
import { toml } from "@codemirror/legacy-modes/mode/toml"
import { hcl } from "codemirror-lang-hcl"

// ---------------------------------------------------------------------------
// Fenced-code languages
// ---------------------------------------------------------------------------

// Keep automatic detection conservative. Explicit info-string languages
// always remain the source of truth.
function detectLanguage(source) {
  const text = source.trim()
  if (!text) return ""
  if (/^#!.*\b(?:ba)?sh\b|^\s*\$\s+/.test(text)) return "bash"
  if ((text.startsWith("{") && text.endsWith("}"))
      || (text.startsWith("[") && text.endsWith("]"))) {
    try { JSON.parse(text); return "json" } catch (_) {}
  }
  if (/^\s*(?:<!DOCTYPE\s+html|<html\b|<(?:div|span|section|article)\b)/i.test(text)) return "html"
  if (/\b(?:resource|data|provider|variable|module)\s+["'][\w-]+["'](?:\s+["'][\w-]+["'])?\s*\{|\bterraform\s*\{/.test(text)) return "hcl"
  if (/\b(?:import\s+Foundation|func\s+\w+\s*\(|@main)\b|\b(?:let|var)\s+\w+\s*:\s*(?:String|Int|Bool|Double|Float)\b/.test(text)) return "swift"
  if (/^\s*(?:#\s*include\s*<iostream>|(?:using\s+namespace\s+std|std::\w+|(?:cout|cin)\s*(?:<<|>>))\b)/m.test(text)) return "cpp"
  if (/^\s*(?:#\s*include\s*[<"](?:assert|ctype|errno|float|inttypes|limits|math|setjmp|signal|stdarg|stdbool|stddef|stdint|stdio|stdlib|string|time)\.h[>"]|(?:int|void)\s+main\s*\([^)]*\)\s*\{)/m.test(text)) return "c"
  if (/^\s*(?:async\s+)?def\s+\w+\s*\(|^\s*from\s+\w+[\w.]*\s+import\b|^\s*class\s+\w+\s*[:(]/m.test(text)) return "python"
  if (/\b(?:SELECT|INSERT|UPDATE|DELETE|CREATE\s+(?:TABLE|VIEW|INDEX)|WITH)\b[\s\S]*\b(?:FROM|INTO|WHERE|AS)\b/i.test(text)) return "sql"
  if (/(?:^|\n)\s*(?:[#.]?[A-Za-z][\w-]*)\s*\{[\s\S]*:[\s\S]*\}/.test(text)
      || /@(?:media|keyframes|supports)\b/.test(text)) return "css"
  if (/^\s*(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*(?::[^=\n]+)?\s*=/m.test(text)
      || /\b(?:function\s+\w+\s*\(|console\.(?:log|error|warn)|=>)/.test(text)) return "javascript"
  if (/^\s*(?:[-A-Za-z_][\w-]*):\s*(?:[^:#\n]|$)/m.test(text)
      && !/[{};]/.test(text)) return "yaml"
  if (/^\s*(?:echo|printf|export|source|cd|mkdir|rm|cp|mv)\s+/m.test(text)) return "bash"
  return ""
}

// Every parser is already part of this offline bundle, so register support
// synchronously. Lazy Promise loaders only delayed highlighting on the first
// fenced block without reducing the shipped JavaScript.
const legacy = (name, alias, parser) =>
  LanguageDescription.of({
    name,
    alias,
    support: new LanguageSupport(StreamLanguage.define(parser)),
  })

const codeLanguages = [
  LanguageDescription.of({
    name: "javascript",
    alias: ["js", "jsx", "ts", "tsx", "typescript", "node"],
    support: javascript({ jsx: true, typescript: true }),
  }),
  LanguageDescription.of({ name: "python", alias: ["py"], support: python() }),
  LanguageDescription.of({ name: "json", alias: ["jsonc"], support: json() }),
  LanguageDescription.of({ name: "css", alias: ["scss"], support: css() }),
  LanguageDescription.of({ name: "html", alias: ["htm", "xml"], support: html() }),
  LanguageDescription.of({ name: "hcl", alias: ["terraform", "tf"], support: hcl() }),
  legacy("swift", [], swift),
  legacy("shell", ["sh", "bash", "zsh", "console"], shell),
  legacy("yaml", ["yml"], yaml),
  legacy("go", ["golang"], go),
  legacy("ruby", ["rb"], ruby),
  legacy("rust", ["rs"], rust),
  legacy("c", ["h"], c),
  legacy("cpp", ["c++", "cc", "hpp"], cpp),
  legacy("java", [], java),
  legacy("kotlin", ["kt"], kotlin),
  legacy("objective-c", ["objc", "objectivec"], objectiveC),
  legacy("csharp", ["cs", "c#"], csharp),
  legacy("sql", [], sql({})),
  legacy("toml", [], toml),
]

// ---------------------------------------------------------------------------
// Obsidian-style text highlights
// ---------------------------------------------------------------------------

const highlightDelimiter = { resolve: "Highlight", mark: "HighlightMark" }
const highlightPunctuation = /[\p{S}\p{P}]/u

function highlightWhitespace(value) {
  return !value || /\s/.test(value)
}

function highlightPunctuationAround(value) {
  return !!value && highlightPunctuation.test(value)
}

// Lezer's delimiter resolver then handles nesting with emphasis, links, and
// adjacent highlights. Keeping the parser extension here (rather than
// matching the DOM after parsing) also means code spans and fenced code are
// naturally excluded by the Markdown grammar.
const obsidianHighlight = {
  defineNodes: ["Highlight", "HighlightMark"],
  parseInline: [{
    name: "Highlight",
    parse(cx, next, pos) {
      if (next !== 61 || cx.char(pos + 1) !== 61) return -1
      let runStart = pos
      while (runStart > cx.offset && cx.char(runStart - 1) === 61) runStart--
      let runEnd = pos + 2
      while (cx.char(runEnd) === 61) runEnd++
      const pairStart = runStart + ((runEnd - runStart) % 2)
      if (pos < pairStart || (pos - pairStart) % 2 !== 0) return -1
      let backslashes = 0
      for (let cursor = runStart - 1;
           cursor >= cx.offset && cx.char(cursor) === 92;
           cursor--) {
        backslashes++
      }
      if (backslashes % 2 !== 0) return -1
      const before = cx.slice(runStart - 1, runStart)
      const after = cx.slice(runEnd, runEnd + 1)
      const spaceBefore = highlightWhitespace(before)
      const spaceAfter = highlightWhitespace(after)
      const punctuationBefore = highlightPunctuationAround(before)
      const punctuationAfter = highlightPunctuationAround(after)
      const leftFlanking = !spaceAfter
        && (!punctuationAfter || spaceBefore || punctuationBefore)
      const rightFlanking = !spaceBefore
        && (!punctuationBefore || spaceAfter || punctuationAfter)
      return cx.addDelimiter(
        highlightDelimiter,
        pos,
        pos + 2,
        leftFlanking,
        rightFlanking,
      )
    },
    after: "Emphasis",
  }],
}

// ---------------------------------------------------------------------------
// Live preview decorations
// ---------------------------------------------------------------------------

class TextWidget extends WidgetType {
  constructor(text, className) { super(); this.text = text; this.className = className }
  eq(other) { return other.text === this.text && other.className === this.className }
  toDOM() {
    const span = document.createElement("span")
    span.textContent = this.text
    span.className = this.className
    return span
  }
  ignoreEvent() { return false }
}

class ImageWidget extends WidgetType {
  constructor(source, alt, raw, from, to) {
    super()
    this.source = source
    this.alt = alt
    this.raw = raw
    this.from = from
    this.to = to
  }

  eq(other) {
    return other.source === this.source
      && other.alt === this.alt
      && other.raw === this.raw
      && other.from === this.from
      && other.to === this.to
  }

  toDOM(view) {
    const root = document.createElement("span")
    root.className = "cm-md-image-preview"
    root.setAttribute("role", "figure")

    const image = document.createElement("img")
    image.src = this.source
    image.alt = this.alt
    image.draggable = false
    image.addEventListener("error", () => root.classList.add("cm-md-image-error"), { once: true })

    const source = document.createElement("code")
    source.className = "cm-md-image-source"
    source.textContent = this.raw
    source.title = "Click to edit image source"

    const revealSource = (event) => {
      event.preventDefault()
      event.stopPropagation()
      view.focus()
      view.dispatch({
        selection: { anchor: Math.min(this.from + 2, this.to) },
        userEvent: "select.pointer",
      })
    }
    source.addEventListener("mousedown", revealSource)
    source.addEventListener("click", revealSource)
    image.addEventListener("mousedown", (event) => {
      event.preventDefault()
      event.stopPropagation()
    })
    image.addEventListener("click", (event) => {
      event.preventDefault()
      event.stopPropagation()
      const resolved = image.currentSrc || image.src
      if (resolved.startsWith("md-asset:")) {
        window.__mdRequestImageRename?.(resolved)
      } else {
        revealSource(event)
      }
    })

    root.append(image, source)
    return root
  }

  ignoreEvent() { return true }
}

class RuleWidget extends WidgetType {
  eq() { return true }
  toDOM() {
    const el = document.createElement("span")
    el.className = "cm-md-hr"
    return el
  }
  ignoreEvent() { return false }
}

let mermaidWidgetID = 0

class MermaidWidget extends WidgetType {
  constructor(source) { super(); this.source = source }
  eq(other) { return other.source === this.source }

  toDOM(view) {
    const figure = document.createElement("figure")
    figure.className = "cm-md-mermaid-preview"
    figure.setAttribute("role", "img")
    figure.setAttribute("aria-label", "Mermaid diagram. Click to edit source.")

    const stage = document.createElement("div")
    stage.className = "cm-md-mermaid-stage"
    stage.textContent = "Rendering diagram…"
    figure.appendChild(stage)

    figure.addEventListener("mousedown", (event) => {
      event.preventDefault()
      view.focus()
      const widgetPosition = view.posAtDOM(figure)
      view.dispatch({
        selection: { anchor: widgetPosition + 1 },
        userEvent: "select.pointer",
      })
    })

    const mermaid = window.mermaid
    if (!mermaid || typeof mermaid.render !== "function") {
      stage.textContent = "Mermaid preview unavailable. Click to edit source."
      return figure
    }

    const id = `md-editor-mermaid-${++mermaidWidgetID}`
    Promise.resolve(mermaid.render(id, this.source))
      .then(({ svg }) => {
        stage.innerHTML = svg
        const diagram = stage.querySelector("svg")
        const box = diagram?.viewBox?.baseVal
        if (diagram && box?.width > 0 && box?.height > 0) {
          figure.style.setProperty("--mm-aspect", `${box.width} / ${box.height}`)
          diagram.removeAttribute("width")
          diagram.removeAttribute("height")
          diagram.setAttribute("preserveAspectRatio", "xMidYMid meet")
          diagram.style.width = "100%"
          diagram.style.height = "100%"
        }
        view.requestMeasure()
      })
      .catch(() => {
        stage.textContent = "Unable to render Mermaid diagram. Click to edit source."
        figure.classList.add("cm-md-mermaid-error")
        view.requestMeasure()
      })
    return figure
  }

  ignoreEvent() { return true }
}

// Language input widget for every fenced block, including blocks without an
// info string. The source range is rebuilt after each commit, so the widget
// remains anchored while its input edits the opening line.
const codeCopyHandlers = new WeakMap()
const toggleCodeWrap = StateEffect.define({ map: (pos, changes) => changes.mapPos(pos, 1, MapMode.TrackAfter) ?? undefined })
const wrappedCodeBlocks = StateField.define({
  create: () => new Set(),
  update(value, tr) {
    if (!tr.docChanged && !tr.effects.some(e => e.is(toggleCodeWrap))) return value
    const next = new Set([...value].map(pos => tr.changes.mapPos(pos, 1, MapMode.TrackAfter)).filter(pos => pos != null))
    for (const effect of tr.effects) if (effect.is(toggleCodeWrap)) {
      if (next.has(effect.value)) next.delete(effect.value)
      else next.add(effect.value)
    }
    return next
  },
})
const codeActionIcon = (kind) => '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ({
  copy: '<rect x="4" y="8" width="12" height="13" rx="3"/><path d="M8 8V6a3 3 0 0 1 3-3h6a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-1"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  wrap: '<path d="M4 6h16M4 11h12a4 4 0 0 1 0 8h-5m3-3-3 3 3 3M4 16h3"/>',
  unwrap: '<path d="M4 6h16M4 12h16m-4-4 4 4-4 4M4 18h7"/>'
})[kind] + '</svg>'

class CodeLanguageWidget extends WidgetType {
  constructor(details) {
    super()
    Object.assign(this, details)
  }

  eq(other) {
    return other.fenceFrom === this.fenceFrom
      && other.infoFrom === this.infoFrom
      && other.infoTo === this.infoTo
      && other.rawInfo === this.rawInfo
      && other.detectedLanguage === this.detectedLanguage
      && other.wrapped === this.wrapped
      && other.plain === this.plain
  }

  toDOM(view) {
    const container = document.createElement("span")
    container.className = "cm-md-code-language"
    container.contentEditable = "false"

    const input = document.createElement("input")
    input.type = "text"
    input.className = "cm-md-code-language-input"
    input.autocomplete = "off"
    input.spellcheck = false
    input.value = this.language
    input.readOnly = !!this.plain
    input.placeholder = "language"
    input.setAttribute("aria-label", "Code block language")
    input.dataset.fenceFrom = String(this.fenceFrom)

    const metadata = this.rawInfo.match(/^\S+([\s\S]*)$/)?.[1] || ""
    const initialDisplayValue = input.value
    let commitOnBlur = true
    let dispatchingCommit = false
    const commit = () => {
      if (this.plain) return
      const language = input.value.trim().split(/\s+/, 1)[0].toLowerCase()
      const nextInfo = language
        ? language + metadata
        : ""
      if (nextInfo === this.rawInfo) return
      if (input.value === initialDisplayValue) return
      dispatchingCommit = true
      view.dispatch({
        changes: { from: this.infoFrom, to: this.infoTo, insert: nextInfo },
        userEvent: "input",
      })
    }

    input.addEventListener("change", commit)
    input.addEventListener("keydown", (event) => {
      event.stopPropagation()
      if (event.key === "Enter") {
        event.preventDefault()
        commit()
        input.blur()
        view.focus()
      } else if (event.key === "Escape") {
        event.preventDefault()
        commitOnBlur = false
        input.value = this.language
        input.blur()
        view.focus()
      }
    })
    input.addEventListener("mousedown", (event) => event.stopPropagation())
    input.addEventListener("click", (event) => event.stopPropagation())
    input.addEventListener("blur", () => {
      if (commitOnBlur && !dispatchingCommit) commit()
      dispatchingCommit = false
      commitOnBlur = true
    })

    container.appendChild(input)
    const action = (label, icon, className, run) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = `cm-md-code-action ${className}`
      button.title = label
      button.setAttribute('aria-label', label)
      button.innerHTML = codeActionIcon(icon)
      button.addEventListener('mousedown', event => { event.preventDefault(); event.stopPropagation() })
      button.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); run(button) })
      container.appendChild(button)
      return button
    }
    const toggle = action(this.wrapped ? 'Unwrap code' : 'Wrap code', this.wrapped ? 'unwrap' : 'wrap',
      'cm-md-code-toggle-wrap', () => view.dispatch({
        effects: toggleCodeWrap.of(view.state.doc.lineAt(this.fenceFrom).from),
      }))
    toggle.setAttribute('aria-pressed', String(this.wrapped))
    action('Copy code', 'copy', 'cm-md-code-copy', async button => {
      const line = view.state.doc.lineAt(this.fenceFrom)
      let node = syntaxTree(view.state).resolve(this.plain ? line.to : this.fenceFrom + 1, -1)
      while (node && node.name !== (this.plain ? 'CodeBlock' : 'FencedCode')) node = node.parent
      if (!node) return
      const source = this.plain
        ? node.getChildren('CodeText').map(text => view.state.sliceDoc(text.from, text.to)).join('')
        : fencedCodeDetails(view.state, node).source
      try {
        const handler = codeCopyHandlers.get(view)
        if (handler) handler(source)
        else await navigator.clipboard.writeText(source)
        button.innerHTML = codeActionIcon('check')
        button.title = 'Code copied'
        button.setAttribute('aria-label', button.title)
        clearTimeout(button.copyTimer)
        button.copyTimer = setTimeout(() => {
          button.innerHTML = codeActionIcon('copy')
          button.title = 'Copy code'
          button.setAttribute('aria-label', button.title)
        }, 1100)
      } catch (_) { /* Leave the copy action available when the clipboard is unavailable. */ }
    })
    return container
  }

  ignoreEvent() { return true }
}

// ---------------------------------------------------------------------------
// Visual table editor
// ---------------------------------------------------------------------------

function splitTableRow(source) {
  const cells = []
  let cell = ""
  let backslashes = 0
  let codeFenceLength = 0
  for (let index = 0; index < source.length;) {
    const character = source[index]
    if (character === "`" && backslashes % 2 === 0) {
      let end = index + 1
      while (end < source.length && source[end] === "`") end++
      const runLength = end - index
      if (codeFenceLength === 0) codeFenceLength = runLength
      else if (codeFenceLength === runLength) codeFenceLength = 0
      cell += source.slice(index, end)
      index = end
      backslashes = 0
      continue
    }
    if (character === "|" && backslashes % 2 === 0 && codeFenceLength === 0) {
      cells.push(cell.trim())
      cell = ""
    } else {
      cell += character
    }
    backslashes = character === "\\" ? backslashes + 1 : 0
    index++
  }
  cells.push(cell.trim())
  const trimmed = source.trim()
  if (trimmed.startsWith("|") && cells[0] === "") cells.shift()
  if (trimmed.endsWith("|") && cells[cells.length - 1] === "") cells.pop()
  return cells
}

function parseTableAlignment(cell) {
  const token = cell.trim()
  const left = token.startsWith(":")
  const right = token.endsWith(":")
  const hyphens = token.replace(/^:/, "").replace(/:$/, "")
  if (!/^-{3,}$/.test(hyphens)) return null
  if (left && right) return "center"
  if (left) return "left"
  if (right) return "right"
  return "none"
}

function parseTableSource(source) {
  const trailingNewline = source.endsWith("\n")
  const lines = source.replace(/\n$/, "").split("\n")
  if (lines.length < 2) return null
  const header = splitTableRow(lines[0])
  const alignments = splitTableRow(lines[1]).map(parseTableAlignment)
  if (!header.length || !alignments.length || alignments.some((item) => item == null)) return null
  const rows = [header, ...lines.slice(2).map(splitTableRow)]
  const columnCount = Math.max(alignments.length, ...rows.map((row) => row.length))
  while (alignments.length < columnCount) alignments.push("none")
  alignments.length = columnCount
  for (const row of rows) {
    while (row.length < columnCount) row.push("")
    row.length = columnCount
  }
  return { rows, alignments, trailingNewline }
}

function escapedTableCell(source) {
  const flattened = source.replace(/\n+/g, " ").trim()
  let result = ""
  let backslashes = 0
  let codeFenceLength = 0
  for (let index = 0; index < flattened.length;) {
    const character = flattened[index]
    if (character === "`" && backslashes % 2 === 0) {
      let end = index + 1
      while (end < flattened.length && flattened[end] === "`") end++
      const runLength = end - index
      if (codeFenceLength === 0) codeFenceLength = runLength
      else if (codeFenceLength === runLength) codeFenceLength = 0
      result += flattened.slice(index, end)
      index = end
      backslashes = 0
      continue
    }
    if (character === "|" && backslashes % 2 === 0 && codeFenceLength === 0) result += "\\"
    result += character
    backslashes = character === "\\" ? backslashes + 1 : 0
    index++
  }
  return result
}

function serializeTable(model) {
  const widths = model.alignments.map((_, column) => Math.max(
    3,
    ...model.rows.map((row) => Array.from(row[column] || "").length),
  ))
  const dataRow = (cells) => "| " + cells.map((cell, column) => {
    const escaped = escapedTableCell(cell)
    return escaped + " ".repeat(Math.max(0, widths[column] - Array.from(escaped).length))
  }).join(" | ") + " |"
  const delimiter = "| " + model.alignments.map((alignment, column) => {
    const width = widths[column]
    if (alignment === "left") return ":" + "-".repeat(Math.max(3, width - 1))
    if (alignment === "right") return "-".repeat(Math.max(3, width - 1)) + ":"
    if (alignment === "center") return ":" + "-".repeat(Math.max(3, width - 2)) + ":"
    return "-".repeat(width)
  }).join(" | ") + " |"
  const lines = [dataRow(model.rows[0]), delimiter, ...model.rows.slice(1).map(dataRow)]
  return lines.join("\n") + (model.trailingNewline ? "\n" : "")
}

let nextTableContextToken = 1
let pendingTableContextAction = null

// Inactive cells render code spans; focused cells expose their original
// Markdown. Build DOM nodes rather than interpreting cell contents as HTML.
function renderTableCellCode(element, source) {
  element.replaceChildren()
  let offset = 0
  if (source.includes('`')) markdownLanguage.parser.parse(source).iterate({
    enter(node) {
      if (node.name !== 'InlineCode') return
      element.append(document.createTextNode(source.slice(offset, node.from)))
      const code = document.createElement('code')
      code.className = 'cm-md-inline-code'
      let text = source.slice(node.node.firstChild.to, node.node.lastChild.from).replace(/\n/g, ' ')
      if (text.startsWith(' ') && text.endsWith(' ') && /[^ ]/.test(text)) text = text.slice(1, -1)
      code.textContent = text
      element.append(code)
      offset = node.to
      return false
    },
  })
  element.append(document.createTextNode(source.slice(offset)))
}

class TableEditorWidget extends WidgetType {
  constructor(source, from) {
    super()
    this.source = source
    this.from = from
  }

  eq(other) { return other.source === this.source && other.from === this.from }

  toDOM(view) {
    const model = parseTableSource(this.source)
    const root = document.createElement("div")
    root.className = "cm-md-table-widget"
    root.dataset.tableFrom = String(this.from)
    if (!model) {
      root.textContent = this.source
      return root
    }

    let active = null
    let selectedPart = null
    let cellDrag = null
    let suppressNextTableClick = false
    const scroll = document.createElement("div")
    scroll.className = "cm-md-table-scroll"
    root.appendChild(scroll)
    const table = document.createElement("table")
    table.className = "cm-md-table-grid"
    scroll.appendChild(table)

    const focusCellAfterUpdate = (row, column) => {
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const replacement = view.dom.querySelector(
          `.cm-md-table-widget[data-table-from="${this.from}"]`
        )
        const cell = replacement && replacement.querySelector(
          `[data-table-row="${row}"][data-table-column="${column}"]`
        )
        cell?.focus()
      }))
    }

    const applyModel = (focusTarget = null) => {
      const source = serializeTable(model)
      if (source === this.source) {
        if (focusTarget) {
          root.querySelector(
            `[data-table-row="${focusTarget.row}"][data-table-column="${focusTarget.column}"]`
          )?.focus()
        }
        return
      }
      active = null
      view.dispatch({
        changes: { from: this.from, to: this.from + this.source.length, insert: source },
        userEvent: "input",
      })
      if (focusTarget) focusCellAfterUpdate(focusTarget.row, focusTarget.column)
    }

    const captureActiveValue = () => {
      if (!active || active.element.dataset.tableEditing !== 'true') return
      model.rows[active.row][active.column] = active.element.innerText || ""
    }

    const clearPartSelection = () => {
      root.querySelectorAll(".is-table-part-selected").forEach((cell) => {
        cell.classList.remove(
          "is-table-part-selected",
          "is-table-selection-top",
          "is-table-selection-right",
          "is-table-selection-bottom",
          "is-table-selection-left",
        )
      })
      root.classList.remove(
        "is-table-row-selected",
        "is-table-column-selected",
        "is-table-range-selected",
      )
      root.removeAttribute("aria-label")
      selectedPart = null
    }

    const applyTableSelection = (kind, bounds, anchor) => {
      captureActiveValue()
      clearPartSelection()
      const cells = Array.from(root.querySelectorAll(".cm-md-table-cell")).filter((cell) => {
        const row = Number(cell.dataset.tableRow)
        const column = Number(cell.dataset.tableColumn)
        return row >= bounds.top && row <= bounds.bottom
          && column >= bounds.left && column <= bounds.right
      })
      cells.forEach((cell) => {
        cell.classList.add("is-table-part-selected")
        const row = Number(cell.dataset.tableRow)
        const column = Number(cell.dataset.tableColumn)
        if (row === bounds.top) cell.classList.add("is-table-selection-top")
        if (column === bounds.right) cell.classList.add("is-table-selection-right")
        if (row === bounds.bottom) cell.classList.add("is-table-selection-bottom")
        if (column === bounds.left) cell.classList.add("is-table-selection-left")
      })
      root.classList.add(
        kind === "row"
          ? "is-table-row-selected"
          : kind === "column"
            ? "is-table-column-selected"
            : "is-table-range-selected",
      )
      window.getSelection()?.removeAllRanges()
      selectedPart = { kind, row: anchor.row, column: anchor.column, bounds }
      root.tabIndex = 0
      if (kind === "range") {
        const rowCount = bounds.bottom - bounds.top + 1
        const columnCount = bounds.right - bounds.left + 1
        root.setAttribute("aria-label", `Selected ${rowCount} rows by ${columnCount} columns.`)
      } else {
        const number = kind === "row" ? anchor.row : anchor.column + 1
        root.setAttribute(
          "aria-label",
          `Selected ${kind} ${number}. Press Delete to remove it.`
        )
      }
      root.focus()
    }

    const selectTablePart = (kind, row, column) => {
      const bounds = kind === "row"
        ? { top: row, right: model.alignments.length - 1, bottom: row, left: 0 }
        : { top: 0, right: column, bottom: model.rows.length - 1, left: column }
      applyTableSelection(kind, bounds, { row, column })
    }

    const selectTableRange = (anchorRow, anchorColumn, headRow, headColumn) => {
      applyTableSelection("range", {
        top: Math.min(anchorRow, headRow),
        right: Math.max(anchorColumn, headColumn),
        bottom: Math.max(anchorRow, headRow),
        left: Math.min(anchorColumn, headColumn),
      }, { row: anchorRow, column: anchorColumn })
    }

    const performAction = (action, row, column) => {
      captureActiveValue()
      if (action === "selectRow" && row > 0) {
        selectTablePart("row", row, column)
      } else if (action === "selectColumn" && model.alignments.length > 1) {
        selectTablePart("column", row, column)
      } else if (action === "insertRowBefore" && row > 0) {
        model.rows.splice(row, 0, Array(model.alignments.length).fill(""))
        applyModel({ row, column })
      } else if (action === "insertRowAfter") {
        model.rows.splice(row + 1, 0, Array(model.alignments.length).fill(""))
        applyModel({ row: row + 1, column })
      } else if (action === "duplicateRow" && row > 0) {
        model.rows.splice(row + 1, 0, [...model.rows[row]])
        applyModel({ row: row + 1, column })
      } else if (action === "deleteRow" && row > 0) {
        model.rows.splice(row, 1)
        applyModel({ row: Math.min(row, model.rows.length - 1), column })
      } else if (action === "insertColumnBefore") {
        for (const cells of model.rows) cells.splice(column, 0, "")
        model.alignments.splice(column, 0, "none")
        applyModel({ row, column })
      } else if (action === "insertColumnAfter") {
        for (const cells of model.rows) cells.splice(column + 1, 0, "")
        model.alignments.splice(column + 1, 0, "none")
        applyModel({ row, column: column + 1 })
      } else if (action === "deleteColumn" && model.alignments.length > 1) {
        for (const cells of model.rows) cells.splice(column, 1)
        model.alignments.splice(column, 1)
        applyModel({ row, column: Math.min(column, model.alignments.length - 1) })
      }
    }

    model.rows.forEach((cells, row) => {
      const tr = document.createElement("tr")
      table.appendChild(tr)
      cells.forEach((value, column) => {
        const container = document.createElement(row === 0 ? "th" : "td")
        const editor = document.createElement("div")
        editor.className = "cm-md-table-cell"
        editor.contentEditable = "plaintext-only"
        editor.spellcheck = true
        renderTableCellCode(editor, value)
        editor.dataset.tableRow = String(row)
        editor.dataset.tableColumn = String(column)
        if (row === 0) {
          const placeholder = `Column ${column + 1}`
          editor.dataset.placeholder = placeholder
          const updateAccessibilityLabel = () => {
            if ((editor.innerText || "").trim()) editor.removeAttribute("aria-label")
            else editor.setAttribute("aria-label", placeholder)
          }
          updateAccessibilityLabel()
          editor.addEventListener("input", updateAccessibilityLabel)
        }
        if (model.alignments[column] !== "none") editor.style.textAlign = model.alignments[column]
        editor.addEventListener("focus", () => {
          clearPartSelection()
          editor.textContent = model.rows[row][column]
          editor.dataset.tableEditing = 'true'
          active = { row, column, element: editor }
        })
        editor.addEventListener("contextmenu", (event) => {
          event.preventDefault()
          active = { row, column, element: editor }
          const token = String(nextTableContextToken++)
          pendingTableContextAction = {
            token,
            perform: (action) => performAction(action, row, column),
          }
          window.__mdRequestTableContextMenu?.({
            token,
            canInsertRowAbove: row > 0,
            canDuplicateRow: row > 0,
            canDeleteRow: row > 0,
            canDeleteColumn: model.alignments.length > 1,
            showsDuplicateRow: true,
          })
        })
        editor.addEventListener("blur", () => {
          if (!active || active.element !== editor) return
          const value = editor.innerText || ""
          const changed = value !== model.rows[row][column]
          model.rows[row][column] = value
          active = null
          delete editor.dataset.tableEditing
          renderTableCellCode(editor, model.rows[row][column])
          if (changed) applyModel()
        })
        editor.addEventListener("keydown", (event) => {
          if (event.key === "Escape") {
            event.preventDefault()
            active = null
            editor.blur()
            delete editor.dataset.tableEditing
            renderTableCellCode(editor, model.rows[row][column])
            view.focus()
            return
          }
          if (event.key !== "Tab" && event.key !== "Enter") return
          event.preventDefault()
          model.rows[row][column] = editor.innerText || ""
          const backwards = event.key === "Tab" && event.shiftKey
          let nextRow = row
          let nextColumn = column + (backwards ? -1 : 1)
          if (nextColumn < 0) {
            nextRow--
            nextColumn = model.alignments.length - 1
          } else if (nextColumn >= model.alignments.length) {
            nextRow++
            nextColumn = 0
          }
          if (nextRow < 0) {
            nextRow = 0
            nextColumn = 0
          } else if (nextRow >= model.rows.length) {
            model.rows.push(Array(model.alignments.length).fill(""))
          }
          applyModel({ row: nextRow, column: nextColumn })
        })
        container.appendChild(editor)
        tr.appendChild(container)
      })
    })
    root.addEventListener("mousedown", (event) => {
      if (event.button !== 0) return
      const cell = event.target.closest?.(".cm-md-table-cell")
      if (!cell) return
      const row = Number(cell.dataset.tableRow)
      const column = Number(cell.dataset.tableColumn)
      if (!Number.isInteger(row) || row < 0 || !Number.isInteger(column)) return
      // Keep CodeMirror from replacing the widget while WebKit is tracking the
      // contenteditable gesture. WebKit's native selection begins on mouse
      // down and can't be reliably cancelled after the pointer crosses into a
      // second cell, so ordinary clicks restore their caret on mouse up.
      event.preventDefault()
      event.stopPropagation()
      cellDrag = { cell, row, column, head: cell, active: false }

      const finishCellDrag = (finishEvent) => {
        document.removeEventListener("mousemove", moveCellDrag, true)
        document.removeEventListener("mouseup", finishCellDrag, true)
        const finishedDrag = cellDrag
        if (finishedDrag?.active) {
          finishEvent.preventDefault()
          window.getSelection()?.removeAllRanges()
          suppressNextTableClick = true
        } else if (finishedDrag) {
          finishEvent.preventDefault()
          finishedDrag.cell.focus({ preventScroll: true })
          const selection = window.getSelection()
          let range = document.caretRangeFromPoint?.(
            finishEvent.clientX,
            finishEvent.clientY,
          )
          if (!range || !finishedDrag.cell.contains(range.startContainer)) {
            range = document.createRange()
            range.selectNodeContents(finishedDrag.cell)
            range.collapse(false)
          }
          selection?.removeAllRanges()
          selection?.addRange(range)
          suppressNextTableClick = true
        }
        cellDrag = null
      }
      const moveCellDrag = (moveEvent) => {
        if (!cellDrag) return
        const hitTarget = document.elementFromPoint?.(
          moveEvent.clientX,
          moveEvent.clientY,
        )
        const head = hitTarget?.closest?.(".cm-md-table-cell")
          || moveEvent.target.closest?.(".cm-md-table-cell")
        if (!head || !root.contains(head)) return
        if (head === cellDrag.cell && !cellDrag.active) return
        if (head === cellDrag.head) return
        moveEvent.preventDefault()
        cellDrag.active = true
        cellDrag.head = head
        selectTableRange(
          cellDrag.row,
          cellDrag.column,
          Number(head.dataset.tableRow),
          Number(head.dataset.tableColumn),
        )
      }
      document.addEventListener("mousemove", moveCellDrag, true)
      document.addEventListener("mouseup", finishCellDrag, true)
    }, true)
    root.addEventListener("click", (event) => {
      if (!suppressNextTableClick) return
      suppressNextTableClick = false
      event.preventDefault()
      event.stopPropagation()
    }, true)
    root.addEventListener("keydown", (event) => {
      if (!selectedPart) return
      if (event.key === "Escape") {
        event.preventDefault()
        clearPartSelection()
        view.focus()
        return
      }
      if (event.key !== "Backspace" && event.key !== "Delete") return
      if (selectedPart.kind === "range") {
        event.preventDefault()
        return
      }
      event.preventDefault()
      const selection = selectedPart
      clearPartSelection()
      performAction(
        selection.kind === "row" ? "deleteRow" : "deleteColumn",
        selection.row,
        selection.column
      )
    })
    return root
  }

  ignoreEvent() { return true }
}

// Search the source buffer, including lines outside CodeMirror's mounted DOM.
// Decorations keep highlights visible while the native toolbar owns focus.
const setFind = StateEffect.define()
function findState(doc, query, beginsWith, index = 0) {
  const matches = []
  if (query) {
    const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "giu")
    const text = doc.toString()
    for (const match of text.matchAll(pattern)) {
      const from = match.index
      if (!beginsWith || from === 0 || !/[A-Za-z0-9_]/.test(text[from - 1])) {
        matches.push({ from, to: from + match[0].length })
      }
    }
  }
  index = matches.length ? Math.min(Math.max(index, 0), matches.length - 1) : -1
  const decorations = Decoration.set(matches.map((match, i) =>
    Decoration.mark({ class: i === index ? "cm-find-match cm-find-current" : "cm-find-match" })
      .range(match.from, match.to)))
  return { query, beginsWith, matches, index, decorations }
}
const documentFind = StateField.define({
  create: (state) => findState(state.doc, "", false),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setFind)) {
        const { query, beginsWith, index } = effect.value
        return findState(tr.state.doc, query, beginsWith, index)
      }
    }
    return tr.docChanged
      ? findState(tr.state.doc, value.query, value.beginsWith, value.index)
      : value
  },
  provide: (field) => EditorView.decorations.from(field, (value) => value.decorations),
})
function currentFindTouches(state, from, to) {
  const search = state.field(documentFind)
  const match = search.matches[search.index]
  return !!match && match.from < to && match.to > from
}
const findTheme = EditorView.baseTheme({
  ".cm-find-match": { backgroundColor: "#ffe58a", color: "#201800", borderRadius: "2px" },
  ".cm-find-current": { backgroundColor: "#ffad33", outline: "1px solid #9b5700" },
})

function buildTableEditors(state) {
  const ranges = []
  const tree = ensureSyntaxTree(state, state.doc.length, 80) || syntaxTree(state)
  tree.iterate({
    enter(node) {
      if (node.name !== "Table") return
      if (currentFindTouches(state, node.from, node.to)) return false
      const source = state.doc.sliceString(node.from, node.to)
      if (!parseTableSource(source)) return
      ranges.push(Decoration.replace({
        block: true,
        widget: new TableEditorWidget(source, node.from),
      }).range(node.from, node.to))
      return false
    },
  })
  return Decoration.set(ranges, true)
}

const tableEditors = StateField.define({
  create: buildTableEditors,
  update: (value, transaction) => transaction.docChanged || transaction.effects.some((effect) => effect.is(setFind))
    ? buildTableEditors(transaction.state)
    : value,
  provide: (field) => EditorView.decorations.from(field),
})

const hide = Decoration.replace({})
const bulletDeco = Decoration.replace({ widget: new TextWidget("•", "cm-md-bullet") })
const activeBulletDeco = Decoration.mark({ class: "cm-md-bullet-source" })
// Ordered markers sit in the same hanging box as bullets, right-aligned and
// in the accent color, so item text lines up across list kinds like the
// preview's ::marker. The active marker stays editable source in that box.
const orderedDecoCache = new Map()
const orderedDeco = (mark) => {
  let deco = orderedDecoCache.get(mark)
  if (!deco) {
    deco = Decoration.replace({ widget: new TextWidget(mark, "cm-md-ordered") })
    orderedDecoCache.set(mark, deco)
  }
  return deco
}
const activeOrderedDeco = Decoration.mark({ class: "cm-md-ordered-source" })
const hrDeco = Decoration.replace({ widget: new RuleWidget() })
const ruleLine = Decoration.line({ class: "cm-md-rule-line" })
const markdownListMarker = /^([ \t]*)([-+*]|\d+[.)])([ \t]+|$)/

const joinDeco = Decoration.replace({ widget: new TextWidget(" ", "cm-md-join") })

const HEADING_LINE = {}
const for_ = (i) => Decoration.line({ class: "cm-md-h" + i })
for (let i = 1; i <= 6; i++) HEADING_LINE[i] = for_(i)
const inactiveHeadingLine = Decoration.line({ class: "cm-md-heading-inactive" })
const headingAfterBlankLine = Decoration.line({ class: "cm-md-heading-after-blank" })
const imageLine = Decoration.line({ class: "cm-md-image-line" })
// Inactive fence source lines collapse because the rendered code card owns
// their height.
const collapsedLine = Decoration.line({ class: "cm-md-line-collapsed" })

// Preview block margin-top values in CSS px. The host passes the live values
// from MarkdownHTML.swift (the single source of truth) through
// MDEditor.create's `spacing` option; these defaults only serve headless
// harnesses. The final blank line of a run shrinks to `blankGap` (plus the
// adjacent blocks' semantic margins) so a single authored blank reads like a
// normal paragraph gap; earlier blanks in a run keep their natural
// source-line height, so extra authored blanks still grow the gap.
const METRICS = {
  line: 22.8,
  blankGap: 4,    // final blank of a run (.md-source-blank-line)
  paragraph: 12,  // p / ul / ol / pre / .md-code-wrap
  quote: 18,      // blockquote
  alert: 24,      // .markdown-alert
  table: 24,      // .md-table-scroll
  hr: 12,         // hr (top only; the next block's margin supplies the bottom)
}
const SEPARATOR_BLOCKS = new Set([
  "Paragraph", "FencedCode", "CodeBlock", "Blockquote",
  "BulletList", "OrderedList", "Table", "HorizontalRule", "HTMLBlock",
])
const separatorLineCache = new Map()
const blockSeparatorLine = (height) => {
  let deco = separatorLineCache.get(height)
  if (!deco) {
    deco = Decoration.line({
      class: "cm-md-block-separator",
      attributes: {
        style: `height:${height}px;min-height:0;line-height:${height}px;overflow:hidden;`,
      },
    })
    separatorLineCache.set(height, deco)
  }
  return deco
}
// A block that starts on the line right after another block (no authored
// blank between them) still gets its margin-top in the preview. Mirror it as
// padding-bottom on the previous block's last line; padding, not margin, so
// CodeMirror's per-line height measurement stays exact. The same value is
// exposed as a variable so pseudo-element bars can stop above the gap.
const blockGapLineCache = new Map()
const blockGapLine = (height) => {
  let deco = blockGapLineCache.get(height)
  if (!deco) {
    deco = Decoration.line({
      class: "cm-md-block-gap",
      attributes: { style: `padding-bottom:${height}px;--cm-md-block-gap:${height}px;` },
    })
    blockGapLineCache.set(height, deco)
  }
  return deco
}
// Quotation lines carry their nesting depth: the preview indents each nested
// blockquote by another 1.5em and draws one rule per level. Depth is
// resolved per line after the tree walk, so a line inside two blockquotes
// gets one decoration at depth 2 rather than two competing ones.
const quoteLineCache = new Map()
const quoteLine = (depth, starts, ends, gap) => {
  const key = `${depth}:${starts}:${ends}:${gap}`
  let deco = quoteLineCache.get(key)
  if (!deco) {
    const positions = []
    const images = []
    for (let level = 0; level < depth; level++) {
      positions.push(`calc(0.3em + ${level * 1.5}em) var(--cm-md-quote-top)`)
      images.push("linear-gradient(var(--quote-border), var(--quote-border))")
    }
    deco = Decoration.line({
      class: "cm-md-quote",
      attributes: {
        style: `padding-inline-start:${depth * 1.5}em;`
          + `--cm-md-quote-top:calc(${starts * 0.4}em + ${gap}px);--cm-md-quote-bottom:${ends * 0.4}em;`
          + `background-image:${images.join(",")};`
          + `background-position:${positions.join(",")};`,
      },
    })
    quoteLineCache.set(key, deco)
  }
  return deco
}
// Lines of a list item that carry no marker (a continuation paragraph, a
// nested code block) align with the item text: same depth padding, but no
// hanging indent, and the source indentation is hidden like a nested
// marker's.
const listContinuationLine = Decoration.line({ class: "cm-md-list-continuation" })
const codeLine = Decoration.line({ class: "cm-md-codeblock" })
const codeLineFirst = Decoration.line({ class: "cm-md-codeblock cm-md-codeblock-first" })
const codeLineLast = Decoration.line({ class: "cm-md-codeblock cm-md-codeblock-last" })
const codeScrollText = Decoration.mark({ class: "cm-md-code-scroll-text" })

// Keep CodeMirror's editable lines (and source selection) intact, while each
// code card shares one horizontal offset and one scrollbar on its last line.
const codeBlockScrolling = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view
    this.offsets = new Map()
    this.onScroll = (event) => {
      const line = event.target
      if (!(line instanceof HTMLElement) || !line.dataset.codeScrollGroup) return
      const group = line.dataset.codeScrollGroup
      const offset = line.scrollLeft
      if (this.offsets.get(group) === offset) return
      this.offsets.set(group, offset)
      for (const other of view.contentDOM.querySelectorAll('[data-code-scroll-group]')) {
        if (other.dataset.codeScrollGroup === group) {
          other.scrollLeft = offset
          other.style.setProperty('--code-scroll-offset', `${offset}px`)
        }
      }
    }
    view.contentDOM.addEventListener('scroll', this.onScroll, true)
    this.measure()
  }
  update(update) {
    if (update.docChanged || update.viewportChanged || update.geometryChanged
        || update.startState.field(wrappedCodeBlocks) !== update.state.field(wrappedCodeBlocks)) this.measure()
  }
  measure() {
    this.view.requestMeasure({
      key: this,
      read: (view) => {
        const groups = new Map()
        for (const line of view.contentDOM.querySelectorAll('[data-code-scroll-group]')) {
          if (line.classList.contains('cm-md-code-wrapped')) continue
          const key = line.dataset.codeScrollGroup
          if (!groups.has(key)) groups.set(key, { lines: [], width: 0, offset: 0 })
          const group = groups.get(key)
          group.offset = Math.max(group.offset, line.scrollLeft)
          let left = Infinity, right = -Infinity
          for (const text of line.querySelectorAll('.cm-md-code-scroll-text')) {
            const range = document.createRange()
            range.selectNodeContents(text)
            const bounds = range.getBoundingClientRect()
            left = Math.min(left, bounds.left)
            right = Math.max(right, bounds.right)
          }
          const width = Number.isFinite(left) ? right - left : 0
          group.lines.push({ line, width })
          group.width = Math.max(group.width, width)
        }
        return groups
      },
      write: (groups) => {
        this.offsets.clear()
        for (const [key, group] of groups) {
          const width = `${Math.ceil(group.width)}px`
          for (const { line } of group.lines) {
            if (line.style.getPropertyValue('--code-scroll-width') !== width) {
              line.style.setProperty('--code-scroll-width', width)
            }
            line.scrollLeft = group.offset
            line.style.setProperty('--code-scroll-offset', `${line.scrollLeft}px`)
          }
          this.offsets.set(key, group.offset)
        }
      },
    })
  }
  destroy() {
    this.view.contentDOM.removeEventListener('scroll', this.onScroll, true)
  }
})
const tableLine = Decoration.line({ class: "cm-md-table" })
// Preview gives every list item after the first a 0.4em margin-top (and a
// nested list the same via li > ul). Mirror it on the item's first line.
const listItemGapLine = Decoration.line({ class: "cm-md-list-item-gap" })
// Mirrors the preview's list geometry: ul/ol start padding with the marker
// hanging inside it, so item text and wrapped lines align like rendered <li>s.
const listItemLine = Decoration.line({ class: "cm-md-list-item" })
const listDepthLineCache = new Map()
const listDepthLine = (depth) => {
  let deco = listDepthLineCache.get(depth)
  if (!deco) {
    deco = Decoration.line({
      class: `cm-md-list-depth-${depth}`,
      attributes: {
        style: `padding-inline-start:${depth * 2.1}em;text-indent:-2.1em;`,
      },
    })
    listDepthLineCache.set(depth, deco)
  }
  return deco
}
const fenceMark = Decoration.mark({ class: "cm-md-fence-info" })
const hiddenCodeFenceSource = Decoration.mark({ class: "cm-md-code-fence-source-hidden" })
const hiddenHeadingSource = Decoration.mark({ class: "cm-md-heading-source-hidden" })
const headingPrefix = Decoration.mark({ class: "cm-md-heading-prefix" })
const headingMarker = Decoration.mark({ class: "cm-md-heading-marker" })
const setextMarkerLine = Decoration.line({ class: "cm-md-setext-marker-line" })
const setextSource = Decoration.mark({ class: "cm-md-setext-source" })
const linkMark = Decoration.mark({ class: "cm-md-link" })
const urlMark = Decoration.mark({ class: "cm-md-url" })
const strongMark = Decoration.mark({ class: "cm-md-strong" })
const emphasisMark = Decoration.mark({ class: "cm-md-emphasis" })
const strikethroughMark = Decoration.mark({ class: "cm-md-strikethrough" })
const highlightMark = Decoration.mark({ class: "cm-md-highlight" })
const frontmatterLine = Decoration.line({ class: "cm-md-frontmatter" })
const frontmatterFirstLine = Decoration.line({ class: "cm-md-frontmatter-first" })
const frontmatterLastLine = Decoration.line({ class: "cm-md-frontmatter-last" })
const frontmatterDelim = Decoration.mark({ class: "cm-md-frontmatter-delim" })

const autoDirectionLine = Decoration.line({ attributes: { dir: "auto" } })

function buildDirectionLines(state) {
  const ranges = []
  for (let lineNumber = 1; lineNumber <= state.doc.lines; lineNumber++) {
    ranges.push(autoDirectionLine.range(state.doc.line(lineNumber).from))
  }
  return Decoration.set(ranges)
}

const directionLines = StateField.define({
  create: buildDirectionLines,
  update(value, transaction) {
    return transaction.docChanged ? buildDirectionLines(transaction.state) : value
  },
  provide: (field) => EditorView.decorations.from(field),
})

function fencedCodeDetails(state, node) {
  let info = ""
  let infoNode = null
  const codeMarks = []
  for (let child = node.node.firstChild; child; child = child.nextSibling) {
    if (child.name === "CodeInfo") {
      infoNode = child
      info = state.doc.sliceString(child.from, child.to)
    }
    if (child.name === "CodeMark") codeMarks.push(child)
  }

  const explicitLanguage = info.trim().split(/\s+/, 1)[0].toLowerCase()
  const openingLine = state.doc.lineAt(node.from)
  const openingMark = codeMarks[0]
  const sourceFrom = openingLine.to < state.doc.length ? openingLine.to + 1 : openingLine.to
  let sourceTo = node.to
  if (codeMarks.length > 1) sourceTo = state.doc.lineAt(codeMarks[codeMarks.length - 1].from).from
  const prefix = state.sliceDoc(openingLine.from, node.from)
  const indentation = /^ {0,3}$/.test(prefix) ? prefix.length : 0
  const textNodes = node.node.getChildren('CodeText')
  const source = textNodes.map((text, index) => {
    const gap = index ? state.doc.lineAt(text.from).number - state.doc.lineAt(textNodes[index - 1].to).number : 0
    return '\n'.repeat(gap) + state.sliceDoc(text.from, text.to)
  }).join('').replace(new RegExp('^ {0,' + indentation + '}', 'gm'), '')
  const detectedLanguage = explicitLanguage ? "" : detectLanguage(source)
  const infoFrom = infoNode?.from ?? openingMark?.to ?? openingLine.to
  const infoTo = infoNode?.to ?? infoFrom

  return {
    explicitLanguage,
    language: explicitLanguage || detectedLanguage,
    detectedLanguage,
    metadata: info.trim().split(/\s+/).slice(1).join(" "),
    rawInfo: info,
    infoFrom,
    infoTo,
    sourceFrom,
    source,
  }
}

function fencedCodeAt(state, pos) {
  // Stay in the outer Markdown tree—the innermost mounted language tree does
  // not retain FencedCode as one of its parents.
  let node = syntaxTree(state).resolve(pos, -1)
  while (node) {
    if (node.name === "FencedCode") {
      return {
        from: node.from,
        to: node.to,
        closed: node.node.lastChild?.name === "CodeMark",
      }
    }
    node = node.parent
  }
  return null
}

// Snapshot only the state that controls source visibility during a gesture.
const setPointerPreview = StateEffect.define()
const pointerPreview = StateField.define({
  create: () => null,
  update(value, tr) {
    // Typing, paste, or an external document update ends the visual snapshot.
    if (tr.docChanged) return null
    for (const effect of tr.effects) {
      if (effect.is(setPointerPreview)) return effect.value
    }
    if (value?.activateOnSelection && tr.isUserEvent('select.pointer')) {
      return { selection: tr.state.selection.main, focused: true,
        fence: tr.state.field(activeCodeBlock), activateOnSelection: false }
    }
    return value
  },
})

// Capture before CodeMirror focuses the editor or changes its selection.
// Keep source-reveal decisions stable, not the entire decoration set: viewport
// changes during auto-scroll must still render newly visible content.
const stablePointerPreview = ViewPlugin.fromClass(class {
  constructor(view) {
    this.view = view
    this.releaseTimer = null
    this.down = (event) => {
      if (event.button !== 0 || event.target.closest('input, textarea, button, select, .cm-md-table-cell')) return
      clearTimeout(this.releaseTimer)
      if (view.state.field(pointerPreview)) return
      view.dispatch({ effects: setPointerPreview.of({
        selection: view.state.selection.main,
        focused: view.hasFocus,
        fence: view.state.field(activeCodeBlock),
        activateOnSelection: event.detail === 1 && !event.shiftKey && !event.metaKey && !event.ctrlKey && !event.altKey,
      }) })
    }
    this.finish = () => {
      if (!view.state.field(pointerPreview)) return
      clearTimeout(this.releaseTimer)
      // CodeMirror's document mouseup listener must finish selecting first.
      this.releaseTimer = setTimeout(() => this.release(), 0)
    }
    this.release = () => {
      clearTimeout(this.releaseTimer)
      if (view.state.field(pointerPreview)) {
        view.dispatch({ effects: setPointerPreview.of(null) })
      }
    }
    this.move = (event) => { if (event.buttons === 0) this.finish() }
    view.contentDOM.addEventListener('mousedown', this.down, true)
    view.contentDOM.addEventListener('keydown', this.release, true)
    view.dom.ownerDocument.addEventListener('mouseup', this.finish)
    view.dom.ownerDocument.addEventListener('mousemove', this.move)
    view.dom.ownerDocument.addEventListener('dragend', this.finish)
    view.win.addEventListener('blur', this.finish)
  }
  destroy() {
    clearTimeout(this.releaseTimer)
    const view = this.view
    view.contentDOM.removeEventListener('mousedown', this.down, true)
    view.contentDOM.removeEventListener('keydown', this.release, true)
    view.dom.ownerDocument.removeEventListener('mouseup', this.finish)
    view.dom.ownerDocument.removeEventListener('mousemove', this.move)
    view.dom.ownerDocument.removeEventListener('dragend', this.finish)
    view.win.removeEventListener('blur', this.finish)
  }
})

// Capture the source position before the first selection reveals syntax.
// Reusing the same screen coordinates after that reveal would hit a different
// character. Only real dragging should start hit-testing the new layout.
const anchoredPointerSelection = EditorView.mouseSelectionStyle.of((view, event) => {
  if (event.button !== 0 || event.detail !== 1 || event.shiftKey || event.metaKey || event.ctrlKey || event.altKey) return null
  let anchor = view.posAtCoords({ x: event.clientX, y: event.clientY })
  if (anchor == null) return null
  let dragged = false
  return {
    update(update) { anchor = update.changes.mapPos(anchor) },
    get(current) {
      dragged ||= Math.hypot(current.clientX - event.clientX, current.clientY - event.clientY) > 3
      const head = dragged ? view.posAtCoords({ x: current.clientX, y: current.clientY }, false) ?? anchor : anchor
      return EditorSelection.single(anchor, head)
    },
  }
})

// A cursor exists at offset zero as soon as CodeMirror is created. Do not let
// that implicit cursor put a leading code block into source mode. A fenced
// block becomes active only after a pointer selection lands inside it.
const activeCodeBlock = StateField.define({
  create: () => null,
  update(value, tr) {
    if (value && tr.docChanged) {
      value = {
        from: tr.changes.mapPos(value.from, 1),
        to: tr.changes.mapPos(value.to, -1),
      }
    }

    const selection = tr.state.selection.main
    if (!selection.empty) return null

    const head = selection.head
    if (tr.isUserEvent("select.pointer")) return fencedCodeAt(tr.state, head)
    // A fence authored from plain text has no prior active range. Resolve it
    // after input so its source stays editable as soon as the opening marker
    // becomes valid, including while a Mermaid block is being typed.
    if (!value && tr.docChanged && tr.isUserEvent("input")) {
      return fencedCodeAt(tr.state, head)
    }
    if (!value) return null
    if (head < value.from || head > value.to) return null

    if (tr.docChanged) return fencedCodeAt(tr.state, head) || value
    return value
  },
})

function buildMermaidPreviews(state) {
  const ranges = []
  const activeFence = state.field(activeCodeBlock)
  const tree = ensureSyntaxTree(state, state.doc.length, 80) || syntaxTree(state)
  tree.iterate({
    enter(node) {
      if (node.name !== "FencedCode") return
      const details = fencedCodeDetails(state, node)
      const isActive = activeFence != null
        && node.from <= activeFence.from && node.to >= activeFence.to
      if (details.language === "mermaid" && !isActive && !currentFindTouches(state, node.from, node.to)) {
        ranges.push(Decoration.replace({
          block: true,
          widget: new MermaidWidget(details.source),
        }).range(node.from, node.to))
        return false
      }
    },
  })
  return Decoration.set(ranges, true)
}

// Mermaid previews replace entire fenced ranges, so they must be provided
// directly from editor state rather than from a view plugin.
const mermaidPreviews = StateField.define({
  create: (state) => buildMermaidPreviews(state),
  update: (value, tr) => {
    if (tr.state.field(pointerPreview)) {
      if (tr.startState.field(pointerPreview)?.activateOnSelection
          && !tr.state.field(pointerPreview).activateOnSelection) return buildMermaidPreviews(tr.state)
      return value
    }
    if (tr.startState.field(pointerPreview)) return buildMermaidPreviews(tr.state)
    const previousActive = tr.startState.field(activeCodeBlock)
    const nextActive = tr.state.field(activeCodeBlock)
    const activeChanged = previousActive?.from !== nextActive?.from
      || previousActive?.to !== nextActive?.to

    let fenceSyntaxChanged = false
    if (tr.docChanged) {
      tr.changes.iterChanges((fromA, toA, _fromB, _toB, inserted) => {
        if (fenceSyntaxChanged) return
        const removed = tr.startState.doc.sliceString(fromA, toA)
        const changedSource = removed + inserted.toString()
        fenceSyntaxChanged = /[`~]|mermaid/i.test(changedSource)
      })
    }

    if (activeChanged || fenceSyntaxChanged || tr.effects.some((effect) => effect.is(setFind))
        || (tr.docChanged && tr.state.field(documentFind).query)) return buildMermaidPreviews(tr.state)
    if (tr.docChanged) return value.map(tr.changes)
    return value
  },
  provide: (field) => EditorView.decorations.from(field),
})

function detectedCodeHighlights(details, cache) {
  const cached = cache.get(details.sourceFrom)
  if (cached?.language === details.detectedLanguage
      && cached.source === details.source) {
    return cached.tokens
  }

  const tokens = []
  const language = LanguageDescription.matchLanguageName(
    codeLanguages, details.detectedLanguage, false
  )?.support?.language
  if (language) {
    highlightTree(language.parser.parse(details.source), codeHighlight,
      (from, to, classes) => {
        tokens.push({ from, to, mark: Decoration.mark({ class: classes }) })
      })
  }
  cache.set(details.sourceFrom, {
    language: details.detectedLanguage,
    source: details.source,
    tokens,
  })
  return tokens
}

function buildDecorations(view, detectedCodeCache) {
  const ranges = []
  const { state } = view
  const pointer = state.field(pointerPreview)
  const sel = pointer?.selection ?? state.selection.main
  const activeFence = pointer ? pointer.fence : state.field(activeCodeBlock)
  const focused = pointer ? pointer.focused : view.hasFocus

  // CodeMirror always owns a selection at offset zero, even before the user
  // clicks the editor. Only reveal source syntax when the editor truly has
  // keyboard focus; otherwise the first block looks spuriously active.
  // A range selection is an operation on rendered content, not a request to
  // reveal every Markdown marker it spans. Only a caret activates source
  // syntax; this keeps Cmd-A and long drag selections in live-preview form.
  const touches = (from, to) => currentFindTouches(state, from, to)
    || (focused && sel.empty && sel.head >= from && sel.head <= to)
  const touchesLineOf = (pos) => {
    const line = state.doc.lineAt(pos)
    return touches(line.from, line.to)
  }
  const isActiveFence = (node) => currentFindTouches(state, node.from, node.to)
    || (activeFence != null && node.from <= activeFence.from && node.to >= activeFence.to)
  const decoratedLines = new Set()
  const listDepthPositions = new Set()
  const lineOnce = (pos, deco) => {
    const line = state.doc.lineAt(pos)
    const key = deco.spec.class + "@" + line.from
    if (decoratedLines.has(key)) return
    decoratedLines.add(key)
    ranges.push(deco.range(line.from))
  }
  const eachLine = (from, to, deco) => {
    let pos = from
    while (pos <= to) {
      const line = state.doc.lineAt(pos)
      lineOnce(line.from, deco)
      if (line.to >= to) break
      pos = line.to + 1
    }
  }
  const indentationColumns = (indentation) => {
    let columns = 0
    for (const character of indentation) {
      columns = character === "\t"
        ? columns + (4 - (columns % 4))
        : columns + 1
    }
    return columns
  }
  // Repeated Tab can move a list-looking source line beyond the indentation
  // depth that the CommonMark parser still recognizes as a ListItem. Keep the
  // editor geometry stable at that boundary: ordinary indented code is left
  // alone, while a line with an explicit list marker retains list styling.
  const decorateRawIndentedListLine = (line, match) => {
    const indentation = match[1]
    const marker = match[2]
    const separator = match[3]
    const markerFrom = line.from + indentation.length
    const markerTo = markerFrom + marker.length
    const depth = Math.floor(indentationColumns(indentation) / 4) + 1

    lineOnce(line.from, listItemLine)
    lineOnce(line.from, listDepthLine(depth))
    listDepthPositions.add(line.from)
    if (line.number > 1
        && markdownListMarker.test(state.doc.line(line.number - 1).text)) {
      lineOnce(line.from, listItemGapLine)
    }
    if (indentation.length > 0) {
      ranges.push(hide.range(line.from, markerFrom))
    }

    const isTask = /^[-+*]$/.test(marker)
      && /^\s*\[[ xX]\](\s|$)/.test(line.text.slice(markerTo - line.from))
    if (/^[-+*]$/.test(marker) && !isTask) {
      if (touchesLineOf(markerFrom)) {
        ranges.push(activeBulletDeco.range(markerFrom, markerTo))
        if (separator.length > 0) {
          ranges.push(hide.range(markerTo, markerTo + separator.length))
        }
      } else {
        ranges.push(bulletDeco.range(
          markerFrom,
          markerTo + separator.length
        ))
      }
    }
  }
  // The renderer shrinks the final source blank line of a run to blankGap
  // before applying semantic block margins. Keep the editor's final blank
  // separator at blankGap plus those margins; earlier blank lines already
  // retain their normal CodeMirror line height.
  const blankRunBefore = (pos) => {
    const line = state.doc.lineAt(pos)
    let first = line.number
    // Only "one blank" vs "several" (plus the document-start case) changes
    // the emitted separator, so cap the walk against pathological runs.
    const stop = Math.max(first - 64, 1)
    while (first > stop && state.doc.line(first - 1).text.length === 0) first--
    return { line, first, count: line.number - first }
  }
  const blockMarginTop = (node) => {
    switch (node.name) {
      case "Blockquote": {
        // Alert blockquotes render as .markdown-alert; recognize the same
        // five kinds as EscapingHTMLFormatter.
        const firstLine = state.doc.lineAt(node.from)
        return /^ {0,3}> ?\[!(note|tip|important|warning|caution)\]/i.test(firstLine.text)
          ? METRICS.alert : METRICS.quote
      }
      case "Table": return METRICS.table
      case "HorizontalRule": return METRICS.hr
      case "FencedCode":
        // Mermaid fences render as .mermaid-figure (same margin as tables).
        return fencedCodeDetails(state, node).language === "mermaid"
          ? METRICS.table : METRICS.paragraph
      default: return METRICS.paragraph
    }
  }
  // Adjacent blocks: the preview gives the second block its margin-top even
  // without a blank line (a paragraph right under a heading, a fence right
  // after a paragraph). Put that gap on the previous block's last line.
  let frontmatterTo = -1
  const gapBeforeAdjacent = (node) => {
    const line = state.doc.lineAt(node.from)
    if (line.number === 1 || line.from <= frontmatterTo) return
    if (blankRunBefore(node.from).count !== 0) return
    lineOnce(state.doc.line(line.number - 1).from, blockGapLine(blockMarginTop(node)))
  }
  const separatorBlankBefore = (node) => {
    const run = blankRunBefore(node.from)
    if (run.count === 0) return
    const separator = state.doc.line(run.line.number - 1)
    if (run.first === 1) {
      lineOnce(
        separator.from,
        blockSeparatorLine(METRICS.blankGap + blockMarginTop(node))
      )
      return
    }
    const marginTop = blockMarginTop(node)
    const height = METRICS.blankGap + marginTop
    lineOnce(separator.from, blockSeparatorLine(height))
  }

  // yamlFrontmatter wraps the Markdown parser as Document(Document(...)), so
  // discover the inner content Document and treat its direct children as the
  // top-level Markdown blocks. Tracking depth (and a stack of enclosing
  // lists) answers parent/sibling questions positionally without
  // materializing a SyntaxNode per visited node.
  let depth = 0
  const listStack = []
  const quoteStack = []
  const quoteLines = new Map()

  for (const { from, to } of view.visibleRanges) {
    let contentDocumentDepth = null
    syntaxTree(state).iterate({
      from, to,
      enter: (node) => {
        depth++
        const name = node.name

        if (depth === 2 && name === "Document") contentDocumentDepth = depth

        // --- Block separators ------------------------------------------
        if (contentDocumentDepth != null && depth === contentDocumentDepth + 1) {
          if (SEPARATOR_BLOCKS.has(name)) {
            separatorBlankBefore(node)
            gapBeforeAdjacent(node)
          }
        }

        // --- Frontmatter ----------------------------------------------
        // Style the whole block as a quiet metadata card; keep the YAML
        // source editable, dimming only the `---` delimiters.
        if (name === "Frontmatter") {
          // The node's end includes the newline after the closing ---;
          // step back so the card never bleeds onto the first body line.
          const end = node.to > node.from && state.doc.lineAt(node.to).from === node.to
            ? node.to - 1 : node.to
          frontmatterTo = end
          eachLine(node.from, end, frontmatterLine)
          lineOnce(node.from, frontmatterFirstLine)
          lineOnce(state.doc.lineAt(end).from, frontmatterLastLine)
          return
        }
        if (name === "DashLine") {
          ranges.push(frontmatterDelim.range(node.from, node.to))
          return
        }

        // --- Headings ------------------------------------------------
        const atx = name.match(/^ATXHeading(\d)$/)
        if (atx) {
          lineOnce(node.from, HEADING_LINE[+atx[1]])
          if (blankRunBefore(node.from).count > 0) {
            lineOnce(node.from, headingAfterBlankLine)
          }
          if (!touchesLineOf(node.from)) lineOnce(node.from, inactiveHeadingLine)
          return
        }
        const setext = name.match(/^SetextHeading(\d)$/)
        if (setext) {
          lineOnce(node.from, HEADING_LINE[+setext[1]])
          if (blankRunBefore(node.from).count > 0) {
            lineOnce(node.from, headingAfterBlankLine)
          }
          return
        }
        if (name === "HeaderMark") {
          const parent = node.node.parent
          if (parent && /^ATXHeading/.test(parent.name)) {
            ranges.push(headingMarker.range(node.from, node.to))
            const after = state.doc.sliceString(node.to, node.to + 1)
            const markTo = node.to + (after === " " ? 1 : 0)
            const opening = node.from === parent.from
            const line = state.doc.lineAt(node.from)
            // ATX nodes start at '#', excluding up to three valid leading
            // spaces. Include that indentation in the measured prefix, but
            // never consume a surrounding list or blockquote marker.
            const prefixFrom = opening && /^ {0,3}$/.test(state.doc.sliceString(line.from, node.from))
              ? line.from : node.from
            if (opening) ranges.push(headingPrefix.range(prefixFrom, markTo))
            if (!touchesLineOf(node.from)) {
              // Keep the hidden source prefix measurable for alignment.
              // Pointer selection keeps its source anchor across activation.
              ranges.push(hiddenHeadingSource.range(prefixFrom, markTo))
            }
          } else if (parent && /^SetextHeading/.test(parent.name)) {
            lineOnce(node.from, setextMarkerLine)
            ranges.push(setextSource.range(node.from, node.to))
          }
          return
        }

        // --- Blockquotes ----------------------------------------------
        if (name === "Blockquote") {
          quoteStack.push(node.from)
          const quoteFirst = state.doc.lineAt(node.from)
          const parentQuote = node.node.parent?.name === "Blockquote"
          let previous = node.node.prevSibling
          while (previous?.name === "QuoteMark") previous = previous.prevSibling
          const nestedGap = parentQuote && previous ? METRICS.quote : 0
          let pos = node.from
          while (pos <= node.to) {
            const line = state.doc.lineAt(pos)
            const edges = quoteLines.get(line.from) || { depth: 0, starts: 0, ends: 0, gap: 0 }
            edges.depth = Math.max(edges.depth, quoteStack.length)
            // Match the preview's 0.4em padding once per quote boundary,
            // not once per source line (which may wrap or soft-join).
            if (line.from === quoteFirst.from) {
              edges.starts++
              edges.gap += nestedGap
            }
            if (line.to >= node.to) edges.ends++
            quoteLines.set(line.from, edges)
            if (line.to >= node.to) break
            pos = line.to + 1
          }
          return
        }
        if (name === "QuoteMark") {
          if (!touchesLineOf(node.from)) {
            const after = state.doc.sliceString(node.to, node.to + 1)
            ranges.push(hide.range(node.from, node.to + (after === " " ? 1 : 0)))
          }
          return
        }

        // Container paragraphs use their own semantic margin. Their blank
        // source lines are not top-level authored spacers in the preview.
        if (name === "Paragraph" && /^(Blockquote|ListItem)$/.test(node.node.parent?.name || "")) {
          const first = state.doc.lineAt(node.from)
          if (first.number > state.doc.lineAt(node.node.parent.from).number) {
            const previous = state.doc.line(first.number - 1)
            if (/^(?:[ >]*)$/.test(previous.text)) {
              lineOnce(previous.from, blockSeparatorLine(METRICS.paragraph))
            }
          }
        }

        // Escape markers disappear in live preview; the literal character
        // still belongs to the original editable source.
        if (name === "Escape" && !touches(node.from, node.to)) {
          ranges.push(hide.range(node.from, node.from + 1))
          return
        }

        // --- Emphasis family -------------------------------------------
        if (name === "StrongEmphasis") {
          ranges.push(strongMark.range(node.from, node.to))
          return
        }
        if (name === "Emphasis") {
          ranges.push(emphasisMark.range(node.from, node.to))
          return
        }
        if (name === "Strikethrough") {
          ranges.push(strikethroughMark.range(node.from, node.to))
          return
        }
        if (name === "Highlight") {
          const marks = []
          for (let child = node.node.firstChild; child; child = child.nextSibling) {
            if (child.name === "HighlightMark") marks.push(child)
          }
          const contentFrom = marks.length ? marks[0].to : node.from
          const contentTo = marks.length > 1 ? marks[marks.length - 1].from : node.to
          if (contentFrom < contentTo) {
            ranges.push(highlightMark.range(contentFrom, contentTo))
          }
          return
        }
        if (name === "HighlightMark") {
          const parent = node.node.parent
          if (parent && parent.name === "Highlight" && !touches(parent.from, parent.to)) {
            ranges.push(hide.range(node.from, node.to))
          }
          return
        }
        if (name === "EmphasisMark" || name === "StrikethroughMark") {
          const parent = node.node.parent
          if (parent && !touches(parent.from, parent.to)) {
            ranges.push(hide.range(node.from, node.to))
          }
          return
        }

        // --- Inline code ------------------------------------------------
        if (name === "InlineCode") {
          const marks = []
          for (let child = node.node.firstChild; child; child = child.nextSibling) {
            if (child.name === "CodeMark") marks.push(child)
          }
          const contentFrom = marks.length ? marks[0].to : node.from
          const contentTo = marks.length > 1 ? marks[marks.length - 1].from : node.to
          if (contentFrom < contentTo) {
            ranges.push(Decoration.mark({ class: "cm-md-inline-code" })
              .range(contentFrom, contentTo))
          }
          return
        }
        if (name === "CodeMark") {
          const parent = node.node.parent
          if (parent && parent.name === "InlineCode" && !touches(parent.from, parent.to)) {
            ranges.push(hide.range(node.from, node.to))
          } else if (parent && parent.name === "FencedCode"
              && !isActiveFence(parent)) {
            const line = state.doc.lineAt(node.from)
            // Hide the complete source line. Collapsing handles geometry;
            // this mark is also the fallback for fences without an interior
            // line and keeps the raw marker out of the visual code card.
            ranges.push(hiddenCodeFenceSource.range(line.from, line.to))
          }
          return
        }

        // --- Images -------------------------------------------------------
        // Render direct image destinations in place. Keeping the raw node
        // active under the caret makes the source editable without a second
        // editor surface; reference-style images stay as authored source.
        if (name === "Image") {
          // Pruning this node also skips Lezer's leave callback. Balance the
          // depth here so later top-level blocks still get paragraph spacing.
          depth--
          const urlNode = node.node.getChild("URL")
          if (!urlNode) return false
          const rawSource = state.doc.sliceString(urlNode.from, urlNode.to).trim()
          const source = rawSource.startsWith("<") && rawSource.endsWith(">")
            ? rawSource.slice(1, -1)
            : rawSource
          if (!source || source.startsWith("//")) return false

          let altEnd = node.from + 2
          for (let child = node.node.firstChild; child; child = child.nextSibling) {
            if (child.name === "LinkMark"
                && state.doc.sliceString(child.from, child.to) === "]") {
              altEnd = child.from
              break
            }
          }
          const alt = state.doc.sliceString(node.from + 2, altEnd)
          if (!touches(node.from, node.to)) {
            const line = state.doc.lineAt(node.from)
            if (line.text.trim() === state.doc.sliceString(node.from, node.to)) {
              lineOnce(line.from, imageLine)
            }
            ranges.push(Decoration.replace({
              widget: new ImageWidget(
                source,
                alt,
                state.doc.sliceString(node.from, node.to),
                node.from,
                node.to,
              ),
            }).range(node.from, node.to))
          }
          return false
        }

        // --- Links ------------------------------------------------------
        // Only real links (with a URL part) get link treatment. Footnote
        // references like [^first] also parse as Link nodes; leave their
        // brackets alone so they read as what they are.
        if (name === "Link") {
          if (node.node.getChild("URL")) {
            ranges.push(linkMark.range(node.from, node.to))
          }
          return
        }
        if (name === "LinkMark") {
          const parent = node.node.parent
          if (parent && parent.name === "Link" && parent.getChild("URL")
              && !touches(parent.from, parent.to)) {
            ranges.push(hide.range(node.from, node.to))
          }
          return
        }
        if (name === "URL") {
          const parent = node.node.parent
          if (parent && parent.name === "Link") {
            if (!touches(parent.from, parent.to)) {
              ranges.push(hide.range(node.from, node.to))
            } else {
              ranges.push(urlMark.range(node.from, node.to))
            }
          }
          return
        }

        // --- Lists --------------------------------------------------------
        if (name === "BulletList" || name === "OrderedList") {
          listStack.push(node.from)
          return
        }
        if (name === "ListItem") {
          // The first item of a top-level list carries no gap (preview:
          // li:first-child { margin-top: 0 }); a nested list's first item
          // inherits the li > ul margin instead, so it keeps the gap. A
          // list starts at its first item, so "first" is a position check.
          const isFirstItem = node.from === listStack[listStack.length - 1]
          const isNested = listStack.length > 1
          if (!isFirstItem) {
            let number = state.doc.lineAt(node.from).number - 1
            while (number > 0 && state.doc.line(number).text.trim() === "") {
              lineOnce(state.doc.line(number).from, blockSeparatorLine(0))
              number--
            }
          }
          if (!isFirstItem || isNested) lineOnce(node.from, listItemGapLine)
          eachLine(node.from, node.to, listItemLine)
          lineOnce(node.from, listDepthLine(listStack.length))
          listDepthPositions.add(state.doc.lineAt(node.from).from)
          // Continuation lines of this item (not nested markers, not blank)
          // sit at the item's text column with their indentation hidden.
          {
            const firstLine = state.doc.lineAt(node.from)
            let pos = firstLine.to + 1
            while (pos <= node.to) {
              const line = state.doc.lineAt(pos)
              const text = line.text
              if (text.length > 0 && !markdownListMarker.test(text)) {
                lineOnce(line.from, listContinuationLine)
                lineOnce(line.from, listDepthLine(listStack.length))
                const lead = text.match(/^[ \t]+/)
                if (lead) ranges.push(hide.range(line.from, line.from + lead[0].length))
              }
              if (line.to >= node.to) break
              pos = line.to + 1
            }
          }
          // Source indentation uses proportional-font space glyphs, which
          // does not equal the rendered list's 2.1em nesting step. Hide that
          // source-only prefix and let the semantic depth line own geometry.
          const line = state.doc.lineAt(node.from)
          const rawIndentedList = line.text.match(markdownListMarker)
          const indentation = rawIndentedList?.[1] ?? ""
          if (indentation.length > 0) {
            ranges.push(hide.range(line.from, line.from + indentation.length))
          }
          return
        }
        if (name === "ListMark") {
          const mark = state.doc.sliceString(node.from, node.to)
          const line = state.doc.lineAt(node.from)
          // Task items (`- [ ]`) keep their literal marker; turning the dash
          // into a bullet dot leaves a confusing "• [ ]" hybrid.
          const isTask = /^\s*\[[ xX]\](\s|$)/.test(line.text.slice(node.to - line.from))
          if ((mark === "-" || mark === "*" || mark === "+") && !isTask) {
            // Both forms occupy the same fixed-width hanging box. Keep the
            // active dash editable, but hide its source separator so the dash
            // can sit at the rendered bullet position without moving text.
            const after = state.doc.sliceString(node.to, node.to + 1)
            if (touchesLineOf(node.from)) {
              ranges.push(activeBulletDeco.range(node.from, node.to))
              if (after === " ") ranges.push(hide.range(node.to, node.to + 1))
            } else {
              ranges.push(bulletDeco.range(node.from, node.to + (after === " " ? 1 : 0)))
            }
          } else if (/^\d+[.)]$/.test(mark) && !isTask) {
            const after = state.doc.sliceString(node.to, node.to + 1)
            if (touchesLineOf(node.from)) {
              ranges.push(activeOrderedDeco.range(node.from, node.to))
              if (after === " ") ranges.push(hide.range(node.to, node.to + 1))
            } else {
              ranges.push(orderedDeco(mark).range(node.from, node.to + (after === " " ? 1 : 0)))
            }
          }
          return
        }

        // --- Code blocks ------------------------------------------------
        if (name === "FencedCode" || name === "CodeBlock") {
          const first = state.doc.lineAt(node.from)
          const last = state.doc.lineAt(node.to)
          const closed = name === "FencedCode"
            && node.node.lastChild?.name === "CodeMark"
          const hasInterior = last.number - first.number >= (closed ? 2 : 1)
          // Parsed fence lines stay out of the visual code card even while
          // its content is active. The opening source is revealed only when
          // the caret is actually on that line, so newly authored fences and
          // manual language edits remain possible without polluting the code.
          const hidesOpeningFence = name === "FencedCode"
            && !touchesLineOf(first.from)
          const hidesClosingFence = closed && !touchesLineOf(last.from)
          const codeFirst = hidesOpeningFence && hasInterior
            ? state.doc.line(first.number + 1) : first
          const widgetLine = hasInterior ? codeFirst : first
          const codeLast = !hasInterior && name === "FencedCode"
            ? first
            : hidesClosingFence
              ? state.doc.line(last.number - 1)
              : last
          if (name === "FencedCode") {
            const details = fencedCodeDetails(state, node)
            if (details.detectedLanguage) {
              for (const token of detectedCodeHighlights(details, detectedCodeCache)) {
                ranges.push(token.mark.range(
                  details.sourceFrom + token.from,
                  details.sourceFrom + token.to,
                ))
              }
            }
            ranges.push(Decoration.widget({
              widget: new CodeLanguageWidget({
                wrapped: state.field(wrappedCodeBlocks).has(first.from),
                fenceFrom: node.from,
                language: details.language,
                detectedLanguage: details.detectedLanguage,
                rawInfo: details.rawInfo,
                infoFrom: details.infoFrom,
                infoTo: details.infoTo,
              }),
              side: -1,
            }).range(widgetLine.from))
          } else {
            ranges.push(Decoration.widget({
              widget: new CodeLanguageWidget({ fenceFrom: first.from, language: 'text',
                rawInfo: '', plain: true, wrapped: state.field(wrappedCodeBlocks).has(first.from) }),
              side: -1,
            }).range(widgetLine.from))
          }
          let pos = node.from
          while (pos <= node.to) {
            const line = state.doc.lineAt(pos)
            const rawIndentedList = name === "CodeBlock"
              && decoratedLines.has(`${listItemLine.spec.class}@${line.from}`)
              ? line.text.match(markdownListMarker)
              : null
            if (rawIndentedList) {
              decorateRawIndentedListLine(line, rawIndentedList)
              if (line.to >= node.to) break
              pos = line.to + 1
              continue
            }
            const isWidgetLine = name === "FencedCode"
              && line.from === widgetLine.from
            if (((hidesOpeningFence && line.from === first.from)
                || (hidesClosingFence && line.from === last.from))
                && !isWidgetLine) {
              lineOnce(line.from, collapsedLine)
            } else if (name === "FencedCode" && !hasInterior
                && line.from !== first.from && !isWidgetLine) {
              lineOnce(line.from, collapsedLine)
            } else {
              const isFirst = line.from === codeFirst.from
              const isLast = line.from === codeLast.from
              if (isFirst) lineOnce(line.from, codeLineFirst)
              if (isLast) lineOnce(line.from, codeLineLast)
              if (!isFirst && !isLast) lineOnce(line.from, codeLine)
              ranges.push(Decoration.line({ attributes: {
                'data-code-scroll-group': String(first.from),
                class: state.field(wrappedCodeBlocks).has(first.from) ? 'cm-md-code-wrapped' : '',
              } }).range(line.from))
              if (line.length) ranges.push(codeScrollText.range(line.from, line.to))
            }
            if (name === "CodeBlock" && !touchesLineOf(line.from)) {
              const indent = line.text.match(/^(?: {4}|\t)/)?.[0]
              if (indent) ranges.push(hide.range(line.from, line.from + indent.length))
            }
            if (line.to >= node.to) break
            pos = line.to + 1
          }
          return
        }
        if (name === "CodeInfo") {
          const parent = node.node.parent
          if (!parent) return
          if (touchesLineOf(parent.from)) ranges.push(fenceMark.range(node.from, node.to))
          return
        }

        // --- Tables -------------------------------------------------------
        if (name === "Table") {
          eachLine(node.from, node.to, tableLine)
          return
        }

        // --- Horizontal rule ----------------------------------------------
        if (name === "HorizontalRule") {
          if (!touchesLineOf(node.from)) {
            lineOnce(node.from, ruleLine)
            ranges.push(hrDeco.range(node.from, node.to))
          }
          return
        }
      },
      leave: (node) => {
        depth--
        const name = node.name
        if (name === "BulletList" || name === "OrderedList") listStack.pop()
        if (name === "Blockquote") quoteStack.pop()
      },
    })
    for (const [lineFrom, edges] of quoteLines) {
      lineOnce(lineFrom, quoteLine(edges.depth, edges.starts, edges.ends, edges.gap))
    }
    quoteLines.clear()
    // A deeply indented marker may be parsed as continuation content inside
    // its ancestor ListItem rather than as a standalone CodeBlock. The parent
    // already gives that line list typography; fill in the missing depth,
    // marker, and gap decorations so the third and later Tabs do not jump.
    let rawPos = from
    while (rawPos <= to) {
      const line = state.doc.lineAt(rawPos)
      const hasListTypography = decoratedLines.has(
        `${listItemLine.spec.class}@${line.from}`
      )
      if (hasListTypography && !listDepthPositions.has(line.from)) {
        const rawIndentedList = line.text.match(markdownListMarker)
        if (rawIndentedList) {
          decorateRawIndentedListLine(line, rawIndentedList)
        }
      }
      if (line.to >= to) break
      rawPos = line.to + 1
    }
  }
  return Decoration.set(ranges, true)
}

function formattingState(state) {
  const selection = state.selection.main
  const commands = new Set()
  let heading = 0
  for (let node = syntaxTree(state).resolveInner(selection.from, 1); node; node = node.parent) {
    if (node.to < selection.to) continue
    const match = /^(?:ATX|Setext)Heading([1-6])$/.exec(node.name)
    if (match) heading = Number(match[1])
    const command = { StrongEmphasis: 'bold', Emphasis: 'italic',
      Strikethrough: 'strikethrough', Link: 'link', InlineCode: 'code',
      BulletList: 'list', OrderedList: 'list', Blockquote: 'quote',
      FencedCode: 'fenced', CodeBlock: 'plain', Table: 'table' }[node.name]
    if (command) commands.add(command)
  }
  return { heading, commands: [...commands].sort() }
}

const livePreview = ViewPlugin.fromClass(class {
  constructor(view) {
    this.detectedCodeCache = new Map()
    this.decorations = buildDecorations(view, this.detectedCodeCache)
  }
  update(update) {
    if (update.docChanged) this.detectedCodeCache.clear()
    // Background parsing can finish without a document, selection, or viewport
    // change. Refresh widgets then too, or images can stay as source until input.
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged
        || update.startState.field(pointerPreview) !== update.state.field(pointerPreview)
        || update.startState.field(wrappedCodeBlocks) !== update.state.field(wrappedCodeBlocks)
        || syntaxTree(update.startState) !== syntaxTree(update.state)
        || update.startState.field(documentFind) !== update.state.field(documentFind)) {
      this.decorations = buildDecorations(update.view, this.detectedCodeCache)
    }
  }
}, { decorations: (v) => v.decorations })

// Align inactive headings with the document column. Active headings show
// their source prefix inline, with pointer selection anchored in source space.
const alignInactiveHeadings = ViewPlugin.fromClass(class {
  constructor(view) { this.schedule(view) }

  update(update) {
    if (update.docChanged || update.selectionSet || update.viewportChanged
        || update.geometryChanged || update.focusChanged) {
      this.schedule(update.view)
    }
  }

  docViewUpdate(view) { this.schedule(view) }

  schedule(view) {
    view.requestMeasure({
      key: this,
      read(view) {
        return Array.from(view.dom.querySelectorAll(".cm-md-heading-prefix"))
          .map((marker) => {
            const line = marker.closest(".cm-line")
            return line ? { line, width: marker.getBoundingClientRect().width } : null
          })
          .filter(Boolean)
      },
      write(measurements) {
        for (const { line, width } of measurements) {
          const value = `${width}px`
          if (line.style.getPropertyValue("--cm-md-heading-prefix-width") !== value) {
            line.style.setProperty("--cm-md-heading-prefix-width", value)
          }
        }
      },
    })
  }
})

// ---------------------------------------------------------------------------
// Paragraph reflow
// ---------------------------------------------------------------------------
// Markdown soft breaks (hard-wrapped source lines) render as spaces in the
// preview. Mirror that: while the cursor is outside a paragraph, each
// internal newline (plus the next line's continuation indent) collapses to
// a single space so the text reflows to the full measure. Lines ending in
// a hard break (two trailing spaces or a backslash) keep their newline —
// they render as a real break in the preview too.
//
// Decorations that replace line breaks affect vertical layout, which view
// plugins are forbidden to do — these must come from a StateField.

function computeJoins(state) {
  const ranges = []
  const sel = state.selection.main
  const touches = (from, to) => sel.from <= to && sel.to >= from
  // Joins span the whole document, so make sure the tree does too —
  // otherwise paragraphs past the initial parse chunk stay unjoined
  // until the first edit.
  const tree = ensureSyntaxTree(state, state.doc.length, 80) || syntaxTree(state)
  tree.iterate({
    enter: (node) => {
      const name = node.name
      // Code content can look hard-wrapped; never descend into it.
      if (name === "FencedCode" || name === "CodeBlock" || name === "HTMLBlock") return false
      if (name !== "Paragraph") return
      if (touches(node.from, node.to)) return false
      let line = state.doc.lineAt(node.from)
      while (line.to < node.to) {
        const tail = state.doc.sliceString(Math.max(line.from, line.to - 2), line.to)
        const hardBreak = tail.endsWith("  ") || tail.endsWith("\\")
        const next = state.doc.lineAt(line.to + 1)
        if (!hardBreak) {
          const indent = next.text.length - next.text.trimStart().length
          ranges.push(joinDeco.range(line.to, next.from + indent))
        }
        line = next
      }
      return false
    },
  })
  return Decoration.set(ranges, true)
}

const paragraphReflow = StateField.define({
  create: (state) => computeJoins(state),
  update: (value, tr) => (tr.docChanged || tr.selection) ? computeJoins(tr.state) : value,
  provide: (field) => EditorView.decorations.from(field),
})

// ---------------------------------------------------------------------------
// Syntax highlighting inside code fences (colors come from page CSS vars)
// ---------------------------------------------------------------------------

const codeHighlight = HighlightStyle.define([
  { tag: [t.keyword, t.modifier, t.operatorKeyword, t.controlKeyword, t.definitionKeyword, t.moduleKeyword], class: "hl-keyword" },
  { tag: [t.string, t.special(t.string), t.regexp], class: "hl-string" },
  { tag: [t.comment, t.blockComment, t.lineComment], class: "hl-comment" },
  { tag: [t.number, t.integer, t.float, t.character], class: "hl-number" },
  { tag: [t.bool, t.atom, t.null], class: "hl-keyword" },
  { tag: [t.typeName, t.namespace], class: "hl-type" },
  { tag: [t.className, t.definition(t.typeName)], class: "hl-declaration" },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], class: "hl-function" },
  { tag: [t.propertyName, t.labelName], class: "hl-property" },
  { tag: t.attributeName, class: "hl-attribute" },
  { tag: [t.standard(t.variableName), t.standard(t.typeName)], class: "hl-builtin" },
  { tag: [t.meta, t.processingInstruction], class: "hl-meta" },
  { tag: [t.punctuation, t.operator], class: "hl-plain" },
])

// ---------------------------------------------------------------------------
// Bold / italic toggles
// ---------------------------------------------------------------------------

function toggleInlineMark(marker) {
  return (view) => {
    const changes = view.state.changeByRange((range) => {
      let { from, to } = range
      // CommonMark rejects emphasis that opens or closes against
      // whitespace ("** bold **"), so keep it outside the markers.
      while (from < to && /\s/.test(view.state.sliceDoc(from, from + 1))) from++
      while (to > from && /\s/.test(view.state.sliceDoc(to - 1, to))) to--
      const len = marker.length
      const before = view.state.sliceDoc(Math.max(0, from - len), from)
      const after = view.state.sliceDoc(to, to + len)
      if (before === marker && after === marker) {
        return {
          changes: [
            { from: from - len, to: from, insert: "" },
            { from: to, to: to + len, insert: "" },
          ],
          range: EditorSelection.range(from - len, to - len),
        }
      }
      const selected = view.state.sliceDoc(from, to)
      if (selected.startsWith(marker) && selected.endsWith(marker) && selected.length >= len * 2) {
        return {
          changes: { from, to, insert: selected.slice(len, selected.length - len) },
          range: EditorSelection.range(from, to - len * 2),
        }
      }
      return {
        changes: { from, to, insert: marker + selected + marker },
        range: EditorSelection.range(from + len, to + len),
      }
    })
    view.dispatch(changes, { scrollIntoView: true, userEvent: "input" })
    return true
  }
}

// ---------------------------------------------------------------------------
// Block-level toggles (headings, quotes, lists) and link insertion —
// backing for the host app's formatting bar.
// ---------------------------------------------------------------------------

function eachSelectedLine(state, fn) {
  const sel = state.selection.main
  const start = state.doc.lineAt(sel.from).number
  const end = state.doc.lineAt(sel.to).number
  const lines = []
  for (let n = start; n <= end; n++) lines.push(state.doc.line(n))
  return fn(lines)
}

function toggleBlockPrefix(prefix, pattern) {
  return (view) => {
    const changes = eachSelectedLine(view.state, (lines) => {
      const all = lines.every((line) => pattern.test(line.text))
      return lines.map((line) => {
        if (all) {
          const m = line.text.match(pattern)
          return { from: line.from, to: line.from + m[0].length, insert: "" }
        }
        return pattern.test(line.text) ? null : { from: line.from, insert: prefix }
      }).filter(Boolean)
    })
    if (changes.length) dispatchBlockChanges(view, changes)
    return true
  }
}

// Dispatch line-prefix edits while keeping the cursor after any inserted
// prefix (the default mapping leaves it before, stranding the caret behind
// the new list marker).
function dispatchBlockChanges(view, changes) {
  const changeSet = view.state.changes(changes)
  const sel = view.state.selection.main
  view.dispatch({
    changes,
    selection: EditorSelection.range(
      changeSet.mapPos(sel.anchor, 1),
      changeSet.mapPos(sel.head, 1)
    ),
    userEvent: "input",
  })
}

function orderedList(view) {
  const pattern = /^\d+\.\s/
  const changes = eachSelectedLine(view.state, (lines) => {
    const all = lines.every((line) => pattern.test(line.text))
    let i = 1
    return lines.map((line) => {
      if (all) {
        const m = line.text.match(pattern)
        return { from: line.from, to: line.from + m[0].length, insert: "" }
      }
      return pattern.test(line.text) ? null : { from: line.from, insert: `${i++}. ` }
    }).filter(Boolean)
  })
  if (changes.length) dispatchBlockChanges(view, changes)
  return true
}

function selectedListLines(state) {
  const selection = state.selection.main
  const start = state.doc.lineAt(selection.from).number
  const end = state.doc.lineAt(selection.empty ? selection.to : selection.to - 1).number
  return Array.from({ length: end - start + 1 }, (_, index) => state.doc.line(start + index))
}

function listPrefix(text) {
  const match = /^([ \t]*(?:>[ \t]*)*)(?:([-+*]|\d+[.)])([ \t]+)(\[[ xX]\][ \t]+)?)?/.exec(text)
  return {
    prefix: match[0], indent: match[1],
    style: !match[2] ? 'none' : match[4] ? 'task' : /^\d/.test(match[2]) ? 'ordered' : 'bullet',
  }
}

function enclosingNode(state, position, names) {
  for (let node = syntaxTree(state).resolve(position, 1); node; node = node.parent) {
    if (names.includes(node.name)) return node
  }
  return null
}

function editableListLines(state) {
  return selectedListLines(state).filter(line =>
    !/^[ \t>]*$/.test(line.text)
    && !enclosingNode(state, line.from + line.text.search(/\S/), ['FencedCode', 'CodeBlock']))
}

function applyListStyle(view, style) {
  if (!['none', 'bullet', 'ordered', 'task'].includes(style)) return false
  const changes = editableListLines(view.state).map((line, index) => {
    const current = listPrefix(line.text)
    if (current.style === style) return null
    const marker = style === 'none' ? '' : style === 'bullet' ? '- ' : style === 'task' ? '- [ ] ' : `${index + 1}. `
    return { from: line.from, to: line.from + current.prefix.length, insert: current.indent + marker }
  }).filter(Boolean)
  if (changes.length) dispatchBlockChanges(view, changes)
  view.focus()
  return true
}

function setHeading(level) {
  return (view) => {
    const changes = eachSelectedLine(view.state, (lines) => lines.map((line) => {
      const m = line.text.match(/^(#{1,6})\s+/)
      const current = m ? m[1].length : 0
      const insert = current === level || level === 0 ? "" : "#".repeat(level) + " "
      return { from: line.from, to: line.from + (m ? m[0].length : 0), insert }
    }))
    view.dispatch({ changes, userEvent: "input" })
    return true
  }
}

function stylingContext(state) {
  const styles = { InlineCode: 'code', FencedCode: 'fenced', CodeBlock: 'plain', Blockquote: 'quote', Table: 'table' }
  for (let node = syntaxTree(state).resolve(state.selection.main.head, state.selection.main.empty ? 1 : -1); node; node = node.parent) {
    if (styles[node.name]) return { style: styles[node.name], node }
  }
  return { style: 'none', node: null }
}

function applyBlockStyle(view, style, language = '') {
  if (!['none', 'quote', 'code', 'plain', 'fenced', 'table'].includes(style)) return false
  const state = view.state, selection = state.selection.main
  const context = stylingContext(state)
  const containsSelection = context.node && selection.from >= context.node.from && selection.to <= context.node.to
  if (style === 'code' && (!containsSelection || context.style === 'code')) {
    if (context.style !== 'code') toggleInlineMark('`')(view)
    view.focus()
    return true
  }
  if (style === 'table') {
    const fence = enclosingNode(state, selection.to, ['FencedCode'])
    const end = fence ? fence.to : state.doc.lineAt(selection.to).to
    const close = fence && fence.lastChild?.name !== 'CodeMark'
      ? '\n' + state.sliceDoc(fence.firstChild.from, fence.firstChild.to) : ''
    const insert = close + '\n\n| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n'
    view.dispatch({ changes: { from: end, insert }, selection: { anchor: end + insert.length }, userEvent: 'input' })
    view.focus()
    return true
  }
  if (style === context.style && containsSelection && style !== 'fenced') return true
  if (style === 'quote' && !containsSelection) {
    const changes = selectedListLines(state).filter(line =>
      !enclosingNode(state, line.from + Math.max(0, line.text.search(/\S/)), ['Blockquote']))
      .map(line => ({ from: line.from, insert: '> ' }))
    if (changes.length) dispatchBlockChanges(view, changes)
    view.focus()
    return true
  }
  const lines = selectedListLines(state)
  let from = lines[0].from, to = lines[lines.length - 1].to
  let source = state.sliceDoc(from, to)
  const node = context.node
  if (node && selection.from >= node.from && selection.to <= node.to
      && (context.style !== 'code' || style === 'none')) {
    from = context.style === 'code' ? node.from : state.doc.lineAt(node.from).from
    to = node.to
    source = state.sliceDoc(from, to)
    if (context.style === 'fenced') {
      const opening = state.doc.lineAt(node.from)
      const last = state.doc.lineAt(node.to)
      const closed = node.lastChild?.name === 'CodeMark'
      source = state.sliceDoc(Math.min(opening.to + 1, node.to), closed ? last.from : node.to).replace(/\n$/, '')
    } else if (context.style === 'plain') source = source.replace(/^(?: {4}|\t)/gm, '')
    else if (context.style === 'quote') source = source.replace(/^ {0,3}> ?/gm, '')
    else if (context.style === 'code') source = state.sliceDoc(node.firstChild.to, node.lastChild.from)
    else if (context.style === 'table') {
      const model = parseTableSource(source)
      if (model) source = model.rows.map(row => row.join('\t')).join('\n')
    }
  }
  let insert = source, caretOffset = 0
  if (style === 'code') {
    source = source.replace(/\n/g, ' ')
    const fence = '`'.repeat(Math.max(1, ...(source.match(/`+/g) || []).map(run => run.length + 1)))
    const pad = /^`|`$/.test(source) || (/^ .* $/.test(source) && /\S/.test(source)) ? ' ' : ''
    insert = fence + pad + source + pad + fence
    caretOffset = fence.length + pad.length
  }
  if (style === 'quote') { insert = source.split('\n').map(line => '> ' + line).join('\n'); caretOffset = 2 }
  if (style === 'plain') { insert = source.split('\n').map(line => '    ' + line).join('\n'); caretOffset = 4 }
  if (style === 'fenced') {
    const runs = source.match(/`+/g) || []
    const fence = '`'.repeat(Math.max(3, ...runs.map(run => run.length + 1)))
    const info = String(language).replace(/[^\w+-]/g, '')
    const opening = fence + info + '\n'
    insert = opening + source + '\n' + fence
    caretOffset = opening.length
  }
  if (style === 'plain' && from > 0 && state.doc.lineAt(from - 1).text.trim()) {
    insert = '\n' + insert
    caretOffset++
  }
  view.dispatch({ changes: { from, to, insert }, selection: { anchor: from + caretOffset }, userEvent: 'input' })
  view.focus()
  return true
}

function insertLink(view) {
  const range = view.state.selection.main
  const text = view.state.sliceDoc(range.from, range.to) || "text"
  const insert = `[${text}](url)`
  const urlStart = range.from + text.length + 3
  view.dispatch({
    changes: { from: range.from, to: range.to, insert },
    selection: EditorSelection.range(urlStart, urlStart + 3),
    userEvent: "input",
    scrollIntoView: true,
  })
  return true
}

// A second fence typed inside an existing block is a deliberate closing mark,
// so only a fence that starts its own line can be paired automatically.
const autoClosedFence = Annotation.define()

function fenceStartAt(state, pos) {
  let node = syntaxTree(state).resolve(pos, -1)
  while (node) {
    if (node.name === "FencedCode") return node.from
    node = node.parent
  }
  return null
}

const autoCloseFence = EditorState.transactionFilter.of((tr) => {
  if (!tr.docChanged || !tr.isUserEvent("input") || tr.annotation(autoClosedFence)) {
    return tr
  }

  const selection = tr.newSelection.main
  if (!selection.empty) return tr

  const line = tr.newDoc.lineAt(selection.head)
  const offset = selection.head - line.from
  if (line.text.slice(0, offset) !== "```" || line.text.slice(offset) !== "") {
    return tr
  }

  let openedOnThisLine = false
  let openingOldPos = null
  tr.changes.iterChanges((fromA, toA, fromB, toB, inserted) => {
    if (openedOnThisLine || fromB > selection.head || toB < selection.head) return
    const oldLine = tr.startState.doc.lineAt(fromA)
    const oldPrefix = oldLine.text.slice(0, fromA - oldLine.from)
    const oldSuffix = oldLine.text.slice(toA - oldLine.from)
    const insertedText = inserted.toString()
    const completesFence = (oldPrefix === "" && insertedText === "```")
      || (oldPrefix === "``" && insertedText === "`")
    openedOnThisLine = oldSuffix === ""
      && completesFence
      && fromB <= line.from + 2
      && toB >= line.from + 3
    if (openedOnThisLine) openingOldPos = fromA
  })
  if (!openedOnThisLine) return tr

  const oldLine = tr.startState.doc.lineAt(openingOldPos)
  const existingFenceStart = fenceStartAt(tr.startState, openingOldPos)
  if (existingFenceStart != null && existingFenceStart < oldLine.from) return tr

  return [
    tr,
    {
      changes: { from: selection.head, insert: "\n\n```" },
      selection: { anchor: selection.head + 1 },
      annotations: autoClosedFence.of(true),
      sequential: true,
    },
  ]
})

// Markdown assigns semantic meaning to four leading spaces: headings,
// paragraphs, tables, fences, and other top-level blocks become code blocks.
// List items are different: keep each Tab as authored, including repeated
// indentation, rather than imposing a maximum nesting depth in the editor.
function indentMarkdownListItems(view) {
  const selection = view.state.selection.main
  const firstLine = view.state.doc.lineAt(selection.from)
  let lastLine = view.state.doc.lineAt(selection.to)
  if (!selection.empty
      && selection.to === lastLine.from
      && lastLine.number > firstLine.number) {
    lastLine = view.state.doc.line(lastLine.number - 1)
  }

  if (selection.empty) {
    const fence = fencedCodeAt(view.state, selection.head)
    if (fence) {
      const openingLine = view.state.doc.lineAt(fence.from)
      const closingLine = view.state.doc.lineAt(fence.to)
      if (firstLine.number > openingLine.number
          && (!fence.closed || firstLine.number < closingLine.number)) {
        return insertTab(view)
      }
    }
  }

  const firstMatch = firstLine.text.match(markdownListMarker)
  if (!firstMatch) {
    // Within ordinary text, behave like a text editor and insert a tab at the
    // caret. Guard the leading source margin:
    // indenting a top-level Markdown block there would reinterpret it as an
    // indented code block.
    if (selection.empty) {
      const offset = selection.head - firstLine.from
      const leadingWhitespace = firstLine.text.match(/^[ \t]*/)?.[0].length || 0
      if (offset > leadingWhitespace) return insertTab(view)
    }
    return true
  }
  const changes = []
  for (let number = firstLine.number; number <= lastLine.number; number++) {
    changes.push({ from: view.state.doc.line(number).from, insert: "    " })
  }
  dispatchBlockChanges(view, changes)
  return true
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

window.MDEditor = {
  create(parent, doc, callbacks) {
    const onDirty = callbacks && callbacks.onDirty
    const onPasteImage = callbacks && callbacks.onPasteImage
    // Live preview spacing tokens from the host stylesheet (MarkdownHTML
    // constants) — see METRICS for the headless defaults.
    Object.assign(METRICS, (callbacks && callbacks.spacing) || {})
    const view = new EditorView({
      parent,
      state: EditorState.create({
        doc,
        extensions: [
          history(),
          documentFind,
          findTheme,
          // Native selection, not drawSelection(): the selection layer paints
          // every selected line edge to edge, while WebKit's own selection
          // follows the text once the host styles .cm-content as a flex
          // column (see EditorViewController). CodeMirror re-syncs the DOM
          // selection to the rendered viewport as the document virtualizes.
          dropCursor(),
          EditorView.lineWrapping,
          EditorView.perLineTextDirection.of(true),
          indentUnit.of("    "),
          directionLines,
          // Parse a leading `---` block as YAML frontmatter so its lines
          // never surface as a thematic break plus setext heading.
          yamlFrontmatter({
            content: markdown({
              base: markdownLanguage,
              codeLanguages,
              extensions: obsidianHighlight,
            }),
          }),
          activeCodeBlock,
          wrappedCodeBlocks,
          pointerPreview,
          stablePointerPreview,
          anchoredPointerSelection,
          mermaidPreviews,
          tableEditors,
          syntaxHighlighting(codeHighlight),
          Prec.lowest(livePreview),
          codeBlockScrolling,
          alignInactiveHeadings,
          autoCloseFence,
          closeBrackets(),
          // paragraphReflow deliberately omitted: the preview renders
          // single newlines as hard breaks, so the
          // editor keeps them visible instead of joining lines.
          keymap.of([
            { key: "Mod-b", run: toggleInlineMark("**") },
            { key: "Mod-i", run: toggleInlineMark("*") },
            { key: "Tab", run: indentMarkdownListItems, shift: indentLess },
            ...closeBracketsKeymap,
            ...markdownKeymap,
            ...defaultKeymap,
            ...historyKeymap,
          ]),
          // Fires on every change; the host debounces for autosave.
          EditorView.updateListener.of((update) => {
            if (callbacks?.onFormattingChange && (update.selectionSet || update.docChanged
                || update.focusChanged || syntaxTree(update.startState) !== syntaxTree(update.state))) {
              callbacks.onFormattingChange(formattingState(update.state))
            }
            if (update.docChanged && callbacks?.onSearchChange) {
              const search = update.state.field(documentFind)
              callbacks.onSearchChange({ index: search.index + 1, total: search.matches.length })
            }
            if (update.docChanged && onDirty
                && !update.transactions.some((transaction) => transaction.isUserEvent("rename"))) {
              onDirty()
            }
          }),
          EditorView.domEventHandlers({
            paste(event, view) {
              if (event.target instanceof Element
                  && event.target.closest(".cm-md-table-cell")) return false
              const items = Array.from(event.clipboardData?.items || [])
              if (!items.some((item) => String(item.type || "").toLowerCase().startsWith("image/"))) return false
              if (typeof onPasteImage !== "function") return false
              event.preventDefault()
              const selection = view.state.selection.main
              onPasteImage(selection.from, selection.to)
              return true
            },
          }),
        ],
      }),
    })
    // On macOS 26+ WebKit scrolls the page and owns the chrome backdrop.
    // Other hosts retain CodeMirror's internal scroll container.
    const pageScrolling = !!(callbacks && callbacks.pageScrolling)
    const scroller = pageScrolling ? document.scrollingElement : view.scrollDOM
    const scrollEvents = pageScrolling ? window : scroller
    let preservedSourcePosition = null
    let preservedSourceGap = 0
    let preservedScrollTop = null
    // CodeMirror block heights start at the first line, after content padding.
    // Scroll offsets start at the scroll container's origin instead. Convert
    // both ways so page padding is preserved during read/edit hand-offs.
    const documentScrollOrigin = () => view.documentTop + scroller.scrollTop
      - (pageScrolling ? 0 : scroller.getBoundingClientRect().top)
    const lineContentBlock = (position) => {
      const block = view.lineBlockAt(position)
      let paddingTop = 0
      let paddingBottom = 0
      try {
        const dom = view.domAtPos(position).node
        const element = dom.nodeType === Node.ELEMENT_NODE ? dom : dom.parentElement
        const line = element && element.closest(".cm-line")
        if (line) {
          const style = getComputedStyle(line)
          paddingTop = parseFloat(style.paddingTop) || 0
          paddingBottom = parseFloat(style.paddingBottom) || 0
        }
      } catch (_) {
        // A distant virtualized line may not have DOM until scrollIntoView
        // runs. The second animation frame measures it precisely.
      }
      return {
        top: block.top + paddingTop,
        height: Math.max(block.height - paddingTop - paddingBottom, 1),
        sourceStart: view.state.doc.lineAt(block.from).number,
        sourceEnd: view.state.doc.lineAt(block.to).number + 1,
      }
    }
    const commands = {
      bold: toggleInlineMark("**"),
      italic: toggleInlineMark("*"),
      strikethrough: toggleInlineMark("~~"),
      highlight: toggleInlineMark("=="),
      code: toggleInlineMark("`"),
      h0: setHeading(0),
      h1: setHeading(1),
      h2: setHeading(2),
      h3: setHeading(3),
      h4: setHeading(4),
      h5: setHeading(5),
      h6: setHeading(6),
      quote: toggleBlockPrefix("> ", /^>\s?/),
      bulletList: toggleBlockPrefix("- ", /^\s*[-*+]\s/),
      orderedList,
      taskList: toggleBlockPrefix("- [ ] ", /^\s*[-*+]\s+\[[ xX]\]\s/),
      link: insertLink,
    }
    if (callbacks?.onCopyCode) codeCopyHandlers.set(view, callbacks.onCopyCode)
    callbacks?.onFormattingChange?.(formattingState(view.state))
    return {
      getMarkdown: () => view.state.doc.toString(),
      getBlockStyle: () => stylingContext(view.state).style,
      setBlockStyle: (style, language) => applyBlockStyle(view, style, language),
      getListStyle: () => {
        const styles = editableListLines(view.state).map(line => listPrefix(line.text).style)
        if (!styles.length) return 'none'
        return styles.every(style => style === styles[0]) ? styles[0] : 'mixed'
      },
      setListStyle: style => applyListStyle(view, style),
      getLinkSelection: (expandLink = false) => {
        const { from, to } = view.state.selection.main
        const link = enclosingNode(view.state, from, ['Link'])
        if (expandLink && link && to <= link.to) {
          const marks = link.getChildren('LinkMark')
          return { from: link.from, to: link.to,
            text: view.state.sliceDoc(marks[0].to, marks[1].from) }
        }
        return { from, to, text: view.state.sliceDoc(from, to) }
      },
      insertLinkFromPopover: (text, url, from, to) => {
        const destination = String(url).trim()
        if (!destination || /[\r\n]/.test(destination)
            || from < 0 || to < from || to > view.state.doc.length) return false
        const link = enclosingNode(view.state, from, ['Link'])
        if (link && (from > link.from || to < link.to)) return false
        const endLink = to > from ? enclosingNode(view.state, to - 1, ['Link']) : null
        if (endLink && (from > endLink.from || to < endLink.to)) return false
        const label = (String(text) || destination).replace(/\\/g, '\\\\').replace(/([\[\]])/g, '\\$1').replace(/[\r\n]+/g, ' ')
        const target = destination.replace(/[\s<>\\()]/g, character =>
          /[()]/.test(character) ? '%' + character.charCodeAt(0).toString(16).toUpperCase() : encodeURIComponent(character))
        const insert = `[${label}](${target})`
        view.dispatch({ changes: { from, to, insert }, selection: { anchor: from + insert.length }, userEvent: 'input' })
        view.focus()
        return true
      },
      getHeadingLevel: () => {
        for (let node = syntaxTree(view.state).resolveInner(view.state.selection.main.head, 1); node; node = node.parent) {
          const heading = /^(?:ATX|Setext)Heading([1-6])$/.exec(node.name)
          if (heading) return Number(heading[1])
        }
        return 0
      },
      find: (query, backwards = false, beginsWith = false) => {
        const previous = view.state.field(documentFind)
        const same = previous.query === query && previous.beginsWith === beginsWith
        let index = 0
        if (same && previous.matches.length) {
          index = (previous.index + (backwards ? -1 : 1) + previous.matches.length) % previous.matches.length
        } else if (backwards) {
          index = Number.MAX_SAFE_INTEGER
        }
        view.dispatch({ effects: setFind.of({ query, beginsWith, index }) })
        const search = view.state.field(documentFind)
        const match = search.matches[search.index]
        if (match) {
          preservedSourcePosition = null
          didUserScroll = true
          view.dispatch({ effects: EditorView.scrollIntoView(match.from, { y: "center" }) })
        }
        return { index: search.index + 1, total: search.matches.length }
      },
      isSyntaxReady: () => syntaxTreeAvailable(view.state, view.state.doc.length),
      replaceMarkdown: (markdown) => {
        const text = String(markdown || "")
        const length = text.length
        const selection = view.state.selection.main
        const anchor = Math.min(selection.anchor, length)
        const head = Math.min(selection.head, length)
        const scrollTop = scroller.scrollTop
        view.dispatch({
          changes: { from: 0, to: view.state.doc.length, insert: text },
          selection: { anchor, head },
          userEvent: "rename",
          annotations: Transaction.addToHistory.of(false),
        })
        requestAnimationFrame(() => {
          scroller.scrollTop = scrollTop
          view.requestMeasure()
        })
      },
      insertTextAt: (text, from, to) => {
        const length = view.state.doc.length
        const start = Math.max(0, Math.min(Number(from) || 0, length))
        const end = Math.max(start, Math.min(Number(to) || start, length))
        view.dispatch({
          changes: { from: start, to: end, insert: String(text || "") },
          selection: { anchor: start + String(text || "").length },
          userEvent: "input",
          scrollIntoView: true,
        })
        view.focus()
      },
      focus: () => view.focus(),
      getScrollAnchor: () => {
        // Native WebKit/scrollbar scrolling need not deliver a DOM wheel or
        // pointer event. Reuse the incoming anchor only at its actual offset.
        if (Number.isFinite(preservedSourcePosition)
            && Math.abs(scroller.scrollTop - preservedScrollTop) <= 0.5) {
          return { position: preservedSourcePosition, gap: preservedSourceGap || 0 }
        }
        const viewportY = scroller.scrollTop - documentScrollOrigin()
        const visibleLine = view.lineBlockAtHeight(viewportY)
        const line = view.state.doc.lineAt(visibleLine.from)
        const sourceLineBlock = lineContentBlock(line.from)
        const progress = sourceLineBlock.height > 0
          ? Math.min(Math.max((viewportY - sourceLineBlock.top) / sourceLineBlock.height, 0), 1)
          : 0
        // Near the document top the viewport can sit above the first line
        // (inside the page padding), which the fractional position cannot
        // express. Carry that remaining pixel gap so the other surface can
        // reproduce the exact viewport, not just the line.
        const gap = Math.max(sourceLineBlock.top - viewportY, 0)
        return {
          position: sourceLineBlock.sourceStart
            + progress * (sourceLineBlock.sourceEnd - sourceLineBlock.sourceStart),
          gap,
        }
      },
      setScrollPosition: (progress, sourcePosition, sourceGap) => new Promise((resolve) => {
        const maximum = Math.max(scroller.scrollHeight - scroller.clientHeight, 0)
        let target = maximum * Math.min(Math.max(Number(progress) || 0, 0), 1)
        let linePosition = null
        const gap = Number.isFinite(sourceGap) ? Math.max(sourceGap, 0) : 0

        if (Number.isFinite(sourcePosition) && sourcePosition >= 1) {
          const sourceLine = Math.min(Math.floor(sourcePosition), view.state.doc.lines)
          linePosition = view.state.doc.line(sourceLine).from
          if (linePosition != null) {
            const block = lineContentBlock(linePosition)
            const fraction = (sourcePosition - block.sourceStart) / (block.sourceEnd - block.sourceStart)
            target = documentScrollOrigin() + block.top + block.height * fraction - gap
            // Let CodeMirror create the viewport around the target before
            // applying the precise within-block offset. Directly assigning a
            // distant scrollTop can briefly leave its virtualized DOM empty.
            view.dispatch({
              effects: EditorView.scrollIntoView(linePosition, { y: "start" }),
            })
          }
        }

        requestAnimationFrame(() => {
          const measuredMaximum = Math.max(scroller.scrollHeight - scroller.clientHeight, 0)
          if (linePosition != null) {
            const block = lineContentBlock(linePosition)
            const fraction = (sourcePosition - block.sourceStart) / (block.sourceEnd - block.sourceStart)
            target = documentScrollOrigin() + block.top + block.height * fraction - gap
          } else {
            target = measuredMaximum * Math.min(Math.max(Number(progress) || 0, 0), 1)
          }
          scroller.scrollTop = Math.min(Math.max(target, 0), measuredMaximum)
          scrollEvents.dispatchEvent(new Event("scroll"))
          view.requestMeasure()
          requestAnimationFrame(() => {
            preservedSourcePosition = Number.isFinite(sourcePosition) ? sourcePosition : null
            preservedSourceGap = Number.isFinite(sourcePosition) ? gap : 0
            preservedScrollTop = scroller.scrollTop
            resolve(true)
          })
        })
      }),
      // Used by hosts that map an external pointer target into the source.
      // Mark it as a pointer selection so fenced blocks enter source mode.
      select: (anchor, head = anchor) => view.dispatch({
        selection: { anchor, head },
        userEvent: "select.pointer",
      }),
      insert: (text) => {
        const range = view.state.selection.main
        const handled = view.state.facet(EditorView.inputHandler)
          .some((handler) => handler(view, range.from, range.to, text))
        if (handled) return
        view.dispatch({
          changes: { from: range.from, to: range.to, insert: text },
          selection: { anchor: range.from + text.length },
          userEvent: "input",
        })
      },
      exec: (name) => {
        const command = commands[name]
        if (command) { command(view); view.focus() }
      },
      performTableContextAction: (token, action) => {
        if (!pendingTableContextAction || pendingTableContextAction.token !== token) return false
        const pending = pendingTableContextAction
        pendingTableContextAction = null
        pending.perform(action)
        return true
      },
      destroy: () => {
        view.destroy()
      },
    }
  },
}
