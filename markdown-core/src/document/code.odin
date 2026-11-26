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

// True for a line that is only a fence, one that can end code: before
// the fence only the indent and the ">" of a quote, and nothing after
// it. A line of code that ends with such a run ("echo ```") is none.
@(private)
closing_fence :: proc(source: []u8, line, end: int) -> bool {
	from, to := fence_run(source, line, end) or_return
	for i in line ..< from {
		if source[i] != ' ' && source[i] != '\t' && source[i] != '>' {
			return false
		}
	}
	for i in to ..< end {
		if source[i] != ' ' && source[i] != '\t' {
			return false
		}
	}
	return true
}

// True for a line that ends the code that the fence in the line from
// `open` to `open_end` starts: a closing fence of the same character,
// and not shorter.
@(private)
closes_code :: proc(source: []u8, open, open_end, line, end: int) -> bool {
	if !closing_fence(source, line, end) {
		return false
	}
	first, first_end, _ := fence_run(source, open, open_end)
	from, to, _ := fence_run(source, line, end)
	return source[from] == source[first] && to - from >= first_end - first
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
	end = break_before(doc.source, min(start + int(b.lines), len(doc.source)))
	line = line_start(doc.source, end)
	return line, end, line > start && closes_code(doc.source, start, first_end, line, end)
}

// How the code of the caret is before text is typed, for the rules
// after it (`typed_fence`).
Code_Before :: struct {
	in_code: bool, // the caret is in code in a fence
	closed:  bool, // which has a closing fence
	// The caret is in the line of a fence whose closing fence is the
	// next line: a fence that was typed and got it (`.Opened`).
	pair:    bool,
	start:   int, // where the line of that fence starts
}

code_before :: proc(doc: ^Document, at: Address, offset: int) -> (before: Code_Before) {
	if doc.count == 0 || at.empty != 0 || !block_at(doc, at.block).fenced {
		return
	}
	line, _, closed := code_close(doc, at.block)
	start := block_start(doc, at.block)
	first_end, content := line_at(doc.source, start)
	return {true, closed, closed && line == content && offset <= first_end, start}
}

// What the caret is in after text that was typed made a fence, or was
// typed in the line of one.
Typed_Fence :: enum {
	None,
	// A new fence, which starts code: `text` at `start` is the closing
	// fence of that code, so it takes no text after it, and no fence of
	// other code is its end. Or one more character of such a fence: the
	// text is that character for its closing fence.
	Opened,
	// A closing fence before the one that the code had: the typed line,
	// from `start` to `end`, goes, and the caret leaves (`code_exit`).
	Closed_Twice,
	// The closing fence of code that had none: the caret leaves.
	Closed,
	// The line of a fence that was typed is no fence now (a "`" in the
	// word after it, or its characters went): the closing fence that it
	// got, from `start` to `end` with the line break before it, goes,
	// or it would start code of its own.
	Unopened,
}

// The rule for a caret at `offset` after text was typed there. The text
// is memory of `allocator`.
typed_fence :: proc(doc: ^Document, before: Code_Before, at: Address, offset: int, allocator := context.allocator) -> (kind: Typed_Fence, start, end: int, text: string) {
	if doc.count == 0 {
		return
	}
	if before.pair {
		// The line of the fence is where it was, or, when text before it
		// went, the line of the caret.
		line := offset < before.start ? line_start(doc.source, offset) : min(before.start, len(doc.source))
		line_end, next := line_at(doc.source, line)
		if opens := block_at_offset(doc, line); !block_at(doc, opens).fenced || block_start(doc, opens) != line {
			if next_end, _ := line_at(doc.source, next); next > line_end && next < len(doc.source) && closing_fence(doc.source, next, next_end) {
				return .Unopened, line_end, next_end, ""
			}
			return
		}
	}
	if at.empty != 0 || !block_at(doc, at.block).fenced {
		return
	}
	first := block_start(doc, at.block)
	first_end, _ := line_at(doc.source, first)
	from, to, _ := fence_run(doc.source, first, first_end)
	if offset >= to && offset <= first_end {
		if before.in_code {
			// One more character of the fence that was typed: its closing
			// fence, in the next line, gets one too, or it is too short
			// to end the code.
			_, next := line_at(doc.source, first)
			next_end, _ := line_at(doc.source, next)
			if offset == to && next < len(doc.source) && closing_fence(doc.source, next, next_end) {
				if close, close_end, _ := fence_run(doc.source, next, next_end); doc.source[close] == doc.source[from] && close_end - close == to - from - 1 {
					return .Opened, close_end, close_end, strings.clone(string(doc.source[from:from + 1]), allocator)
				}
			}
			return
		}
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
	// The line after it is the fence that closed the code before: it
	// starts code of its own now, and closes this code again when the
	// typed line goes.
	_, next := line_at(doc.source, line)
	if next_end, _ := line_at(doc.source, next); next < len(doc.source) && closes_code(doc.source, first, first_end, next, next_end) && before.in_code && before.closed {
		return .Closed_Twice, line, next, ""
	}
	// In the middle of code that has its closing fence: no end of the
	// code that the reader sees. The next character makes the line a
	// line of code again.
	if before.in_code && before.closed {
		return
	}
	return .Closed, line, line_end, ""
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

// Where the caret goes from the line of the closing fence of its block,
// which shows no place for it: an empty paragraph after the code. With
// none there, `text` at `at` makes one, as Return at the end of a text
// does (`line_break`). False for a caret at another place, and where an
// empty paragraph cannot be: the next block is in a list or in a quote
// with the code. The text is memory of `allocator`.
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
		if next := block_at(doc, address.block + 1); in_list(next) || (b.quote_depth > 0 && next.quote_depth > 0) {
			return
		}
	}
	if b.empties > 0 {
		caret = empty_offset(doc, address.block, 1)
		return caret, "", caret, true
	}
	after, empty := block_empty_lines(doc, address.block)
	nl := line_ending(doc.source)
	at = break_before(doc.source, after)
	return at, strings.concatenate({nl, empty == 0 ? nl : ""}, allocator), at + len(nl), true
}
