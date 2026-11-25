package document

import "core:strings"

// What Return and a delete do where the answer is of the block of the
// caret, and not of the byte that the caret is at.

// The line break of a source: the kind of its first one.
line_ending :: proc(source: []u8) -> string {
	for ch, i in source {
		switch ch {
		case '\n':
			return "\n"
		case '\r':
			return i + 1 < len(source) && source[i + 1] == '\n' ? "\r\n" : "\r"
		}
	}
	return "\n"
}

// What Return puts into the source for a caret at an address of the
// text of a block, where, and where the caret is after it:
//
// - In an empty paragraph, one more: a line break at the caret.
// - In code, a line break at the caret with what the line of the caret
//   starts with (its indent, the marks of a quote): a new line of the
//   code, in a list item and in a quote too.
// - At the end of the text of a list item, a new item of the same kind
//   after it and after the lists in it (a number one higher, a task
//   that is not done).
// - In a list item with no text, the item goes and an empty paragraph
//   is there: Return two times ends a list. Between two items, and for
//   the first block of the source, the item only goes.
// - At the end of each other text, an empty paragraph after the lines
//   of the block: after the line under a heading, and after the marks
//   that end bold text, which are after the caret in the source.
// - In the text, the text after the caret is a paragraph of its own:
//   two line breaks for the spaces and the line break at the caret.
//
// The text takes the place of the source from `start` to `end`. False
// where Return does nothing yet: in a table, and at the end of a text
// whose next block is in a list (text between two blocks of a list
// makes two lists of it). `text` is memory of `allocator`, the
// caller's to delete, also when it is empty.
line_break :: proc(doc: ^Document, places: []Place, at: Address, allocator := context.allocator) -> (start, end: int, text: string, caret: int, ok: bool) {
	b := block_at(doc, at.block)
	source := doc.source
	nl := line_ending(source)
	offset := place_of(doc, places, at) or_return
	out := strings.builder_make(allocator)
	defer if !ok {
		strings.builder_destroy(&out)
	}
	// The text so far is what goes in.
	done :: proc(out: ^strings.Builder, start, end, caret: int) -> (int, int, string, int, bool) {
		return start, end, strings.to_string(out^), caret, true
	}
	if empty_of(doc, at) > 0 {
		strings.write_string(&out, nl)
		return done(&out, offset, offset, offset + len(nl))
	}
	texts := block_texts(b)
	if b.kind == .Table || at.cell >= len(texts) {
		return
	}
	block_begin := block_start(doc, at.block)
	at_end := at.byte >= len(texts[at.cell].bytes)
	first_end, _ := line_at(source, block_begin)
	// Code by its indent ends at its last line: a line with only the
	// indent is no code, so Return there is as at the end of each other
	// text.
	if b.kind == .Code && (fence_line(source[block_begin:first_end]) || !at_end) {
		line := offset
		for line > block_begin && source[line - 1] != '\n' && source[line - 1] != '\r' {
			line -= 1
		}
		// The indent, and as many marks of a quote as the block is in
		// quotes: a ">" after those is a character of the code.
		lead, quotes := line, 0
		for lead < offset && (source[lead] == ' ' || source[lead] == '\t' || (source[lead] == '>' && quotes < b.quote_depth)) {
			quotes += int(source[lead] == '>')
			lead += 1
		}
		strings.write_string(&out, nl)
		strings.write_bytes(&out, source[line:lead])
		return done(&out, offset, offset, offset + len(nl) + lead - line)
	}
	if !at_end {
		// In the text: the spaces around the caret and one line break
		// after it go, so the two halves have one empty line between.
		start, end = offset, offset
		for start > block_begin && (source[start - 1] == ' ' || source[start - 1] == '\t') {
			start -= 1
		}
		for end < len(source) && (source[end] == ' ' || source[end] == '\t') {
			end += 1
		}
		if end < len(source) && (source[end] == '\n' || source[end] == '\r') {
			_, end = line_at(source, end)
		} else {
			end = max(end, offset)
		}
		strings.write_string(&out, nl)
		strings.write_string(&out, nl)
		return done(&out, start, end, start + 2 * len(nl))
	}
	// At the end of the text: after the lines of the block. The empty
	// paragraph is the first line after them, and the line after it
	// ends it: a block with no empty line after it needs the two.
	after, empty, _ := block_empty_lines(doc, at.block)
	breaks := empty == 0 ? 2 : 1
	in_list_next := at.block + 1 < doc.count && in_list(block_at(doc, at.block + 1))
	if is_item(doc, at.block) {
		if len(texts[at.cell].bytes) == 0 {
			// No text: the line of the item becomes an empty paragraph.
			// Between two items it only goes (a paragraph there makes
			// two lists of the list), and so does the first block of
			// the source, which has no text before it to end.
			start, end = empty_item(doc, at.block) or_return
			if in_list_next || at.block == 0 {
				return done(&out, start, end, start)
			}
			for _ in 0 ..< breaks {
				strings.write_string(&out, nl)
			}
			return done(&out, start, end, start + len(nl))
		}
		strings.write_string(&out, nl)
		if item_mark(doc, at.block, &out) {
			// After the lists that are in the item.
			last := at.block
			for last + 1 < doc.count && block_at(doc, last + 1).list_depth > b.list_depth {
				last += 1
			}
			below, _, _ := block_empty_lines(doc, last)
			below = break_before(source, below)
			return done(&out, below, below, below + strings.builder_len(out))
		}
		strings.builder_reset(&out)
	}
	if in_list_next {
		return
	}
	after = break_before(source, after)
	for _ in 0 ..< breaks {
		strings.write_string(&out, nl)
	}
	return done(&out, after, after, after + len(nl))
}

// What a delete takes out for a caret at an address where it is more
// than the character before the caret, or another thing: an empty
// paragraph, a list item with no text, or the only character of a
// paragraph. The caret is then at `caret`. False at each other address.
delete_back :: proc(doc: ^Document, places: []Place, at: Address) -> (start, end, caret: int, ok: bool) {
	if n := empty_of(doc, at); n > 0 {
		start, end = empty_range(doc, at.block, n)
		before := at
		before.byte -= 1
		caret = place_of(doc, places, before) or_return
		return start, end, caret, caret <= start
	}
	if start, end, ok = empty_item(doc, at.block); ok {
		return start, end, start, true
	}
	// The only character of a paragraph: its line stays, as an empty
	// line. The paragraph had an empty line before it, which showed as
	// no line; with the character out, that one shows, so one of the
	// two goes with the character.
	b := block_at(doc, at.block)
	if at.block == 0 || b.kind != .Paragraph || b.list_depth > 0 || b.quote_depth > 0 || at.byte != len(b.text.bytes) {
		return
	}
	from, to := char_before(doc, places, at) or_return
	line := block_start(doc, at.block)
	line_end, _ := line_at(doc.source, line)
	before := break_before(doc.source, line)
	above := before
	for above > 0 && doc.source[above - 1] != '\n' && doc.source[above - 1] != '\r' {
		above -= 1
	}
	if from != line || to != line_end || before == line || !blank(doc.source[above:before]) || block_at(doc, at.block - 1).kind == .Rule {
		return
	}
	return above, to, above, true
}

// True for a block that is the first and only block of a list item
// that is in no quote. The item can have lists in it, and no block of
// its own after them.
@(private)
is_item :: proc(doc: ^Document, block: int) -> bool {
	b := block_at(doc, block)
	if b.marker == .None || (b.spacing != .Item && b.spacing != .List_Start) || b.quote_depth > 0 {
		return false
	}
	// The first block after the lists that are in the item.
	after := block + 1
	for after < doc.count && block_at(doc, after).list_depth > b.list_depth {
		after += 1
	}
	return (block + 1 >= doc.count || block_at(doc, block + 1).item != b.item) && (after >= doc.count || block_at(doc, after).item != b.item)
}

// The lines of a list item with no text and nothing in it, with the
// line break before them: with these out of the source, the item is
// gone and the text before it ends as it did. For the first block of
// the source, its line with the line break after it. False for each
// other block.
@(private)
empty_item :: proc(doc: ^Document, block: int) -> (start, end: int, ok: bool) {
	b := block_at(doc, block)
	if !is_item(doc, block) || len(b.text.bytes) > 0 {
		return
	}
	if block + 1 < doc.count && block_at(doc, block + 1).list_depth > b.list_depth {
		return
	}
	end, _, _ = block_empty_lines(doc, block)
	if block == 0 {
		return block_start(doc, 0), end, end > block_start(doc, 0)
	}
	start = break_before(doc.source, block_start(doc, block))
	end = break_before(doc.source, end)
	return start, end, end > start
}

// Writes the mark of a new list item after the item of a block
// (`is_item`): its indent, its bullet or the next number, and the box
// of a task that is not done. False, with nothing sure about what is
// written, when the source has no such mark there, and for a number
// that a list item cannot have.
@(private)
item_mark :: proc(doc: ^Document, block: int, out: ^strings.Builder) -> bool {
	source := doc.source
	at := block_start(doc, block)
	start := at
	for at < len(source) && (source[at] == ' ' || source[at] == '\t') {
		at += 1
	}
	strings.write_bytes(out, source[start:at])
	digits := at
	for digits < len(source) && source[digits] >= '0' && source[digits] <= '9' {
		digits += 1
	}
	switch {
	case digits > at && digits - at <= 9 && digits < len(source) && (source[digits] == '.' || source[digits] == ')'):
		number := 0
		for ch in source[at:digits] {
			number = number * 10 + int(ch - '0')
		}
		// A number of a list item has nine digits at most.
		if number + 1 > 999_999_999 {
			return false
		}
		strings.write_int(out, number + 1)
		strings.write_byte(out, source[digits])
	case at < len(source) && (source[at] == '-' || source[at] == '*' || source[at] == '+'):
		strings.write_byte(out, source[at])
	case:
		return false
	}
	strings.write_byte(out, ' ')
	b := block_at(doc, block)
	if b.marker == .Task_Open || b.marker == .Task_Done {
		strings.write_string(out, "[ ] ")
	}
	return true
}
