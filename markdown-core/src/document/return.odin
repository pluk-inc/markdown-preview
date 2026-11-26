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
	// Code by its indent ends at its last line: a line with only the
	// indent is no code, so Return there is as at the end of each other
	// text.
	if b.kind == .Code && (b.fenced || !at_end) {
		line := max(line_start(source, offset), block_begin)
		// The indent, and as many marks of a quote as the block is in
		// quotes: a ">" after those is a character of the code.
		lead, quotes := line, 0
		for lead < offset && (source[lead] == ' ' || source[lead] == '\t' || (source[lead] == '>' && quotes < b.quote_depth)) {
			quotes += int(source[lead] == '>')
			lead += 1
		}
		strings.write_string(&out, nl)
		strings.write_bytes(&out, source[line:lead])
		caret = offset + len(nl) + lead - line
		// With no line of code yet, the line after the caret is the one
		// of the closing fence: the new line gets a line break of its own.
		if code_needs_line(doc, at, offset) {
			strings.write_string(&out, nl)
		}
		return done(&out, offset, offset, caret)
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
		// A backslash before the line break is a part of that break.
		if end + 1 < len(source) && source[end] == '\\' && (source[end + 1] == '\n' || source[end + 1] == '\r') {
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
	after, empty := block_empty_lines(doc, at.block)
	breaks := empty == 0 ? 2 : 1
	in_list_next := at.block + 1 < doc.count && in_list(block_at(doc, at.block + 1))
	// A mark with nothing after it that is being typed (`typed_mark`): no
	// list yet, so no new item; Return is as at the end of a paragraph.
	if is_item(doc, at.block) && !b.typed {
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
			below, _ := block_empty_lines(doc, last)
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
// paragraph, or a list item with no text. The caret is then at `caret`.
// False at each other address. (The last text of a paragraph that goes:
// `replace_range`.)
delete_back :: proc(doc: ^Document, places: []Place, at: Address) -> (start, end, caret: int, ok: bool) {
	if n := empty_of(doc, at); n > 0 {
		start, end = empty_range(doc, at.block, n)
		// The empty paragraph before it, or the end of the text.
		before := at
		before.empty -= 1
		if before.empty == 0 {
			before = with_end_spaces(doc, before)
		}
		caret = place_of(doc, places, before) or_return
		return start, end, caret, caret <= start
	}
	if start, end, ok = empty_item(doc, at.block); ok {
		return start, end, start, true
	}
	return
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
	end, _ = block_empty_lines(doc, block)
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

// For a list item that joins the list before it across empty lines (a
// list that the reader starts after leaving the one above with Return,
// which leaves two empty lines): where its mark is in the source, and
// the mark that makes a list of its own there ("*" for "-", "-" for "*"
// and "+", ")" for "." of a number, "." for ")"). In Markdown empty lines
// do not end a list, but another mark does. One empty line keeps the
// list: that is a loose list. -1 when the item does not do so.
new_list_mark :: proc(doc: ^Document, block: int) -> (at: int, mark: u8) {
	at = -1
	if block <= 0 || block >= doc.count {
		return
	}
	b := block_at(doc, block)
	before := block_at(doc, block - 1)
	if b.marker == .None || b.spacing != .Item || before.list_depth < b.list_depth {
		return
	}
	source := doc.source
	start := block_start(doc, block)
	end, _ := line_at(source, start)
	after_before := clamp(block_start(doc, block - 1) + int(before.lines), 0, start)
	if count_lines(source, after_before, start) < 2 {
		return
	}
	i := skip_quote_marks(source, start, end)
	mark_end, char, found := list_mark_at(source, i, end)
	if !found {
		return
	}
	switch char {
	case '-':
		return i, '*'
	case '*', '+':
		return i, '-'
	case '.':
		return mark_end - 1, ')'
	case ')':
		return mark_end - 1, '.'
	}
	return
}

// The marks of quotes and the spaces at the start of a line, from `at`:
// where the next thing of the line starts.
skip_quote_marks :: proc(source: []u8, at, end: int) -> int {
	at := at
	for at < end && (source[at] == '>' || source[at] == ' ' || source[at] == '\t') {
		at += 1
	}
	return at
}

// The mark of a list item at `at` of a line: a bullet ("-", "*", "+") or
// a number of 1 to 9 digits and its "." or ")". `end` is after it, `char`
// is the bullet or the delimiter of the number.
list_mark_at :: proc(source: []u8, at, line_end: int) -> (end: int, char: u8, found: bool) {
	if at >= line_end {
		return
	}
	if c := source[at]; c == '-' || c == '*' || c == '+' {
		return at + 1, c, true
	}
	digits := at
	for digits < line_end && digits - at < 9 && source[digits] >= '0' && source[digits] <= '9' {
		digits += 1
	}
	if digits > at && digits < line_end && (source[digits] == '.' || source[digits] == ')') {
		return digits + 1, source[digits], true
	}
	return
}

// A line from `line` to `end` that is only the mark of a list item, and a
// "[ ]" or "[x]" after it, with nothing after them, not a space either:
// a mark that is being typed when the caret is in it (`typed_mark`).
bare_mark_line :: proc(source: []u8, line, end: int) -> bool {
	if end <= line || source[end - 1] == ' ' || source[end - 1] == '\t' {
		return false
	}
	at := skip_quote_marks(source, line, end)
	mark_end, _, found := list_mark_at(source, at, end)
	if !found {
		return false
	}
	if mark_end == end {
		return true
	}
	// "- [ ]": one space or more, and the box at the end of the line.
	box := mark_end
	for box < end && (source[box] == ' ' || source[box] == '\t') {
		box += 1
	}
	return box > mark_end && end - box == 3 && source[box] == '[' && source[box + 2] == ']' && (source[box + 1] == ' ' || source[box + 1] == 'x' || source[box + 1] == 'X')
}
