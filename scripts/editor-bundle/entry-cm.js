// Typora-style live-preview markdown editor for Markdown Preview.app.
// Bundled with esbuild into a single self-contained IIFE exposing
// window.MDEditor. The document buffer IS the markdown source — saving
// is byte-faithful. Formatting syntax is styled live and marks hide
// themselves unless the cursor is inside the construct.

import {
  EditorView, keymap, ViewPlugin, Decoration, WidgetType,
  drawSelection, dropCursor,
} from "@codemirror/view"
import { EditorState, EditorSelection, StateField } from "@codemirror/state"
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands"
import { markdown, markdownLanguage, markdownKeymap } from "@codemirror/lang-markdown"
import {
  syntaxTree, ensureSyntaxTree, syntaxHighlighting, HighlightStyle,
  LanguageDescription, LanguageSupport, StreamLanguage,
} from "@codemirror/language"
import { tags as t } from "@lezer/highlight"
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

// ---------------------------------------------------------------------------
// Fenced-code languages
// ---------------------------------------------------------------------------

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
      if (!active) return
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
        editor.textContent = value
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
          model.rows[row][column] = editor.innerText || ""
          active = null
          applyModel()
        })
        editor.addEventListener("keydown", (event) => {
          if (event.key === "Escape") {
            event.preventDefault()
            editor.textContent = model.rows[row][column]
            active = null
            editor.blur()
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

function buildTableEditors(state) {
  const ranges = []
  const tree = ensureSyntaxTree(state, state.doc.length, 80) || syntaxTree(state)
  tree.iterate({
    enter(node) {
      if (node.name !== "Table") return
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
  update: (value, transaction) => transaction.docChanged
    ? buildTableEditors(transaction.state)
    : value,
  provide: (field) => EditorView.decorations.from(field),
})

const hide = Decoration.replace({})
const bulletDeco = Decoration.replace({ widget: new TextWidget("•", "cm-md-bullet") })
const hrDeco = Decoration.replace({ widget: new RuleWidget() })

const joinDeco = Decoration.replace({ widget: new TextWidget(" ", "cm-md-join") })

const HEADING_LINE = {}
const for_ = (i) => Decoration.line({ class: "cm-md-h" + i })
for (let i = 1; i <= 6; i++) HEADING_LINE[i] = for_(i)
const inactiveHeadingLine = Decoration.line({ class: "cm-md-heading-inactive" })
// A source line whose height another element owns (a heading's padding, a
// fence card, the document's first-block margin reset) collapses to nothing.
const collapsedLine = Decoration.line({ class: "cm-md-line-collapsed" })

// Preview block margin-top values in CSS px. The host passes the live values
// from MarkdownHTML.swift (the single source of truth) through
// MDEditor.create's `spacing` option; these defaults only serve headless
// harnesses. The preview swallows the single blank source line before each
// block and expresses that separation as the block's own margin-top; the
// editor mirrors it by resizing the blank separator line to the same height.
const METRICS = {
  paragraph: 12,  // p / ul / ol / pre / .md-code-wrap
  quote: 18,      // blockquote
  alert: 24,      // .markdown-alert
  table: 24,      // .md-table-scroll
  hr: 35.25,      // hr (top and bottom)
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
const quoteLine = Decoration.line({ class: "cm-md-quote" })
const codeLine = Decoration.line({ class: "cm-md-codeblock" })
const codeLineFirst = Decoration.line({ class: "cm-md-codeblock cm-md-codeblock-first" })
const codeLineLast = Decoration.line({ class: "cm-md-codeblock cm-md-codeblock-last" })
const tableLine = Decoration.line({ class: "cm-md-table" })
// Preview gives every list item after the first a 0.4em margin-top (and a
// nested list the same via li > ul). Mirror it on the item's first line.
const listItemGapLine = Decoration.line({ class: "cm-md-list-item-gap" })
// Mirrors the preview's list geometry: ul/ol start padding with the marker
// hanging inside it, so item text and wrapped lines align like rendered <li>s.
const listItemLine = Decoration.line({ class: "cm-md-list-item" })
const fenceMark = Decoration.mark({ class: "cm-md-fence-info" })
const hiddenCodeFenceSource = Decoration.mark({ class: "cm-md-code-fence-source-hidden" })
const hiddenHeadingSource = Decoration.mark({ class: "cm-md-heading-source-hidden" })
const setextMarkerLine = Decoration.line({ class: "cm-md-setext-marker-line" })
const setextSource = Decoration.mark({ class: "cm-md-setext-source" })
const linkMark = Decoration.mark({ class: "cm-md-link" })
const urlMark = Decoration.mark({ class: "cm-md-url" })
const strongMark = Decoration.mark({ class: "cm-md-strong" })
const emphasisMark = Decoration.mark({ class: "cm-md-emphasis" })
const strikethroughMark = Decoration.mark({ class: "cm-md-strikethrough" })

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
  const codeMarks = []
  for (let child = node.node.firstChild; child; child = child.nextSibling) {
    if (child.name === "CodeInfo") info = state.doc.sliceString(child.from, child.to)
    if (child.name === "CodeMark") codeMarks.push(child)
  }

  const language = info.trim().split(/\s+/, 1)[0].toLowerCase()
  const openingLine = state.doc.lineAt(node.from)
  const sourceFrom = openingLine.to < state.doc.length ? openingLine.to + 1 : openingLine.to
  let sourceTo = node.to
  if (codeMarks.length > 1) sourceTo = state.doc.lineAt(codeMarks[codeMarks.length - 1].from).from
  return {
    language,
    source: state.doc.sliceString(sourceFrom, sourceTo).replace(/\n$/, ""),
  }
}

function fencedCodeAt(state, pos) {
  // Stay in the outer Markdown tree—the innermost mounted language tree does
  // not retain FencedCode as one of its parents.
  let node = syntaxTree(state).resolve(pos, -1)
  while (node) {
    if (node.name === "FencedCode") return { from: node.from, to: node.to }
    node = node.parent
  }
  return null
}

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
      if (details.language === "mermaid" && !isActive) {
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

    if (activeChanged || fenceSyntaxChanged) return buildMermaidPreviews(tr.state)
    if (tr.docChanged) return value.map(tr.changes)
    return value
  },
  provide: (field) => EditorView.decorations.from(field),
})

function buildDecorations(view) {
  const ranges = []
  const { state } = view
  const sel = state.selection.main
  const activeFence = state.field(activeCodeBlock)

  // CodeMirror always owns a selection at offset zero, even before the user
  // clicks the editor. Only reveal source syntax when the editor truly has
  // keyboard focus; otherwise the first block looks spuriously active.
  // A range selection is an operation on rendered content, not a request to
  // reveal every Markdown marker it spans. Only a caret activates source
  // syntax; this keeps Cmd-A and long drag selections in live-preview form.
  const touches = (from, to) => view.hasFocus && sel.empty
    && sel.head >= from && sel.head <= to
  const touchesLineOf = (pos) => {
    const line = state.doc.lineAt(pos)
    return touches(line.from, line.to)
  }
  const isActiveFence = (node) => activeFence != null
    && node.from <= activeFence.from && node.to >= activeFence.to
  const decoratedLines = new Set()
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
  // One blank source line between blocks is Markdown's normal separator; the
  // preview swallows it and lets the next block's margin-top own that space.
  // Mirror it here: the blank line directly above each block collapses to
  // zero before headings (their padding-top owns the space) or resizes to
  // the following block's semantic margin otherwise. Additional blank lines
  // keep their natural source-line height in both surfaces.
  const blankRunBefore = (pos) => {
    const line = state.doc.lineAt(pos)
    let first = line.number
    // Only "one blank" vs "several" (plus the document-start case) changes
    // the emitted separator, so cap the walk against pathological runs.
    const stop = Math.max(first - 64, 1)
    while (first > stop && state.doc.line(first - 1).text.length === 0) first--
    return { line, first, count: line.number - first }
  }
  const collapseBlankBefore = (pos) => {
    const run = blankRunBefore(pos)
    if (run.count === 0) return
    lineOnce(state.doc.line(run.line.number - 1).from, collapsedLine)
  }
  // iterate visits top-level blocks in document order, so the previous
  // block's name is a running variable; the tree is resolved only for the
  // first block of a visible range, whose predecessor was never visited.
  let lastTopBlockName = null
  const topBlockNameBefore = (blankFirstLine) => {
    if (lastTopBlockName != null) return lastTopBlockName
    if (blankFirstLine <= 1) return null
    const prev = state.doc.line(blankFirstLine - 1)
    let n = syntaxTree(state).resolveInner(prev.from, 1)
    while (n.parent && n.parent.name !== "Document") n = n.parent
    return n.name
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
  const separatorBlankBefore = (node) => {
    const run = blankRunBefore(node.from)
    if (run.count === 0) return
    const separator = state.doc.line(run.line.number - 1)
    if (run.first === 1) {
      // Blank lines open the document. The preview strips the first block's
      // margin entirely, so a single leading blank occupies no height.
      lineOnce(separator.from, run.count === 1
        ? collapsedLine
        : blockSeparatorLine(blockMarginTop(node)))
      return
    }
    // hr is the only block with a margin-bottom. Adjacent margins collapse in
    // the preview (max); literal blank-line spacers between them do not.
    const marginBottom = topBlockNameBefore(run.first) === "HorizontalRule"
      ? METRICS.hr : 0
    const marginTop = blockMarginTop(node)
    const height = run.count === 1
      ? Math.max(marginBottom, marginTop)
      : marginBottom + marginTop
    lineOnce(separator.from, blockSeparatorLine(height))
  }

  // Depth relative to the tree root: Document is entered at depth 1, so its
  // children — the top-level blocks — sit at depth 2. Tracking depth (and a
  // stack of enclosing lists) answers parent/sibling questions positionally,
  // without materializing a SyntaxNode per visited node.
  let depth = 0
  const listStack = []

  for (const { from, to } of view.visibleRanges) {
    lastTopBlockName = null
    syntaxTree(state).iterate({
      from, to,
      enter: (node) => {
        depth++
        const name = node.name

        // --- Block separators ------------------------------------------
        if (depth === 2) {
          if (SEPARATOR_BLOCKS.has(name)) separatorBlankBefore(node)
          lastTopBlockName = name
        }

        // --- Headings ------------------------------------------------
        const atx = name.match(/^ATXHeading(\d)$/)
        if (atx) {
          collapseBlankBefore(node.from)
          lineOnce(node.from, HEADING_LINE[+atx[1]])
          if (!touchesLineOf(node.from)) lineOnce(node.from, inactiveHeadingLine)
          return
        }
        const setext = name.match(/^SetextHeading(\d)$/)
        if (setext) {
          collapseBlankBefore(node.from)
          lineOnce(node.from, HEADING_LINE[+setext[1]])
          return
        }
        if (name === "HeaderMark") {
          const parent = node.node.parent
          if (parent && /^ATXHeading/.test(parent.name)) {
            const after = state.doc.sliceString(node.to, node.to + 1)
            const markTo = node.to + (after === " " ? 1 : 0)
            if (!touchesLineOf(node.from)) {
              // Keep the source prefix in layout while hiding it. Its exact
              // width is therefore already reserved before the line becomes
              // active, so revealing it cannot alter wrapping or height.
              ranges.push(hiddenHeadingSource.range(node.from, markTo))
            }
          } else if (parent && /^SetextHeading/.test(parent.name)) {
            lineOnce(node.from, setextMarkerLine)
            ranges.push(setextSource.range(node.from, node.to))
          }
          return
        }

        // --- Blockquotes ----------------------------------------------
        if (name === "Blockquote") {
          eachLine(node.from, node.to, quoteLine)
          return
        }
        if (name === "QuoteMark") {
          if (!touchesLineOf(node.from)) {
            const after = state.doc.sliceString(node.to, node.to + 1)
            ranges.push(hide.range(node.from, node.to + (after === " " ? 1 : 0)))
          }
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
          if (!isFirstItem || isNested) lineOnce(node.from, listItemGapLine)
          eachLine(node.from, node.to, listItemLine)
          return
        }
        if (name === "ListMark") {
          const mark = state.doc.sliceString(node.from, node.to)
          const line = state.doc.lineAt(node.from)
          // Task items (`- [ ]`) keep their literal marker; turning the dash
          // into a bullet dot leaves a confusing "• [ ]" hybrid.
          const isTask = /^\s*\[[ xX]\](\s|$)/.test(line.text.slice(node.to - line.from))
          if ((mark === "-" || mark === "*" || mark === "+") && !isTask && !touchesLineOf(node.from)) {
            // Swallow the following space too: the bullet widget is a fixed
            // 1.6em box, so item text starts exactly at the list padding.
            const after = state.doc.sliceString(node.to, node.to + 1)
            ranges.push(bulletDeco.range(node.from, node.to + (after === " " ? 1 : 0)))
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
          const codeLast = hidesClosingFence && hasInterior
            ? state.doc.line(last.number - 1) : last
          let pos = node.from
          while (pos <= node.to) {
            const line = state.doc.lineAt(pos)
            if ((hidesOpeningFence && line.from === first.from)
                || (hidesClosingFence && line.from === last.from)) {
              lineOnce(line.from, collapsedLine)
            } else if (name === "FencedCode" && !hasInterior
                && line.from !== first.from) {
              lineOnce(line.from, collapsedLine)
            } else {
              const isFirst = line.from === codeFirst.from
              const isLast = line.from === codeLast.from
              if (isFirst) lineOnce(line.from, codeLineFirst)
              if (isLast) lineOnce(line.from, codeLineLast)
              if (!isFirst && !isLast) lineOnce(line.from, codeLine)
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
          if (!parent || touchesLineOf(parent.from)) {
            ranges.push(fenceMark.range(node.from, node.to))
          }
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
            ranges.push(hrDeco.range(node.from, node.to))
          }
          return
        }
      },
      leave: (node) => {
        depth--
        const name = node.name
        if (name === "BulletList" || name === "OrderedList") listStack.pop()
      },
    })
  }
  return Decoration.set(ranges, true)
}

const livePreview = ViewPlugin.fromClass(class {
  constructor(view) { this.decorations = buildDecorations(view) }
  update(update) {
    if (update.docChanged || update.selectionSet || update.viewportChanged || update.focusChanged) {
      this.decorations = buildDecorations(update.view)
    }
  }
}, { decorations: (v) => v.decorations })

// Inactive ATX markers keep their width in layout so line wrapping remains
// stable. Measure that reserved width and translate the whole inactive line
// left by the same amount. Activating the line removes only the transform,
// producing the intended horizontal source reveal without changing height.
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
        return Array.from(view.dom.querySelectorAll(".cm-md-heading-source-hidden"))
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
  { tag: [t.string, t.special(t.string), t.character], class: "hl-string" },
  { tag: [t.comment, t.blockComment, t.lineComment], class: "hl-comment" },
  { tag: [t.number, t.integer, t.float, t.bool, t.atom, t.null], class: "hl-number" },
  { tag: [t.typeName, t.className, t.namespace], class: "hl-type" },
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName], class: "hl-function" },
  { tag: [t.propertyName, t.attributeName, t.labelName], class: "hl-property" },
  { tag: [t.meta, t.processingInstruction, t.punctuation], class: "hl-meta" },
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

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

window.MDEditor = {
  create(parent, doc, callbacks) {
    const onDirty = callbacks && callbacks.onDirty
    // Live preview spacing tokens from the host stylesheet (MarkdownHTML
    // constants) — see METRICS for the headless defaults.
    Object.assign(METRICS, (callbacks && callbacks.spacing) || {})
    const view = new EditorView({
      parent,
      state: EditorState.create({
        doc,
        extensions: [
          history(),
          // CodeMirror virtualizes long documents. Its selection layer keeps
          // a full-document Cmd-A range visible as the viewport moves.
          drawSelection(),
          dropCursor(),
          EditorView.lineWrapping,
          EditorView.perLineTextDirection.of(true),
          directionLines,
          markdown({ base: markdownLanguage, codeLanguages }),
          activeCodeBlock,
          mermaidPreviews,
          tableEditors,
          syntaxHighlighting(codeHighlight),
          livePreview,
          alignInactiveHeadings,
          // paragraphReflow deliberately omitted: the preview renders
          // single newlines as hard breaks, so the
          // editor keeps them visible instead of joining lines.
          keymap.of([
            { key: "Mod-b", run: toggleInlineMark("**") },
            { key: "Mod-i", run: toggleInlineMark("*") },
            ...markdownKeymap,
            ...defaultKeymap,
            ...historyKeymap,
          ]),
          // Fires on every change; the host debounces for autosave.
          EditorView.updateListener.of((update) => {
            if (update.docChanged && onDirty) onDirty()
          }),
        ],
      }),
    })
    let preservedSourcePosition = null
    let preservedSourceGap = 0
    let didUserScroll = false
    let userScrollIntent = false
    let lastScrollTop = view.scrollDOM.scrollTop
    const markScrollIntent = () => { userScrollIntent = true }
    const markKeyboardScrollIntent = (event) => {
      if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End", " "].includes(event.key)) {
        userScrollIntent = true
      }
    }
    const observeScroll = () => {
      const scrollTop = view.scrollDOM.scrollTop
      if (userScrollIntent && Math.abs(scrollTop - lastScrollTop) > 0.5) {
        didUserScroll = true
      }
      lastScrollTop = scrollTop
    }
    view.scrollDOM.addEventListener("wheel", markScrollIntent, { passive: true })
    view.scrollDOM.addEventListener("pointerdown", markScrollIntent, { passive: true })
    view.scrollDOM.addEventListener("keydown", markKeyboardScrollIntent)
    view.scrollDOM.addEventListener("scroll", observeScroll, { passive: true })
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
      }
    }
    const commands = {
      bold: toggleInlineMark("**"),
      italic: toggleInlineMark("*"),
      strikethrough: toggleInlineMark("~~"),
      code: toggleInlineMark("`"),
      h0: setHeading(0),
      h1: setHeading(1),
      h2: setHeading(2),
      h3: setHeading(3),
      quote: toggleBlockPrefix("> ", /^>\s?/),
      bulletList: toggleBlockPrefix("- ", /^\s*[-*+]\s/),
      orderedList,
      taskList: toggleBlockPrefix("- [ ] ", /^\s*[-*+]\s+\[[ xX]\]\s/),
      link: insertLink,
    }
    return {
      getMarkdown: () => view.state.doc.toString(),
      focus: () => view.focus(),
      getScrollAnchor: () => {
        if (!didUserScroll && Number.isFinite(preservedSourcePosition)) {
          return { position: preservedSourcePosition, gap: preservedSourceGap || 0 }
        }
        const viewportY = view.scrollDOM.scrollTop
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
        return { position: line.number + progress, gap }
      },
      setScrollPosition: (progress, sourcePosition, sourceGap) => new Promise((resolve) => {
        const scroller = view.scrollDOM
        const maximum = Math.max(scroller.scrollHeight - scroller.clientHeight, 0)
        let target = maximum * Math.min(Math.max(Number(progress) || 0, 0), 1)
        let linePosition = null
        let lineProgress = 0
        const gap = Number.isFinite(sourceGap) ? Math.max(sourceGap, 0) : 0

        if (Number.isFinite(sourcePosition) && sourcePosition >= 1) {
          const sourceLine = Math.min(Math.floor(sourcePosition), view.state.doc.lines)
          lineProgress = Math.min(Math.max(sourcePosition - sourceLine, 0), 1)
          linePosition = view.state.doc.line(sourceLine).from
          if (linePosition != null) {
            const block = lineContentBlock(linePosition)
            target = block.top + block.height * lineProgress - gap
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
            target = block.top + block.height * lineProgress - gap
          } else {
            target = measuredMaximum * Math.min(Math.max(Number(progress) || 0, 0), 1)
          }
          scroller.scrollTop = Math.min(Math.max(target, 0), measuredMaximum)
          scroller.dispatchEvent(new Event("scroll"))
          view.requestMeasure()
          requestAnimationFrame(() => {
            preservedSourcePosition = Number.isFinite(sourcePosition) ? sourcePosition : null
            preservedSourceGap = Number.isFinite(sourcePosition) ? gap : 0
            didUserScroll = false
            userScrollIntent = false
            lastScrollTop = scroller.scrollTop
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
        view.scrollDOM.removeEventListener("wheel", markScrollIntent)
        view.scrollDOM.removeEventListener("pointerdown", markScrollIntent)
        view.scrollDOM.removeEventListener("keydown", markKeyboardScrollIntent)
        view.scrollDOM.removeEventListener("scroll", observeScroll)
        view.destroy()
      },
    }
  },
}
