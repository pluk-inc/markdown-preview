package document

// A place in the text of a document: a block by its number, the cell for
// a table (0 in each other block), and a byte in the text of the block or
// of the cell. It needs no layout, so it says the same in each layout of
// the document. A caret, the ends of a selection, and the place of a view
// are such addresses.
//
// Two kinds of places come after the end of the text of a block, and
// the text has no byte for them. `spaces`: how many of the spaces that
// the source has after the end of the text (`Block.end_spaces`) are
// before the place. `empty`: which empty paragraph after the block the
// place is in, from 1 (`empties.odin`). For each, `byte` is the end of
// the last text of the block. Both are 0 for a place in the text.
Address :: struct {
	block, cell, byte: int,
	empty, spaces:     int,
}

// True when `a` comes before `b` in reading order.
before :: proc(a, b: Address) -> bool {
	switch {
	case a.block != b.block:
		return a.block < b.block
	case a.cell != b.cell:
		return a.cell < b.cell
	case a.empty != b.empty:
		return a.empty < b.empty
	case a.byte != b.byte:
		return a.byte < b.byte
	}
	return a.spaces < b.spaces
}

// The last place of a block: after its last empty paragraph, or after
// the spaces at the end of its text. False for a block with no text (a
// rule).
block_end :: proc(doc: ^Document, block: int) -> (at: Address, ok: bool) {
	b := block_at(doc, block)
	if b.empties > 0 {
		return empty_address(doc, block, int(b.empties))
	}
	at = empty_address(doc, block, 0) or_return
	at.spaces = int(b.end_spaces)
	return at, true
}

// An address with the end of its text, and with the spaces after it:
// the end of a line that is the last one of a block. Other addresses
// as they are.
with_end_spaces :: proc(doc: ^Document, at: Address) -> Address {
	at := at
	b := block_at(doc, at.block)
	texts := block_texts(b)
	if at.empty == 0 && at.cell == len(texts) - 1 && at.byte == len(texts[at.cell].bytes) {
		at.spaces = int(b.end_spaces)
	}
	return at
}

// Which of the texts of its block a text is (`block_texts`): the cell of
// a table, 0 in each other block.
cell_of :: proc(b: ^Block, text: ^Text) -> int {
	return int(uintptr(text) - uintptr(raw_data(block_texts(b)))) / size_of(Text)
}

// A selection: two addresses. It needs no layout; only its highlight on
// the lines that show does (`layout.selection_quads`).
Selection :: struct {
	active:        bool,
	anchor, focus: Address,
}

// The two ends of a selection in reading order. False when nothing is
// selected.
selection_range :: proc(s: Selection) -> (from, to: Address, ok: bool) {
	if !s.active || s.anchor == s.focus {
		return
	}
	from, to = s.anchor, s.focus
	if before(to, from) {
		from, to = to, from
	}
	return from, to, true
}

// The selection of all of the text of a document. Not active for a
// document with no text.
select_all :: proc(doc: ^Document) -> (s: Selection) {
	s.anchor, s.focus, s.active = text_ends(doc)
	return
}

// Appends the selected text to `out` as UTF-8.
selection_text :: proc(doc: ^Document, s: Selection, out: ^[dynamic]u8) {
	if from, to, ok := selection_range(s); ok {
		text_between(doc, from, to, out)
	}
}

// The texts of a block in reading order: its cells for a table, its own
// text for a paragraph, a heading, or a code block, none for a rule.
block_texts :: proc(b: ^Block) -> []Text {
	switch b.kind {
	case .Table:
		return b.cells[:]
	case .Rule:
		return nil
	case .Paragraph, .Heading, .Code:
	}
	return ([^]Text)(&b.text)[:1]
}

// The text that an address is in. Nil when the document has no such text
// (no such block, a rule, no such cell).
text_at :: proc(doc: ^Document, at: Address) -> ^Text {
	if at.block < 0 || at.block >= doc.count {
		return nil
	}
	texts := block_texts(block_at(doc, at.block))
	return at.cell >= 0 && at.cell < len(texts) ? &texts[at.cell] : nil
}

// The start of the first text of the document that is not empty, and the
// end of the last one: the two ends of all of its text. False for a
// document with no text.
text_ends :: proc(doc: ^Document) -> (first, last: Address, ok: bool) {
	outer: for part, p in doc.parts {
		for &b, slot in part_blocks(part) {
			for text, cell in block_texts(&b) {
				if len(text.bytes) > 0 {
					first, ok = {block = doc.starts[p] + slot, cell = cell}, true
					break outer
				}
			}
		}
	}
	if !ok {
		return
	}
	for p := len(doc.parts) - 1; p >= 0; p -= 1 {
		blocks := part_blocks(doc.parts[p])
		for slot := len(blocks) - 1; slot >= 0; slot -= 1 {
			texts := block_texts(&blocks[slot])
			for cell := len(texts) - 1; cell >= 0; cell -= 1 {
				if n := len(texts[cell].bytes); n > 0 {
					return first, {block = doc.starts[p] + slot, cell = cell, byte = n}, true
				}
			}
		}
	}
	return
}

// Appends the text between two addresses to `out` as UTF-8, `from` before
// `to`. Each text (a paragraph, a cell) starts a new line; the lines of a
// code block are in its text already. A text with nothing in the range
// gives no line at the two ends of the result, and an empty line between
// two texts that have something.
text_between :: proc(doc: ^Document, from, to: Address, out: ^[dynamic]u8) {
	if doc.count == 0 || from.block < 0 || from.block >= doc.count {
		return
	}
	// The line ends that are owed before the next bytes: one for each text
	// since the last bytes.
	owed := 0
	wrote := false
	first, slot := locate(doc, from.block)
	for part, p in doc.parts[first:] {
		for &b, n in part_blocks(part)[slot:] {
			block := doc.starts[first + p] + slot + n
			if block > to.block {
				return
			}
			for text, cell in block_texts(&b) {
				// The cells before the first one and after the last one.
				if (block == from.block && cell < from.cell) || (block == to.block && cell > to.cell) {
					continue
				}
				start := block == from.block && cell == from.cell ? clamp(from.byte, 0, len(text.bytes)) : 0
				end := block == to.block && cell == to.cell ? clamp(to.byte, 0, len(text.bytes)) : len(text.bytes)
				if start < end {
					if wrote {
						for _ in 0 ..< owed {
							append(out, '\n')
						}
					}
					append(out, ..text.bytes[start:end])
					wrote, owed = true, 0
				}
				owed += 1
			}
		}
		slot = 0
	}
}
