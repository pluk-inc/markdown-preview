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
  constructor(source, from) { super(); this.source = source; this.from = from }
  eq(other) { return other.source === this.source && other.from === this.from }

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
      view.dispatch({
        selection: { anchor: this.from + 1 },
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

const hide = Decoration.replace({})
const bulletDeco = Decoration.replace({ widget: new TextWidget("•", "cm-md-bullet") })
const hrDeco = Decoration.replace({ widget: new RuleWidget() })

const joinDeco = Decoration.replace({ widget: new TextWidget(" ", "cm-md-join") })

const HEADING_LINE = {}
const for_ = (i) => Decoration.line({ class: "cm-md-h" + i })
for (let i = 1; i <= 6; i++) HEADING_LINE[i] = for_(i)
const inactiveHeadingLine = Decoration.line({ class: "cm-md-heading-inactive" })
const blankBeforeHeadingLine = Decoration.line({ class: "cm-md-blank-before-heading" })
const quoteLine = Decoration.line({ class: "cm-md-quote" })
const codeLine = Decoration.line({ class: "cm-md-codeblock" })
const codeLineFirst = Decoration.line({ class: "cm-md-codeblock cm-md-codeblock-first" })
const codeLineLast = Decoration.line({ class: "cm-md-codeblock cm-md-codeblock-last" })
const tableLine = Decoration.line({ class: "cm-md-table" })
const fenceMark = Decoration.mark({ class: "cm-md-fence-info" })
const hiddenCodeFenceSource = Decoration.mark({ class: "cm-md-code-fence-source-hidden" })
const hiddenHeadingSource = Decoration.mark({ class: "cm-md-heading-source-hidden" })
const setextMarkerLine = Decoration.line({ class: "cm-md-setext-marker-line" })
const setextSource = Decoration.mark({ class: "cm-md-setext-source" })
const linkMark = Decoration.mark({ class: "cm-md-link" })
const urlMark = Decoration.mark({ class: "cm-md-url" })
const strikethroughMark = Decoration.mark({ class: "cm-md-strikethrough" })

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

    const head = tr.state.selection.main.head
    if (tr.isUserEvent("select.pointer")) return fencedCodeAt(tr.state, head)
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
          widget: new MermaidWidget(details.source, node.from),
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
  update: (_value, tr) => buildMermaidPreviews(tr.state),
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
  const touches = (from, to) => view.hasFocus && sel.from <= to && sel.to >= from
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
  const collapseBlankBefore = (pos) => {
    const line = state.doc.lineAt(pos)
    if (line.number <= 1) return
    const previous = state.doc.line(line.number - 1)
    if (previous.text.length === 0) lineOnce(previous.from, blankBeforeHeadingLine)
  }

  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from, to,
      enter: (node) => {
        const name = node.name

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
          ranges.push(Decoration.mark({ class: "cm-md-inline-code" }).range(node.from, node.to))
          return
        }
        if (name === "CodeMark") {
          const parent = node.node.parent
          if (parent && parent.name === "InlineCode" && !touches(parent.from, parent.to)) {
            ranges.push(hide.range(node.from, node.to))
          } else if (parent && parent.name === "FencedCode"
              && !isActiveFence(parent)) {
            const line = state.doc.lineAt(node.from)
            // Hide the complete source line so the opening language info and
            // closing fence disappear together. A mark (rather than replace)
            // keeps its geometry stable when this block becomes active.
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
        if (name === "ListMark") {
          const mark = state.doc.sliceString(node.from, node.to)
          if ((mark === "-" || mark === "*" || mark === "+") && !touchesLineOf(node.from)) {
            ranges.push(bulletDeco.range(node.from, node.to))
          }
          return
        }

        // --- Fenced code -----------------------------------------------
        if (name === "FencedCode") {
          const first = state.doc.lineAt(node.from)
          const last = state.doc.lineAt(node.to)
          let pos = node.from
          while (pos <= node.to) {
            const line = state.doc.lineAt(pos)
            const deco = line.from === first.from ? codeLineFirst
              : line.from === last.from ? codeLineLast
              : codeLine
            lineOnce(line.from, deco)
            if (line.to >= node.to) break
            pos = line.to + 1
          }
          return
        }
        if (name === "CodeInfo") {
          ranges.push(fenceMark.range(node.from, node.to))
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
    if (changes.length) view.dispatch({ changes, userEvent: "input" })
    return true
  }
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
  if (changes.length) view.dispatch({ changes, userEvent: "input" })
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
    const view = new EditorView({
      parent,
      state: EditorState.create({
        doc,
        extensions: [
          history(),
          drawSelection(),
          dropCursor(),
          EditorView.lineWrapping,
          markdown({ base: markdownLanguage, codeLanguages }),
          activeCodeBlock,
          mermaidPreviews,
          syntaxHighlighting(codeHighlight),
          livePreview,
          alignInactiveHeadings,
          // paragraphReflow deliberately omitted: the preview renders
          // single newlines as hard breaks (Obsidian-style), so the
          // editor keeps them visible instead of joining lines.
          keymap.of([
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
    const commands = {
      strikethrough: toggleInlineMark("~~"),
      code: toggleInlineMark("`"),
      h0: setHeading(0),
      h1: setHeading(1),
      h2: setHeading(2),
      h3: setHeading(3),
      quote: toggleBlockPrefix("> ", /^>\s?/),
      bulletList: toggleBlockPrefix("- ", /^\s*[-*+]\s/),
      orderedList,
      link: insertLink,
    }
    return {
      getMarkdown: () => view.state.doc.toString(),
      focus: () => view.focus(),
      getScrollAnchor: () => {
        const viewportY = view.scrollDOM.scrollTop
        const visibleLine = view.lineBlockAtHeight(viewportY)
        let node = syntaxTree(view.state).resolve(visibleLine.from, 1)
        while (node.parent && node.parent.name !== "Document") node = node.parent
        const blockLine = view.state.doc.lineAt(node.from).number
        const blockTop = view.lineBlockAt(node.from).top
        return { line: blockLine, offset: blockTop - view.scrollDOM.scrollTop }
      },
      setScrollPosition: (progress, sourceLine, viewportOffset) => new Promise((resolve) => {
        const scroller = view.scrollDOM
        const maximum = Math.max(scroller.scrollHeight - scroller.clientHeight, 0)
        let target = maximum * Math.min(Math.max(Number(progress) || 0, 0), 1)
        let linePosition = null

        if (Number.isInteger(sourceLine)
            && sourceLine >= 1 && sourceLine <= view.state.doc.lines) {
          linePosition = view.state.doc.line(sourceLine).from
          if (linePosition != null) {
            const offset = Number.isFinite(viewportOffset) ? viewportOffset : 0
            target = view.lineBlockAt(linePosition).top - offset
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
            const offset = Number.isFinite(viewportOffset) ? viewportOffset : 0
            target = view.lineBlockAt(linePosition).top - offset
          } else {
            target = measuredMaximum * Math.min(Math.max(Number(progress) || 0, 0), 1)
          }
          scroller.scrollTop = Math.min(Math.max(target, 0), measuredMaximum)
          scroller.dispatchEvent(new Event("scroll"))
          view.requestMeasure()
          requestAnimationFrame(() => resolve(true))
        })
      }),
      // Used by hosts that map an external pointer target into the source.
      // Mark it as a pointer selection so fenced blocks enter source mode.
      select: (anchor) => view.dispatch({
        selection: { anchor },
        userEvent: "select.pointer",
      }),
      exec: (name) => {
        const command = commands[name]
        if (command) { command(view); view.focus() }
      },
      destroy: () => view.destroy(),
    }
  },
}
