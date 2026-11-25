package document

import "core:strings"

// What Return and a delete do where the answer is of the block of the
// caret, and not of the byte that the caret is at.

// The line break of a source: the kind of its first one.
@(private)
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
// - In an empty paragraph, one more after it.
// - In code, a line break at the caret: a new line of the code, with
//   the indent of code that is code by its indent.
// - At the end of the text of a list item, a new item of the same kind
//   after it and after the lists in it (a number one higher, a task
//   that is not done).
// - In a list item with no text, the item goes and an empty paragraph
//   is there: Return two times ends a list. Between two items, the
//   item only goes.
// - At the end of each other text, an empty paragraph after the lines
//   of the block: after the line under a heading, and after the marks
//   that end bold text, which are after the caret in the source.
// - In the text, the text after the caret is a paragraph of its own:
//   two line breaks for the spaces and the line break at the caret.
//
// The text takes the place of the source from `start` to `end`. False
// where Return does nothing yet: in a table, and at the end of a text
// whose next block is in a list (text between two blocks of a list
// makes two lists of it). `text` is in the temporary memory of the
// context.
line_break :: proc(doc: ^Document, places: []Place, at: Address) -> (start, end: int, text: string, caret: int, ok: bool) {
	b := block_at(doc, at.block)
	source := doc.source
	nl := line_ending(source)
	offset := place_of(doc, places, at) or_return
	two := strings.concatenate({nl, nl}, context.temp_allocator)
	if empty_of(doc, at) > 0 {
		return offset, offset, two, offset + len(two), true
	}
	texts := block_texts(b)
	if b.kind == .Table || at.cell >= len(texts) {
		return
	}
	block_begin := block_start(doc, at.block)
	at_end := at.byte >= len(texts[at.cell].bytes)
	if b.kind == .Code {
		first_end, _ := line_at(source, block_begin)
		if fence_line(source[block_begin:first_end]) {
			return offset, offset, nl, offset + len(nl), true
		}
		// Code by its indent: the new line has the indent. At its end,
		// a line with only the indent is no code, so Return there is
		// as at the end of each other text.
		if !at_end {
			indent := block_begin
			for indent < first_end && (source[indent] == ' ' || source[indent] == '\t') {
				indent += 1
			}
			text = strings.concatenate({nl, string(source[block_begin:indent])}, context.temp_allocator)
			return offset, offset, text, offset + len(text), true
		}
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
		return start, end, two, start + len(two), true
	}
	// At the end of the text: after the lines of the block.
	after, empty, followed := block_empty_lines(doc, at.block)
	// The empty paragraph is the second line after the block. With a
	// line with something in it right after, it needs a line that ends
	// it too.
	breaks := empty == 0 && followed ? strings.concatenate({nl, nl, nl}, context.temp_allocator) : two
	if is_item(doc, at.block) {
		if len(texts[at.cell].bytes) == 0 {
			// No text: the line of the item becomes an empty paragraph.
			// Between two items it only goes: a paragraph there makes
			// two lists of the list.
			start, end = empty_item(doc, at.block) or_return
			if at.block + 1 < doc.count && in_list(block_at(doc, at.block + 1)) {
				return start, end, "", start, true
			}
			return start, end, breaks, start + len(two), true
		}
		if mark, has := item_mark(doc, at.block); has {
			// After the lists that are in the item.
			last := at.block
			for last + 1 < doc.count && block_at(doc, last + 1).list_depth > b.list_depth {
				last += 1
			}
			below, _, _ := block_empty_lines(doc, last)
			below = break_before(source, below)
			text = strings.concatenate({nl, mark}, context.temp_allocator)
			return below, below, text, below + len(text), true
		}
	}
	if at.block + 1 < doc.count && in_list(block_at(doc, at.block + 1)) {
		return
	}
	after = break_before(source, after)
	return after, after, breaks, after + len(two), true
}

// What a delete takes out for a caret at an address that is not after a
// character: an empty paragraph, or a list item with no text. The caret
// is then at `caret`, the end of what is before it. False at each other
// address.
delete_back :: proc(doc: ^Document, places: []Place, at: Address) -> (start, end, caret: int, ok: bool) {
	if n := empty_of(doc, at); n > 0 {
		start, end = empty_range(doc, at.block, n)
		before := at
		before.byte -= 1
		caret = place_of(doc, places, before) or_return
		return start, end, caret, caret <= start
	}
	start, end = empty_item(doc, at.block) or_return
	return start, end, start, true
}

// True for a block that is the first and only block of a list item
// that is in no quote. The item can have lists in it.
@(private)
is_item :: proc(doc: ^Document, block: int) -> bool {
	b := block_at(doc, block)
	if b.marker == .None || (b.spacing != .Item && b.spacing != .List_Start) || b.quote_depth > 0 {
		return false
	}
	return block + 1 >= doc.count || block_at(doc, block + 1).item != b.item
}

// The lines of a list item with no text and nothing in it, with the
// line break before them: with these out of the source, the item is
// gone and the text before it ends as it did. False for each other
// block, and for the first block of the source.
@(private)
empty_item :: proc(doc: ^Document, block: int) -> (start, end: int, ok: bool) {
	b := block_at(doc, block)
	if !is_item(doc, block) || len(b.text.bytes) > 0 || block == 0 {
		return
	}
	if block + 1 < doc.count && block_at(doc, block + 1).list_depth > b.list_depth {
		return
	}
	start = break_before(doc.source, block_start(doc, block))
	end, _, _ = block_empty_lines(doc, block)
	end = break_before(doc.source, end)
	return start, end, end > start
}

// The mark of a new list item after the item of a block (`is_item`):
// its indent, its bullet or the next number, and the box of a task
// that is not done. False when the source has no such mark there, and
// for a number that a list item cannot have.
@(private)
item_mark :: proc(doc: ^Document, block: int) -> (mark: string, ok: bool) {
	source := doc.source
	at := block_start(doc, block)
	start := at
	for at < len(source) && (source[at] == ' ' || source[at] == '\t') {
		at += 1
	}
	out := strings.builder_make(context.temp_allocator)
	strings.write_bytes(&out, source[start:at])
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
			return
		}
		strings.write_int(&out, number + 1)
		strings.write_byte(&out, source[digits])
	case at < len(source) && (source[at] == '-' || source[at] == '*' || source[at] == '+'):
		strings.write_byte(&out, source[at])
	case:
		return
	}
	strings.write_byte(&out, ' ')
	b := block_at(doc, block)
	if b.marker == .Task_Open || b.marker == .Task_Done {
		strings.write_string(&out, "[ ] ")
	}
	return strings.to_string(out), true
}
