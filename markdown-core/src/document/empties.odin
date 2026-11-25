package document

import "core:bytes"

// Empty paragraphs. Markdown has no paragraph with no text: lines with
// nothing in them only end a block. For an editor, the line that Return
// makes after a paragraph is a paragraph all the same: the caret is in
// it, and the first character that is typed there starts its text. So a
// document says for each block how many such lines come after it
// (`Shape.empties`), and each is a place of the text of that block: an
// address with a byte after the end of the last text of the block, one
// byte for each line (`empty_address`, `empty_of`, `empty_offset`).
//
// Which lines: right after the lines of a block come empty lines b0, b1,
// b2, and so on, to the next line with something in it or to the end of
// the source (the end of a source that ends with a line break is such a
// line too). b0 ends the block. b1 is an empty paragraph: text typed
// there has an empty line before it, so it is a paragraph of its own.
// b2 ends that one, b3 is the next, and so on. The last empty line
// before a line with something in it is no paragraph: text typed there
// is the first line of what comes.
//
// Not after each block. A rule has no text, so it has no address for
// them. Text typed between two blocks of a list makes two lists of it,
// or takes a block out of its item, so a block has none when the block
// after it is in a list and does not start one (`in_list`). And the empty lines must come right after the
// lines of the block: ones after raw HTML or after a definition of a
// link are not counted, and ones in code with no end mark are code.

// The start of the line break that ends at an offset, or the offset.
@(private)
break_before :: proc(source: []u8, at: int) -> int {
	at := at
	if at > 0 && source[at - 1] == '\n' {
		at -= 1
		if at > 0 && source[at - 1] == '\r' {
			at -= 1
		}
	} else if at > 0 && source[at - 1] == '\r' {
		at -= 1
	}
	return at
}

// The line that starts at an offset: where its text ends, and where the
// next line starts (the same at the end of the source).
@(private)
line_at :: proc(source: []u8, at: int) -> (end, next: int) {
	end = at
	for end < len(source) && source[end] != '\n' && source[end] != '\r' {
		end += 1
	}
	next = end
	if next < len(source) {
		next += next + 1 < len(source) && source[next] == '\r' && source[next + 1] == '\n' ? 2 : 1
	}
	return
}

// True for a line with nothing but spaces in it.
@(private)
blank :: proc(line: []u8) -> bool {
	for ch in line {
		if ch != ' ' && ch != '\t' {
			return false
		}
	}
	return true
}

// Where the lines of a block end in a source: the start of the line
// after its last one (the end of the source for a last line with no
// line break). `next`: where the block after it starts, or the end of
// the source. False for a block whose end the lines do not show: code
// with no end mark.
@(private)
lines_end :: proc(source: []u8, b: ^Block, start, next: int) -> (end: int, ok: bool) {
	if b.kind != .Code {
		// No line of these blocks is empty.
		end = start
		for end < next {
			text_end, after := line_at(source, end)
			if blank(source[end:text_end]) {
				break
			}
			end = after
		}
		return end, true
	}
	// Code can have empty lines, so its end is found from the back: the
	// last line with something in it before `next` is the end mark of a
	// fence, or a line of code that is code by its indent.
	first_end, _ := line_at(source, start)
	fenced := fence_line(source[start:first_end])
	end = next
	for end > start {
		before := break_before(source, end)
		line := before
		for line > start && source[line - 1] != '\n' && source[line - 1] != '\r' {
			line -= 1
		}
		if !blank(source[line:before]) {
			// The end mark is not the line that starts the fence.
			return end, fenced ? line > start && fence_line(source[line:before]) : true
		}
		if line == end {
			break
		}
		end = line
	}
	return end, false
}

// True for a line that starts or ends a fence of code, after the marks
// of a quote or of a list item before it.
@(private)
fence_line :: proc(line: []u8) -> bool {
	text := bytes.trim_left(line, {' ', '\t', '>'})
	// The mark of a list item: a bullet, or a number.
	if len(text) > 1 && (text[0] == '-' || text[0] == '*' || text[0] == '+') && text[1] == ' ' {
		text = bytes.trim_left(text[1:], {' '})
	} else {
		digits := 0
		for digits < len(text) && text[digits] >= '0' && text[digits] <= '9' {
			digits += 1
		}
		if digits > 0 && digits < len(text) && (text[digits] == '.' || text[digits] == ')') {
			text = bytes.trim_left(text[digits + 1:], {' '})
		}
	}
	return bytes.has_prefix(text, {'`', '`', '`'}) || bytes.has_prefix(text, {'~', '~', '~'})
}

// The empty lines right after the lines of a block: where the first
// one starts (where the lines of the block end), how many there are,
// and if a line with something in it comes after them. `whole`: the
// source ends where `source` ends, so its end is a line when a line
// break is before it. No lines for a block that has no empty
// paragraphs; `first` is then where its lines end all the same, when
// the lines show it.
@(private)
empty_lines :: proc(source: []u8, b: ^Block, start, next: int, next_in_list, whole: bool) -> (first, count: int, followed: bool) {
	whole := whole
	found: bool
	first, found = lines_end(source, b, start, next)
	if !found {
		return next, 0, true
	}
	at := first
	for at < len(source) {
		text_end, after := line_at(source, at)
		if !blank(source[at:text_end]) {
			followed = true
			break
		}
		count += 1
		at = after
		if after == text_end {
			// Spaces at the end of the source, with no line break.
			whole = false
			break
		}
	}
	if !followed && whole && (at == 0 || source[at - 1] == '\n' || source[at - 1] == '\r') {
		count += 1
	}
	if b.kind == .Rule || next_in_list {
		count = 0
	}
	return
}

// True for a block that goes on a list: one in a list that is not the
// first block of a list of its own.
@(private)
in_list :: proc(b: ^Block) -> bool {
	return b.list_depth > 0 && b.spacing != .List_Start
}

// How many of some empty lines are empty paragraphs.
@(private)
empties_in :: proc(count: int, followed: bool) -> u16 {
	return u16(clamp((followed ? count - 1 : count) / 2, 0, int(max(u16))))
}

// Gives each block of a document that was parsed its number of empty
// paragraphs. The blocks have their offsets from the start of the
// source still. `end`: where the text of the last block ends, and
// `followed`: a block that is not in this document starts there, in a
// list or not.
@(private)
count_empties :: proc(doc: ^Document, end: int, followed, followed_in_list: bool) {
	before: ^Block
	for part in doc.parts {
		for &b in part_blocks(part) {
			if before != nil {
				_, count, _ := empty_lines(doc.source[:end], before, before.source, b.source, in_list(&b), false)
				before.empties = empties_in(count, true)
			}
			before = &b
		}
	}
	if before != nil {
		_, count, more := empty_lines(doc.source[:end], before, before.source, end, followed && followed_in_list, !followed)
		before.empties = empties_in(count, more || followed)
	}
}

// The empty lines after a block of a document (`empty_lines`).
@(private)
block_empty_lines :: proc(doc: ^Document, block: int) -> (first, count: int, followed: bool) {
	_, next := block_source(doc, block)
	inside := block + 1 < doc.count && in_list(block_at(doc, block + 1))
	return empty_lines(doc.source, block_at(doc, block), block_start(doc, block), next, inside, true)
}

// The offset of the source where an empty paragraph of a block starts:
// `n` from 1. The block has that many.
empty_offset :: proc(doc: ^Document, block, n: int) -> int {
	at, _, _ := block_empty_lines(doc, block)
	// Two lines on for each: the line that ends what is before it, and
	// the paragraph itself.
	for _ in 0 ..< 2 * n - 1 {
		_, at = line_at(doc.source, at)
	}
	return at
}

// The lines of the source that an empty paragraph of a block is: the
// line that ends what is before it, and its own line. With these out,
// the source has one empty paragraph less after the block.
empty_range :: proc(doc: ^Document, block, n: int) -> (start, end: int) {
	start, _, _ = block_empty_lines(doc, block)
	for _ in 0 ..< 2 * n - 2 {
		_, start = line_at(doc.source, start)
	}
	_, end = line_at(doc.source, start)
	_, end = line_at(doc.source, end)
	return
}

// The empty paragraph of a block that an offset of the source is in or
// after: its number from 1, or 0 for an offset before the first one.
empty_at :: proc(doc: ^Document, block, offset: int) -> int {
	empties := int(block_at(doc, block).empties)
	if empties == 0 {
		return 0
	}
	// Paragraph n starts 2n - 1 lines after the first empty line.
	first, _, _ := block_empty_lines(doc, block)
	return clamp((count_lines(doc.source, first, offset) + 1) / 2, 0, empties)
}

// The address of an empty paragraph of a block: after the end of its
// last text, one byte for each; with 0, the end of that text. False
// for a block with no text (a rule).
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
	b := block_at(doc, at.block)
	texts := block_texts(b)
	if at.cell != len(texts) - 1 || at.cell < 0 {
		return 0
	}
	return clamp(at.byte - len(texts[at.cell].bytes), 0, int(b.empties))
}
