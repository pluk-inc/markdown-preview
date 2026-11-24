package document

// A place in the text of a document: a block by its number, the cell for
// a table (0 in each other block), and a byte in the text of the block or
// of the cell. It needs no layout, so it says the same in each layout of
// the document. A caret, the ends of a selection, and the place of a view
// are such addresses.
Address :: struct {
	block, cell, byte: int,
}

// True when `a` comes before `b` in reading order.
before :: proc(a, b: Address) -> bool {
	if a.block != b.block {
		return a.block < b.block
	}
	return a.cell < b.cell || (a.cell == b.cell && a.byte < b.byte)
}

// The cell of a table that a text is, or 0 for the text of another block.
cell_of :: proc(b: ^Block, text: ^Text) -> int {
	if b.kind != .Table {
		return 0
	}
	return int(uintptr(text) - uintptr(raw_data(b.cells))) / size_of(Text)
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

// The start of the first text of the document that is not empty, and the
// end of the last one: the two ends of all of its text. False for a
// document with no text.
text_ends :: proc(doc: ^Document) -> (first, last: Address, ok: bool) {
	outer: for part, p in doc.parts {
		for &b, slot in part_blocks(part) {
			for text, cell in block_texts(&b) {
				if len(text.bytes) > 0 {
					first, ok = {doc.starts[p] + slot, cell, 0}, true
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
					return first, {doc.starts[p] + slot, cell, n}, true
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
	p, slot := locate(doc, from.block)
	for block := from.block; block <= to.block && p < len(doc.parts); block += 1 {
		for text, cell in block_texts(&doc.parts[p].blocks[slot]) {
			at := Address{block, cell, 0}
			if before(at, Address{from.block, from.cell, 0}) || before(Address{to.block, to.cell, 0}, at) {
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
		slot += 1
		if slot >= doc.parts[p].count {
			p, slot = p + 1, 0
		}
	}
}
