package document

import "core:strings"

// Code in a fence, in an editor that does not show the two lines of the
// fence: where text goes in a block with no line of code, what Return
// does in the line of a fence that was typed, and how the caret gets out
// of the block after a closing fence that was typed.

// The run of a fence in a line from `line` to `end`: three or more "`"
// or "~" after the marks of the containers of the block (the indent,
// the ">" of a quote, the mark of a list item). False for a line with
// none.
@(private)
fence_run :: proc(source: []u8, line, end: int) -> (from, to: int, ok: bool) {
	from = line
	for from < end && source[from] != '`' && source[from] != '~' {
		from += 1
	}
	to = from
	for to < end && source[to] == source[from] {
		to += 1
	}
	return from, to, to - from >= 3
}

// True for a line that is only a fence: one that ends code.
@(private)
closing_fence :: proc(source: []u8, line, end: int) -> bool {
	_, to := fence_run(source, line, end) or_return
	for i in to ..< end {
		if source[i] != ' ' && source[i] != '\t' {
			return false
		}
	}
	return true
}

// What a line of the code of a block starts with: the marks before the
// fence in its first line, with spaces for the mark of a list item (the
// lines after the first one of an item have its indent) and the ">" of
// each quote as it is.
@(private)
write_code_lead :: proc(out: ^strings.Builder, doc: ^Document, block: int) {
	start := block_start(doc, block)
	end, _ := line_at(doc.source, start)
	from, _, _ := fence_run(doc.source, start, end)
	for ch in doc.source[start:from] {
		strings.write_byte(out, ch == '>' || ch == '\t' ? ch : ' ')
	}
}

// Where text goes in code in a fence that has no text: the end of its
// first line when it has one (an empty line, after its indent), or with
// `needs_line` the start of the line after the fence, where a line for
// the text must come first (the line there is the closing fence, or
// another block, or the end of the source). False for another block,
// and with no line break after the fence.
code_place :: proc(doc: ^Document, block: int) -> (offset: int, needs_line: bool, ok: bool) {
	b := block_at(doc, block)
	if !b.fenced || len(b.text.bytes) > 0 {
		return
	}
	start := block_start(doc, block)
	end, content := line_at(doc.source, start)
	if content == end {
		return
	}
	if content < start + int(b.lines) {
		if line_end, _ := line_at(doc.source, content); !closing_fence(doc.source, content, line_end) {
			return line_end, false, true
		}
	}
	return content, true, true
}

// The text that goes into the source for `text` typed at `offset`, when
// that is the place of code with no line (`code_place`): a line of its
// own for it, as a line of the code of its block. `caret` is where the
// caret is after it, from the offset. False at each other place. The
// text is memory of `allocator`.
code_first_line :: proc(doc: ^Document, at: Address, offset: int, text: string, allocator := context.allocator) -> (own: string, caret: int, ok: bool) {
	if at.empty != 0 {
		return
	}
	place, needs_line := code_place(doc, at.block) or_return
	if !needs_line || place != offset {
		return
	}
	out := strings.builder_make(allocator)
	write_code_lead(&out, doc, at.block)
	strings.write_string(&out, text)
	caret = strings.builder_len(out)
	strings.write_string(&out, line_ending(doc.source))
	return strings.to_string(out), caret, true
}

// The line of the closing fence of a block of code: its start and its
// end before the line break. False for code with no closing fence.
@(private)
code_close :: proc(doc: ^Document, block: int) -> (line, end: int, ok: bool) {
	b := block_at(doc, block)
	if !b.fenced {
		return
	}
	start := block_start(doc, block)
	first_end, _ := line_at(doc.source, start)
	open, open_end := fence_run(doc.source, start, first_end) or_return
	end = break_before(doc.source, min(start + int(b.lines), len(doc.source)))
	line = line_start(doc.source, end)
	if line <= start || !closing_fence(doc.source, line, end) {
		return
	}
	from, to, _ := fence_run(doc.source, line, end)
	return line, end, doc.source[from] == doc.source[open] && to - from >= open_end - open
}

// What Return puts into the source for a caret at `offset` in the first
// line of code in a fence, where the caret is while the fence is typed:
// the first line of the code, and for code with no closing fence that
// fence after it, so the code does not take the rest of the document.
// The text goes in at the offset; `caret` is where the caret is after
// it, from the offset. False at each other place.
fence_return :: proc(doc: ^Document, at: Address, offset: int, allocator := context.allocator) -> (text: string, caret: int, ok: bool) {
	if at.empty != 0 || !block_at(doc, at.block).fenced {
		return
	}
	start := block_start(doc, at.block)
	end, _ := line_at(doc.source, start)
	from, to := fence_run(doc.source, start, end) or_return
	if offset < to || offset > end {
		return
	}
	nl := line_ending(doc.source)
	out := strings.builder_make(allocator)
	strings.write_string(&out, nl)
	write_code_lead(&out, doc, at.block)
	caret = strings.builder_len(out)
	// Not in the word after the fence: the rest of it is a line of code.
	if _, _, closed := code_close(doc, at.block); !closed && offset == end {
		strings.write_string(&out, nl)
		write_code_lead(&out, doc, at.block)
		strings.write_bytes(&out, doc.source[from:to])
	}
	return strings.to_string(out), caret, true
}

// For a caret at `offset` in the line of the closing fence of its block,
// where it is after that fence was typed: the range of that line when
// the line after it is a fence too, the one that closed the code before
// (it now starts code of its own, and closes this code again when the
// typed line goes). False with no such line after it.
typed_close_range :: proc(doc: ^Document, at: Address, offset: int) -> (start, end: int, ok: bool) {
	if at.empty != 0 {
		return
	}
	line, line_end := code_close(doc, at.block) or_return
	if offset < line || offset > line_end {
		return
	}
	_, next := line_at(doc.source, line)
	next_end, _ := line_at(doc.source, next)
	return line, next, next < len(doc.source) && closing_fence(doc.source, next, next_end)
}

// Where the caret goes from the line of the closing fence of its block,
// which shows no place for it: an empty paragraph after the code. With
// none there, `text` at `at` makes one. False for a caret at another
// place, and where an empty paragraph cannot be (the next block is in a
// list with this one). The text is memory of `allocator`.
code_exit :: proc(doc: ^Document, address: Address, offset: int, allocator := context.allocator) -> (at: int, text: string, caret: int, ok: bool) {
	if address.empty != 0 {
		return
	}
	line, line_end := code_close(doc, address.block) or_return
	if offset < line || offset > line_end {
		return
	}
	if address.block + 1 < doc.count && in_list(block_at(doc, address.block + 1)) {
		return
	}
	// As Return at the end of a text (`line_break`): the empty paragraph
	// is the first line after the lines of the block, and the line after
	// it ends it. An empty line of the source that is there is the place.
	after, empty := block_empty_lines(doc, address.block)
	if empty > 0 && after < len(doc.source) {
		return after, "", after, true
	}
	nl := line_ending(doc.source)
	at = break_before(doc.source, after)
	return at, strings.concatenate({nl, empty == 0 ? nl : ""}, allocator), at + len(nl), true
}
