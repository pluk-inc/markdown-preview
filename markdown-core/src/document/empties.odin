package document

// Empty paragraphs. Markdown has no paragraph with no text: lines with
// nothing in them only end a block. For an editor, the line that Return
// makes after a paragraph is a paragraph all the same: the caret is in
// it, and the first character that is typed there starts its text. So a
// document says for each block how many such lines come after it
// (`Shape.empties`), and each is a place of the text of that block: an
// address with a byte after the end of the last text of the block, one
// byte for each line (`empty_at`, `empty_offset`).
//
// Which lines: after the lines of a block come empty lines b0, b1, b2,
// and so on, to the start of the next block or to the end of the source
// (the end of a source that ends with a line break is such a line too).
// b0 ends the block. b1 is an empty paragraph: text typed there has an
// empty line before it, so it is a paragraph of its own. b2 ends that
// one, b3 is the next, and so on. The last empty line before a block is
// no paragraph: text typed there is the first line of that block.

// The empty lines that end at an offset of a source: where the first
// one starts, and how many there are. `followed`: a block starts at the
// offset; with none there, the offset is the end of the source.
@(private)
empty_lines :: proc(source: []u8, end: int, followed: bool) -> (first, count: int) {
	// The start of the line that ends at an offset (with its line
	// break), when that line has nothing but spaces in it; else -1.
	empty_before :: proc(source: []u8, at: int) -> int {
		i := at
		if i > 0 && source[i - 1] == '\n' {
			i -= 1
		}
		if i > 0 && source[i - 1] == '\r' {
			i -= 1
		}
		if i == at {
			return -1
		}
		for i > 0 && (source[i - 1] == ' ' || source[i - 1] == '\t') {
			i -= 1
		}
		return i == 0 || source[i - 1] == '\n' || source[i - 1] == '\r' ? i : -1
	}
	first = clamp(end, 0, len(source))
	if !followed {
		// The line that the source ends in, when it has no text: after
		// a line break, or spaces only.
		for first > 0 && (source[first - 1] == ' ' || source[first - 1] == '\t') {
			first -= 1
		}
		if first > 0 && source[first - 1] != '\n' && source[first - 1] != '\r' {
			return end, 0
		}
		count = 1
	}
	for {
		before := empty_before(source, first)
		if before < 0 {
			break
		}
		first, count = before, count + 1
	}
	// Lines at the start of the source end no block.
	if first == 0 {
		count = 0
	}
	return
}

// How many of some empty lines are empty paragraphs.
@(private)
empties_in :: proc(count: int, followed: bool) -> u16 {
	return u16(min((followed ? count - 1 : count) / 2, int(max(u16))))
}

// Gives each block of a document that was parsed its number of empty
// paragraphs. The blocks have their offsets from the start of the
// source still. `end`: where the text of the last block ends, and
// `followed`: a block that is not in this document starts there.
@(private)
count_empties :: proc(doc: ^Document, end: int, followed: bool) {
	before: ^Block
	for part in doc.parts {
		for &b in part_blocks(part) {
			if before != nil {
				_, count := empty_lines(doc.source, b.source, true)
				before.empties = empties_in(count, true)
			}
			before = &b
		}
	}
	// The empty lines at the end of code with no end mark are its text.
	if before != nil && !(before.kind == .Code && !followed) {
		_, count := empty_lines(doc.source, end, followed)
		before.empties = empties_in(count, followed)
	}
}

// The offset of the source where an empty paragraph of a block starts:
// `n` from 1. The block has that many.
empty_offset :: proc(doc: ^Document, block, n: int) -> int {
	_, end := block_source(doc, block)
	at, _ := empty_lines(doc.source, end, block + 1 < doc.count)
	// Two lines on for each: the line that ends what is before it, and
	// the paragraph itself.
	for _ in 0 ..< 2 * n - 1 {
		for at < len(doc.source) && doc.source[at] != '\n' && doc.source[at] != '\r' {
			at += 1
		}
		if at + 1 < len(doc.source) && doc.source[at] == '\r' && doc.source[at + 1] == '\n' {
			at += 1
		}
		at = min(at + 1, len(doc.source))
	}
	return at
}

// The lines of the source that an empty paragraph of a block is: the
// line that ends what is before it, and its own line. With these out,
// the source has one empty paragraph less after the block.
empty_range :: proc(doc: ^Document, block, n: int) -> (start, end: int) {
	source := doc.source
	at := empty_offset(doc, block, n)
	// The start of the line before it.
	start = at
	if start > 0 && source[start - 1] == '\n' {
		start -= 1
	}
	if start > 0 && source[start - 1] == '\r' {
		start -= 1
	}
	for start > 0 && source[start - 1] != '\n' && source[start - 1] != '\r' {
		start -= 1
	}
	// The start of the line after it, or the end of the source.
	end = at
	for end < len(source) && source[end] != '\n' && source[end] != '\r' {
		end += 1
	}
	if end + 1 < len(source) && source[end] == '\r' && source[end + 1] == '\n' {
		end += 1
	}
	end = min(end + 1, len(source))
	return
}

// The empty paragraph of a block that an offset of the source is in or
// after: its number from 1, or 0 for an offset before the first one.
empty_at :: proc(doc: ^Document, block, offset: int) -> (n: int) {
	for n < int(block_at(doc, block).empties) && empty_offset(doc, block, n + 1) <= offset {
		n += 1
	}
	return
}

// The address of an empty paragraph of a block: after the end of its
// last text, one byte for each. False for a block with no text (a
// rule).
empty_address :: proc(doc: ^Document, block, n: int) -> (at: Address, ok: bool) {
	texts := block_texts(block_at(doc, block))
	if len(texts) == 0 {
		return
	}
	return {block, len(texts) - 1, len(texts[len(texts) - 1].bytes) + n}, true
}

// Which empty paragraph of its block an address is: its number from 1,
// or 0 for an address in the text.
empty_of :: proc(doc: ^Document, at: Address) -> int {
	texts := block_texts(block_at(doc, at.block))
	if at.cell != len(texts) - 1 || at.cell < 0 {
		return 0
	}
	return clamp(at.byte - len(texts[at.cell].bytes), 0, int(block_at(doc, at.block).empties))
}
