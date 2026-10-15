// Math belongs to the Markdown tree so TeX underscores and backslashes never
// become Markdown formatting. Code spans/fences retain their normal precedence.
export const mathSyntax = {
  defineNodes: ["MathDelimiter", "MathLine", "InlineMath", "DisplayMath", { name: "MathBlock", block: true },
    { name: "UnclosedMathBlock", block: true }],
  parseInline: [{
    name: "Math",
    before: "Escape",
    parse(cx, next, pos) {
      if (next !== 36 || cx.char(pos - 1) === 92) return -1
      const display = cx.char(pos + 1) === 36
      const size = display ? 2 : 1
      const start = pos + size
      if (!display && /\s/.test(cx.slice(start, start + 1))) return -1
      for (let end = start; end < cx.end; end++) {
        const ch = cx.char(end)
        if (!display && ch === 10) return -1
        if (ch !== 36) continue
        if (display && cx.char(end + 1) !== 36) continue
        if (end === start || (!display && /\s/.test(cx.slice(end - 1, end)))) break
        return cx.addElement(cx.elt(display ? "DisplayMath" : "InlineMath", pos, end + size))
      }
      // Consume unmatched double delimiters together so the second dollar
      // cannot accidentally open inline math while the block is being typed.
      return display ? cx.addElement(cx.elt("MathDelimiter", pos, pos + 2)) : -1
    },
  }],
  parseBlock: [{
    name: "MathBlock",
    // Only a delimiter on its own line starts a multiline block. Inline
    // display expressions are handled above, including surrounding prose.
    after: "FencedCode",
    parse(cx, line) {
      if (line.next !== 36 || line.text.slice(line.pos).trim() !== "$$") return false
      const from = cx.lineStart + line.pos
      let to = cx.lineStart + line.text.length
      let closed = false
      const lines = []
      while (cx.nextLine()) {
        to = cx.lineStart + line.text.length
        if (line.text.slice(line.pos).trim() === "$$") {
          closed = true
          cx.nextLine()
          break
        }
        lines.push(cx.elt("MathLine", cx.lineStart + line.basePos, to))
      }
      // An unfinished block stays visible and editable, never replaced by a
      // widget that could conceal the rest of the document while typing.
      cx.addElement(cx.elt(closed ? "MathBlock" : "UnclosedMathBlock", from, to, lines))
      return true
    },
    endLeaf(_cx, line) { return line.next === 36 && line.text.slice(line.pos).trim() === "$$" },
  }],
}
