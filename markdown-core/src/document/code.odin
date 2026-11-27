package document

import "core:strings"

// Code in a fence, in an editor that does not show the two lines of the
// fence, so a caret has no place in them: where text goes in a block
// with no line of code, how a fence that is typed becomes code with the
// caret in it, and how the caret gets out of the code after a closing
// fence that was typed.

// Where the line of the fence of code starts. Not always where the block
// starts: the first block of a quote or of a list item starts at the
// line of their mark, which can be a line before the fence (">" alone).
fence_start :: proc(doc: ^Document, block: int) -> int {
	start := block_start(doc, block)
	end := min(start + int(block_at(doc, block).lines), len(doc.source))
	for at := start; at < end; {
		line_end, next := line_at(doc.source, at)
		if _, _, found := fence_run(doc.source, at, line_end); found {
			return at
		}
		at = next
	}
	return start
}

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

// True for a line with nothing after its fence: the form of a closing
// fence. Only for a line that the parser read as a fence (the first line
// of code, or a line that closed code before an edit of another line):
// if a line of the source is a closing fence, only the parser knows
// (`Block.closed`).
@(private)
bare_fence :: proc(source: []u8, line, end: int) -> bool {
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
	start := fence_start(doc, block)
	end, _ := line_at(doc.source, start)
	from, _, _ := fence_run(doc.source, start, end)
	for ch, i in doc.source[start:from] {
		strings.write_byte(out, ch == '>' || ch == '\t' ? ch : ' ')
		// A ">" before the fence or before the mark of a list item gets
		// a space when it has none: the parser takes the first space
		// after a ">" for the quote, not for the indent of the item or
		// of the code. Not before a ">" or a tab, which a space would
		// move to another column.
		if next := start + i + 1; ch == '>' && (next >= from || (doc.source[next] != ' ' && doc.source[next] != '\t' && doc.source[next] != '>')) {
			strings.write_byte(out, ' ')
		}
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
	start := fence_start(doc, block)
	end, content := line_at(doc.source, start)
	if content == end {
		return
	}
	// A line of the block after the fence that is not its closing fence:
	// an empty line of code.
	if close, _, closed := code_close(doc, block); content < block_start(doc, block) + int(b.lines) && !(closed && close == content) {
		line_end, _ := line_at(doc.source, content)
		return line_end, false, true
	}
	return content, true, true
}

// The text that goes into the source for `text` typed at `offset`, when
// that is the place of code with no line (`code_place`): a line of its
// own for it, as a line of the code of its block, and so each line of
// a text with line breaks. In an empty line of code that ends with the
// mark of a quote, the text after the space of that quote. `caret` is where the
// caret is after it, from the offset. False at each other place. The
// text is memory of `allocator`.
code_first_line :: proc(doc: ^Document, at: Address, offset: int, text: string, allocator := context.allocator) -> (own: string, caret: int, ok: bool) {
	if at.empty != 0 {
		return
	}
	place, needs_line := code_place(doc, at.block) or_return
	if place != offset {
		return
	}
	if !needs_line {
		// An empty line of code that is only the mark of a quote: the
		// space of the quote first, or the parser takes the first space
		// of the text for it.
		if offset == 0 || doc.source[offset - 1] != '>' || block_at(doc, at.block).quote_depth == 0 {
			return
		}
		return strings.concatenate({" ", text}, allocator), len(text) + 1, true
	}
	out := strings.builder_make(allocator)
	write_code_lead(&out, doc, at.block)
	// Each line of a text with line breaks (a paste) is a line of the
	// code.
	for i := 0; i < len(text); i += 1 {
		strings.write_byte(&out, text[i])
		if text[i] == '\n' || (text[i] == '\r' && (i + 1 == len(text) || text[i + 1] != '\n')) {
			write_code_lead(&out, doc, at.block)
		}
	}
	caret = strings.builder_len(out)
	strings.write_string(&out, line_ending(doc.source))
	return strings.to_string(out), caret, true
}

// What a delete takes out for a caret in code in a fence with no text:
// the code, which is its two fences then (and an empty line between
// them), from the fence to the end of its last line. The marks of its
// containers before the fence stay, so a list item or a quote is there
// with no text, and the caret is where the fence was. False for each
// other block, and for a caret at another place.
code_delete :: proc(doc: ^Document, at: Address, offset: int) -> (start, end: int, ok: bool) {
	if at.empty != 0 {
		return
	}
	place, _ := code_place(doc, at.block) or_return
	if place != offset {
		return
	}
	first := fence_start(doc, at.block)
	first_end, _ := line_at(doc.source, first)
	start, _, _ = fence_run(doc.source, first, first_end)
	end = break_before(doc.source, min(block_start(doc, at.block) + int(block_at(doc, at.block).lines), len(doc.source)))
	return start, max(end, first_end), true
}

// The line of the closing fence of a block of code: its start and its
// end before the line break. False for code with no closing fence.
@(private)
code_close :: proc(doc: ^Document, block: int) -> (line, end: int, ok: bool) {
	b := block_at(doc, block)
	if !b.fenced || !b.closed {
		return
	}
	end = break_before(doc.source, min(block_start(doc, block) + int(b.lines), len(doc.source)))
	return line_start(doc.source, end), end, true
}

// How the code of the caret is before a command of the reader, for the
// rules after it (`typed_fence`).
Code_Before :: struct {
	in_code: bool, // the caret is in code in a fence
	closed:  bool, // which has a closing fence
}

code_before :: proc(doc: ^Document, at: Address) -> (before: Code_Before) {
	if doc.count == 0 || at.empty != 0 || !block_at(doc, at.block).fenced {
		return
	}
	return {true, block_at(doc, at.block).closed}
}

// What the caret is in after a command of the reader made a fence.
Typed_Fence :: enum {
	None,
	// A new fence, which starts code: `text` at `start` is the closing
	// fence of that code, so it takes no text after it, and no fence of
	// other code is its end. The caret then goes into the code
	// (`code_place`): the line of a fence shows no place for it.
	Opened,
	// A closing fence before the one that the code had: the typed line,
	// from `start` to `end`, goes, and the caret leaves (`code_exit`).
	Closed_Twice,
	// The closing fence of code that had none: the caret leaves.
	Closed,
}

// The rule for a caret at `offset` after a command of the reader. The
// text is memory of `allocator`.
typed_fence :: proc(doc: ^Document, before: Code_Before, at: Address, offset: int, allocator := context.allocator) -> (kind: Typed_Fence, start, end: int, text: string) {
	if doc.count == 0 || at.empty != 0 || !block_at(doc, at.block).fenced {
		return
	}
	first := fence_start(doc, at.block)
	first_end, _ := line_at(doc.source, first)
	from, to, _ := fence_run(doc.source, first, first_end)
	if offset >= to && offset <= first_end {
		// Not for the caret of a fence that was there.
		if before.in_code {
			return
		}
		// Also when the parser finds a closing fence for it: that one
		// is the fence of other code after it.
		out := strings.builder_make(allocator)
		strings.write_string(&out, line_ending(doc.source))
		write_code_lead(&out, doc, at.block)
		strings.write_bytes(&out, doc.source[from:to])
		return .Opened, first_end, first_end, strings.to_string(out)
	}
	line, line_end, closed := code_close(doc, at.block)
	if !closed || offset < line || offset > line_end {
		return
	}
	// In the fence of that line or after it, where the caret is when it
	// typed a character of it. Not before it: that is the place of a
	// caret in code with no line (`code_place`), which typed no fence.
	if typed_from, _, _ := fence_run(doc.source, line, line_end); offset <= typed_from {
		return
	}
	// The line after it is the fence that closed the code before: it
	// starts code of its own now, and closes this code again when the
	// typed line goes.
	_, next := line_at(doc.source, line)
	if before.in_code && before.closed && at.block + 1 < doc.count && block_at(doc, at.block + 1).fenced && block_start(doc, at.block + 1) == next {
		next_end, _ := line_at(doc.source, next)
		close, close_end, _ := fence_run(doc.source, next, next_end)
		if bare_fence(doc.source, next, next_end) && doc.source[close] == doc.source[from] && close_end - close >= to - from {
			return .Closed_Twice, line, next, ""
		}
	}
	// In the middle of code that has its closing fence: no end of the
	// code that the reader sees. The next character makes the line a
	// line of code again.
	if before.in_code && before.closed {
		return
	}
	return .Closed, line, line_end, ""
}

// Where the caret goes from the line of the closing fence of its block,
// which shows no place for it: an empty paragraph after the code. With
// none there, `text` at `at` makes one, as Return at the end of a text
// does (`line_break`). False for a caret at another place, and where an
// empty paragraph cannot be: the next block is in a list or in a quote
// with the code. Code that is in no list leaves also before a list. The text is memory of `allocator`.
code_exit :: proc(doc: ^Document, address: Address, offset: int, allocator := context.allocator) -> (at: int, text: string, caret: int, ok: bool) {
	if address.empty != 0 {
		return
	}
	line, line_end := code_close(doc, address.block) or_return
	if offset < line || offset > line_end {
		return
	}
	b := block_at(doc, address.block)
	if address.block + 1 < doc.count {
		// Not between two blocks of the list or of the quote that the
		// code is in: an empty paragraph there makes two of it.
		if next := block_at(doc, address.block + 1); (b.list_depth > 0 && in_list(next)) || (b.quote_depth > 0 && next.quote_depth > 0) {
			return
		}
	}
	at, text, caret = paragraph_after(doc, address.block, allocator)
	return at, text, caret, true
}

// An empty paragraph after a block: the offset of the one that is there
// (`text` is empty then), or `text` at `at` makes one, as Return at the
// end of a text does (`line_break`). `caret` is its offset.
@(private)
paragraph_after :: proc(doc: ^Document, block: int, allocator := context.allocator) -> (at: int, text: string, caret: int) {
	if block_at(doc, block).empties > 0 {
		caret = empty_offset(doc, block, 1)
		return caret, "", caret
	}
	after, empty := block_empty_lines(doc, block)
	nl := line_ending(doc.source)
	at = break_before(doc.source, after)
	return at, strings.concatenate({nl, empty == 0 ? nl : ""}, allocator), at + len(nl)
}

// What a move of the caret down puts into the source when the caret is
// in the last line of code that is the last block of the document, with
// no empty paragraph after it: an empty paragraph, which is the only
// place below the code that a caret can go to (the line of its closing
// fence does not show). False for each other caret: in code with no
// closing fence the text would be code, and above another block the
// move finds a line.
code_below :: proc(doc: ^Document, at: Address, allocator := context.allocator) -> (start: int, text: string, caret: int, ok: bool) {
	if doc.count == 0 || at.empty != 0 || at.block != doc.count - 1 {
		return
	}
	if b := block_at(doc, at.block); !b.fenced || !b.closed || b.empties > 0 {
		return
	}
	start, text, caret = paragraph_after(doc, at.block, allocator)
	return start, text, caret, true
}
