import { Compartment, EditorState } from "@codemirror/state"
import { drawSelection, EditorView, keymap } from "@codemirror/view"
import { standardKeymap } from "@codemirror/commands"
import { MergeView } from "@codemirror/merge"

// CodeMirror compares normalized lines. Copy from the original snapshot so
// selections retain CRLF and mixed line endings, including collapsed text.
function copySnapshot(source) {
  const starts = [0]
  for (const match of source.matchAll(/\r\n|\r|\n/g)) starts.push(match.index + match[0].length)
  return EditorView.domEventHandlers({ copy(event, view) {
    if (!event.clipboardData || view.state.selection.empty) return false
    const offset = pos => {
      const line = view.state.doc.lineAt(pos)
      return starts[line.number - 1] + pos - line.from
    }
    const text = view.state.selection.ranges.map(({ from, to }) =>
      source.slice(offset(from), offset(to))).join("\n")
    event.clipboardData.setData("text/plain", text)
    event.preventDefault()
    return true
  } })
}

// This view never edits either snapshot. The native sheet owns resolution
// and change navigation; it drives MDConflictNavigate.
window.MDConflictDiff = (disk, draft, labels) => {
  const host = document.getElementById("comparison")
  host.replaceChildren()
  const appearance = new Compartment()
  const media = matchMedia("(prefers-color-scheme: dark)")
  const theme = () => EditorView.theme({
    "&": { backgroundColor: "transparent", color: "inherit" },
    ".cm-scroller": { fontFamily: "inherit" },
    ".cm-content": { padding: "10px 0" },
  }, { dark: media.matches })
  const extensions = [
    EditorState.readOnly.of(true), EditorView.editable.of(false),
    EditorView.lineWrapping, drawSelection(), keymap.of(standardKeymap),
    EditorState.phrases.of({ "$ unchanged lines": labels.unchanged }),
    appearance.of(theme()),
  ]
  const merge = new MergeView({
    parent: host,
    a: { doc: disk, extensions: [...extensions, copySnapshot(disk),
      EditorView.contentAttributes.of({ "aria-label": labels.disk, tabindex: "0" })] },
    b: { doc: draft, extensions: [...extensions, copySnapshot(draft),
      EditorView.contentAttributes.of({ "aria-label": labels.draft, tabindex: "0" })] },
    highlightChanges: true,
    gutter: true,
    collapseUnchanged: { margin: 3, minSize: 8 },
  })
  let current = -1
  // A native button and its keyboard equivalent expose all context in both panes.
  window.MDConflictShowWholeFile = () => {
    merge.reconfigure({ collapseUnchanged: undefined })
  }
  // Returns the 1-based change shown, and the total, for the native counter.
  window.MDConflictNavigate = direction => {
    const total = merge.chunks.length
    if (!total) return [0, 0]
    current = (current + direction + total) % total
    const chunk = merge.chunks[current]
    // There is one shared scroller. A second request on the empty side of a
    // deletion would scroll past the block the user came to inspect.
    const [view, from] = chunk.fromA < chunk.toA ? [merge.a, chunk.fromA] : [merge.b, chunk.fromB]
    view.dispatch({ effects: EditorView.scrollIntoView(Math.min(from, view.state.doc.length), { y: "start", yMargin: 12 }) })
    return [current + 1, total]
  }
  media.addEventListener("change", () => {
    for (const view of [merge.a, merge.b]) view.dispatch({ effects: appearance.reconfigure(theme()) })
  })
  // Expose the rendered snapshots for WebKit regression tests, not a save bridge.
  window.__conflictDiff = merge
  window.__conflictPosition = window.MDConflictNavigate(1)
  window.__conflictReady = true
}
