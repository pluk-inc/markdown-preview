package document

import "core:bytes"

// Empty paragraphs. Markdown has no paragraph with no text: lines with
// nothing in them only end a block. For an editor, the line that Return
// makes after a paragraph is a paragraph all the same: the caret is in
// it, and the first character that is typed there starts its text. So a
// document says for each block how many such lines come after it
// (`Shape.empties`), and each is a place of the text of that block: an
// address at the end of the last text of the block, with the number of
// the line in a field of its own (`Address.empty`; `empty_address`,
// `empty_of`, `empty_offset`).
//
// Which lines: each line with nothing in it right after the lines of a
// block, but the last one (the end of a source that ends with a line
// break is such a line too). That is what an editor of the lines of
// the source shows: one line for each, and the last one is the one
// that ends the text before the next block. Text that is typed in such
// a line must be a paragraph of its own, at that place: it goes in
// with a line break before it (`empty_text`), so it has an empty line
// before it, and the lines after it are as they were.
//
// Not after each block. A rule has no text, so it has no address for
// them. Text typed between two blocks of a list makes two lists of it,
// or takes a block out of its item, so a block has none when the block
// after it is in a list and does not start one (`in_list`). And the
// empty lines must come right after the lines of the block, as the
// parser says where they end (`Block.lines`): ones after raw HTML or
// after a definition of a link are not counted, and ones in code with
// no end mark are lines of the code.

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

// The start of the line that an offset is in.
@(private)
line_start :: proc(source: []u8, at: int) -> int {
	at := at
	for at > 0 && source[at - 1] != '\n' && source[at - 1] != '\r' {
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

// The empty lines right after the lines of a block: where the first
// one starts (where the lines of the block end), and how many there
// are. `whole`: the source ends where `source` ends, so its end is a
// line when a line break is before it. No lines for a block that has
// no empty paragraphs; `first` is then where its lines end all the
// same.
@(private)
empty_lines :: proc(source: []u8, b: ^Block, start, next: int, next_in_list, whole: bool) -> (first, count: int) {
	whole := whole
	followed: bool
	first = min(start + int(b.lines), next)
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

// How many of some empty lines are empty paragraphs: each but the last.
@(private)
empties_in :: proc(count: int) -> u16 {
	return u16(clamp(count - 1, 0, int(max(u16))))
}

// Gives each block of a document that was parsed its number of empty
// paragraphs. The blocks have their offsets from the start of the
// source still. `end`: where the text of the last block ends;
// `followed`: a block that is not in this document starts there; and
// `followed_in_list`: that block goes on a list (`in_list`).
@(private)
count_empties :: proc(doc: ^Document, end: int, followed, followed_in_list: bool) {
	before: ^Block
	for part in doc.parts {
		for &b in part_blocks(part) {
			if before != nil {
				lines, count := empty_lines(doc.source[:end], before, before.source, b.source, in_list(&b), false)
				before.empties = empties_in(count)
				before.end_spaces = end_spaces_of(doc.source[:end], before, before.source, lines)
			}
			before = &b
		}
	}
	if before != nil {
		lines, count := empty_lines(doc.source[:end], before, before.source, end, followed_in_list, !followed)
		before.empties = empties_in(count)
		before.end_spaces = end_spaces_of(doc.source[:end], before, before.source, lines)
	}
}

// How many spaces and tabs the line where the text of a paragraph or a
// heading ends has at its end (`Block.end_spaces`), with `lines` where
// the lines of the block end (`Block.lines`) and `first` where they
// start. That is the last line of the block that has text after its
// marks: not a line of a quote with only its ">" in it, and not the
// line under a heading that the line makes ("---"). None for a text
// with nothing in it (an item of a list with no text yet).
@(private)
end_spaces_of :: proc(source: []u8, b: ^Block, first, lines: int) -> u16 {
	if (b.kind != .Paragraph && b.kind != .Heading) || len(b.text.bytes) == 0 {
		return 0
	}
	end := break_before(source, lines)
	for {
		start := line_start(source, end)
		count := 0
		for end - count > start && (source[end - count - 1] == ' ' || source[end - count - 1] == '\t') {
			count += 1
		}
		text := bytes.trim_left(source[start:end - count], {' ', '\t', '>'})
		under := b.kind == .Heading && len(text) > 0 && len(bytes.trim(text, {'=', '-'})) == 0
		if (len(text) == 0 || under) && start > first {
			// No text of the block on this line: it ends on a line
			// before it.
			end = break_before(source, start)
			continue
		}
		return len(text) == 0 ? 0 : u16(min(count, int(max(u16))))
	}
}

// The empty lines after a block of a document (`empty_lines`).
@(private)
block_empty_lines :: proc(doc: ^Document, block: int) -> (first, count: int) {
	_, next := block_source(doc, block)
	inside := block + 1 < doc.count && in_list(block_at(doc, block + 1))
	return empty_lines(doc.source, block_at(doc, block), block_start(doc, block), next, inside, true)
}

// The offset of the source where an empty paragraph of a block starts:
// `n` from 1. The block has that many.
empty_offset :: proc(doc: ^Document, block, n: int) -> int {
	at, _ := block_empty_lines(doc, block)
	for _ in 1 ..< n {
		_, at = line_at(doc.source, at)
	}
	return at
}

// The line of the source that an empty paragraph of a block is, with
// its line break. With it out, the source has one empty paragraph less
// after the block.
empty_range :: proc(doc: ^Document, block, n: int) -> (start, end: int) {
	start = empty_offset(doc, block, n)
	_, end = line_at(doc.source, start)
	return
}

// The empty paragraph of a block that an offset of the source is in or
// after: its number from 1, or 0 for an offset before the first one.
empty_at :: proc(doc: ^Document, block, offset: int) -> int {
	empties := int(block_at(doc, block).empties)
	if empties == 0 {
		return 0
	}
	first, _ := block_empty_lines(doc, block)
	if offset < first {
		return 0
	}
	return min(count_lines(doc.source, first, offset) + 1, empties)
}

// Text that is typed in an empty paragraph, as it goes into the source:
// with a line break before it. The text then has an empty line before
// it, so it is a paragraph of its own, and it is at the place of the
// line that it was typed in: the line before it shows no more (it ends
// the text before the new paragraph), and the lines after it are as
// they were. Memory of `allocator`, the caller's to delete.
empty_text :: proc(doc: ^Document, text: string, allocator := context.allocator) -> string {
	nl := line_ending(doc.source)
	out := make([]u8, len(nl) + len(text), allocator)
	copy(out, nl)
	copy(out[len(nl):], text)
	return string(out)
}

// The address of an empty paragraph of a block (`Address.empty`); with
// 0, the end of its last text. False for a block with no text (a rule).
empty_address :: proc(doc: ^Document, block, n: int) -> (at: Address, ok: bool) {
	texts := block_texts(block_at(doc, block))
	if len(texts) == 0 {
		return
	}
	return {block = block, cell = len(texts) - 1, byte = len(texts[len(texts) - 1].bytes), empty = n}, true
}

// Which empty paragraph of its block an address is: its number from 1,
// or 0 for an address in the text. Not more than the block has.
empty_of :: proc(doc: ^Document, at: Address) -> int {
	return clamp(at.empty, 0, int(block_at(doc, at.block).empties))
}

// How many of the spaces at the end of the text of its block are
// before an address (`Address.spaces`). Not more than the block has.
spaces_of :: proc(doc: ^Document, at: Address) -> int {
	b := block_at(doc, at.block)
	texts := block_texts(b)
	if at.empty > 0 || at.spaces <= 0 || at.cell != len(texts) - 1 || at.byte != len(texts[at.cell].bytes) {
		return 0
	}
	return min(at.spaces, int(b.end_spaces))
}
