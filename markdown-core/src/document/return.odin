package document

import "core:strings"

// What Return puts into the source for a caret at an address of the
// text of a block, where it goes, and where the caret is after it. The
// answer is of the block, not of the byte of the caret:
//
// - In code, a line break at the caret: a new line of the code.
// - At the end of the text of a list item, a new item of the same kind
//   after it (a number one higher, a task that is not done).
// - At the end of each other text, an empty paragraph after the lines
//   of the block: after the line under a heading, and after the marks
//   that end bold text, which are after the caret in the source.
// - In the text, two line breaks at the caret: the text after it is a
//   paragraph of its own.
// - In an empty paragraph, one more after it.
//
// False where Return does nothing yet (a table). `text` is in the
// temporary memory of the context.
line_break :: proc(doc: ^Document, places: []Place, at: Address) -> (offset: int, text: string, caret: int, ok: bool) {
	b := block_at(doc, at.block)
	if b.kind == .Table {
		return
	}
	offset = place_of(doc, places, at) or_return
	texts := block_texts(b)
	if b.kind == .Code {
		return offset, "\n", offset + 1, true
	}
	if empty_of(doc, at) > 0 || at.cell >= len(texts) || at.byte < len(texts[at.cell].bytes) {
		return offset, "\n\n", offset + 2, true
	}
	// At the end of the text: after the lines of the block.
	end, empty := content_end(doc, at.block)
	if mark, is_item := item_mark(doc, at.block); is_item && len(texts[at.cell].bytes) > 0 {
		text = strings.concatenate({"\n", mark}, context.temp_allocator)
		return end, text, end + len(text), true
	}
	// The empty paragraph is the second line after the block. With a
	// block right after, it needs a line that ends it too.
	text = empty == 0 && at.block + 1 < doc.count ? "\n\n\n" : "\n\n"
	return end, text, end + 2, true
}

// Where the lines of a block end in the source, before the line break
// of its last line, and how many empty lines come after them.
@(private)
content_end :: proc(doc: ^Document, block: int) -> (end, empty: int) {
	_, next := block_source(doc, block)
	end, empty = empty_lines(doc.source, next, block + 1 < doc.count)
	if end > 0 && doc.source[end - 1] == '\n' {
		end -= 1
	}
	if end > 0 && doc.source[end - 1] == '\r' {
		end -= 1
	}
	return
}

// The mark of a new list item after the item that a block is the first
// and only block of: its indent, its bullet or the next number, and
// the box of a task that is not done. False for each other block, and
// for an item in a quote.
@(private)
item_mark :: proc(doc: ^Document, block: int) -> (mark: string, ok: bool) {
	b := block_at(doc, block)
	if b.marker == .None || (b.spacing != .Item && b.spacing != .List_Start) || b.quote_depth > 0 {
		return
	}
	// Not when the item goes on in the block after this one.
	if block + 1 < doc.count && block_at(doc, block + 1).item == b.item {
		return
	}
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
		strings.write_int(&out, number + 1)
		strings.write_byte(&out, source[digits])
	case at < len(source) && (source[at] == '-' || source[at] == '*' || source[at] == '+'):
		strings.write_byte(&out, source[at])
	case:
		return
	}
	strings.write_byte(&out, ' ')
	if b.marker == .Task_Open || b.marker == .Task_Done {
		strings.write_string(&out, "[ ] ")
	}
	return strings.to_string(out), true
}
