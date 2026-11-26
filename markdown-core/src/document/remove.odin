package document

import "core:bytes"
import "core:mem"
import "core:slice"
import "core:unicode/utf8"

// Text that goes out of the source: a selection that a key deletes or
// that typed text takes the place of, a word, a line. The range is
// between two places of a caret, so it has no part of a thing that the
// source has as a whole (an entity, a line break with the marks of its
// next line). What it can have a part of is a style: one of the two
// marks of bold text, code, a link. Such a mark stays, so the text that
// stays has the style that it had.

// What takes the place of the bytes from `start` to `end` of a source
// when the text between the offsets `from` and `to` goes out, with
// `text` in its place. `pairs`: the marks of the styles of the blocks
// that the two offsets are in (`block_map`), in the order of their
// first marks for each block.
//
// A mark in the range whose other mark is not in it stays. A style
// that has all of its text in the range goes with its two marks, also
// the ones right outside of the range: text that is typed after "bold"
// went out of "**bold**" is not bold, and the source has no "****".
// The new text comes first, in the styles that end in the range, as
// text that is typed at the place where the range starts would be.
//
// Two things that Markdown reads in another way are put right. Spaces
// and a line break that the edit puts on the inner side of a mark of
// bold text and the like go to its outer side ("** more**" is no bold
// text); they are the same spaces of the text, with no style. And a
// mark that ends a style right before the same mark that starts one
// ("`a``b`", "**a****b**") goes with it: the two texts are one text of
// that style.
//
// `caret`: the offset of the place of the range in the source that the
// edit gives, after the new text. Memory of `allocator`, the caller's
// to delete.
//
// `kept`: gets the ranges of the source in the range of the edit that
// the text of the edit has again (a mark, spaces): they did not go.
range_edit :: proc(pairs: []Pair, source: []u8, from, to: int, text: string, allocator := context.allocator, kept: ^[dynamic][2]int = nil) -> (edit: Edit, caret: int) {
	start, end := from, to
	// The styles that have all of their text in the range, from the
	// inside out: "**_text_**" has two.
	for grown := true; grown; {
		grown = false
		for pair in pairs {
			if pair.close < 0 || pair.open_end < start || pair.close > end || (pair.open >= start && pair.close_end <= end) {
				continue
			}
			// No text of the range is before its first mark or after
			// its last one, when the mark is outside.
			if (pair.open < start && pair.open_end != start) || (pair.close_end > end && pair.close != end) {
				continue
			}
			start, end = min(start, pair.open), max(end, pair.close_end)
			grown = true
		}
	}
	// The marks that stay, in the order of the source. Styles do not
	// cross: the ones that end in the range all have its start in them,
	// the inner one first, and the ones that start in it all have its
	// end, the outer one first.
	Mark :: struct {
		start, end: int,
		tight:      bool,
	}
	inside :: proc(a, b, start, end: int) -> bool {return a >= start && b <= end && b > a}
	closes, opens: [dynamic]Mark
	defer delete(closes)
	defer delete(opens)
	#reverse for pair in pairs {
		if pair.close >= 0 && inside(pair.close, pair.close_end, start, end) && !inside(pair.open, pair.open_end, start, end) {
			append(&closes, Mark{pair.close, pair.close_end, pair.tight})
		}
	}
	for pair in pairs {
		if pair.close >= 0 && inside(pair.open, pair.open_end, start, end) && !inside(pair.close, pair.close_end, start, end) {
			append(&opens, Mark{pair.open, pair.open_end, pair.tight})
		}
	}
	// The mark that ends a style right after the range, and the one
	// that starts a style right before it: with no new text and no mark
	// that stays between, they are beside what is before and after the
	// range now.
	close_after :: proc(pairs: []Pair, start, at: int) -> (mark: Mark, ok: bool) {
		for pair in pairs {
			if pair.close == at && pair.close_end > at && pair.open < start {
				return {pair.close, pair.close_end, pair.tight}, true
			}
		}
		return
	}
	open_before :: proc(pairs: []Pair, at, end: int) -> (mark: Mark, ok: bool) {
		for pair in pairs {
			if pair.close >= end && pair.open_end == at && pair.open < at {
				return {pair.open, pair.open_end, pair.tight}, true
			}
		}
		return
	}
	bare := len(text) == 0 && len(closes) == 0 && len(opens) == 0
	head := start
	before, after := 0, 0
	// Spaces before the range with a mark that ends a style right after
	// them: they go after the marks that end there.
	if len(text) == 0 {
		first, found := len(closes) > 0 ? closes[0] : Mark{}, len(closes) > 0
		if bare {
			first, found = close_after(pairs, start, end)
		}
		if run := space_before(source, start); found && first.tight && run > 0 {
			before = run
			for bare {
				mark := close_after(pairs, start, end) or_break
				append(&closes, mark)
				end = mark.end
			}
		}
	}
	// Spaces after the range with a mark that starts a style right
	// before them: they go before the marks that start there.
	{
		last, found := len(opens) > 0 ? opens[len(opens) - 1] : Mark{}, len(opens) > 0
		if bare && before == 0 {
			last, found = open_before(pairs, start, end)
		}
		if run := space_after(source, end); found && last.tight && run > 0 {
			after = run
			for bare && before == 0 {
				mark := open_before(pairs, head, end) or_break
				inject_at(&opens, 0, mark)
				head = mark.start
			}
		}
	}
	// A mark that ends a style, and right after it the same mark for
	// the start of one: the two go.
	for len(text) == 0 && before == 0 && after == 0 && len(closes) > 0 {
		close := closes[len(closes) - 1]
		open, kept := len(opens) > 0 ? opens[0] : Mark{}, len(opens) > 0
		if !kept {
			found := false
			for pair in pairs {
				if pair.open == end && pair.open_end > end && pair.close >= pair.open_end {
					open, found = Mark{pair.open, pair.open_end, pair.tight}, true
				}
			}
			found or_break
		}
		if string(source[close.start:close.end]) != string(source[open.start:open.end]) {
			break
		}
		pop(&closes)
		if kept {
			ordered_remove(&opens, 0)
		} else {
			end = open.end
		}
	}
	out := make([dynamic]u8, 0, len(text) + before + after + 8, allocator)
	append(&out, text)
	for mark in closes {
		append(&out, ..source[mark.start:mark.end])
	}
	append(&out, ..source[start - before:start])
	// The caret is after the new text. With no new text it is before
	// the marks that end a style there (text that is typed next has that
	// style, as the text that went had), but after the marks of code and
	// of a link, where text reads in another way than outside (an
	// entity, a mark), and after each mark when the bytes that went end
	// with a space or a line break (the end of a block that was joined),
	// which is no end of text of a style. So the bytes that went give
	// the text of before when they are put in again. And after spaces
	// that moved out of a style, which are before the place.
	caret = head - before + len(text)
	ends_word := to > from && (source[to - 1] == ' ' || source[to - 1] == '\t' || source[to - 1] == '\n' || source[to - 1] == '\r')
	if before > 0 || (len(text) == 0 && len(closes) > 0 && (!closes[0].tight || ends_word)) {
		caret = head - before + len(out)
	}
	append(&out, ..source[end:end + after])
	for mark in opens {
		append(&out, ..source[mark.start:mark.end])
	}
	if kept != nil {
		append(kept, [2]int{start - before, start}, [2]int{end, end + after})
		for mark in closes {
			append(kept, [2]int{mark.start, mark.end})
		}
		for mark in opens {
			append(kept, [2]int{mark.start, mark.end})
		}
	}
	return {head - before, end + after, string(out[:])}, caret
}

// How many bytes right before an offset are space between two words of
// a text: spaces and tabs, or a line break with them around it and the
// marks of a quote at the start of its next line.
@(private)
space_before :: proc(source: []u8, at: int) -> int {
	i := at
	for i > 0 && (source[i - 1] == ' ' || source[i - 1] == '\t' || source[i - 1] == '>') {
		i -= 1
	}
	if line := break_before(source, i); line < i {
		i = line
	} else {
		// A ">" with no line break before it is text.
		i = at
	}
	for i > 0 && (source[i - 1] == ' ' || source[i - 1] == '\t') {
		i -= 1
	}
	return at - i
}

// `space_before` for the bytes right after an offset.
@(private)
space_after :: proc(source: []u8, at: int) -> int {
	i := at
	for i < len(source) && (source[i] == ' ' || source[i] == '\t') {
		i += 1
	}
	if i < len(source) && (source[i] == '\n' || source[i] == '\r') {
		_, i = line_at(source, i)
		for i < len(source) && (source[i] == ' ' || source[i] == '\t' || source[i] == '>') {
			i += 1
		}
	}
	return i - at
}

// The range of the source of the lines that two offsets are in, with
// the line break of the last one: what goes out when the lines go.
@(private)
lines_range :: proc(source: []u8, from, to: int) -> (start, end: int) {
	from := clamp(from, 0, len(source))
	// The last line is the one of the last byte of the range: a range
	// that ends at the start of a line has nothing of that line.
	last := clamp(to > from ? to - 1 : to, from, len(source))
	start = line_start(source, from)
	_, end = line_at(source, line_start(source, last))
	return
}

// The edit that takes the lines of two offsets out of a document
// (`lines_range`), with the definitions of links in them kept, and the
// offset where the lines were. False when there is nothing to take.
remove_lines :: proc(doc: ^Document, from, to: int, allocator := context.allocator) -> (edit: Edit, caret: int, ok: bool) {
	start, end := lines_range(doc.source, from, to)
	if start == end {
		return
	}
	edit, caret = keep_defs(doc, {start, end, ""}, start, start, allocator)
	return edit, caret, true
}

// The map of a block that a caller of `replace_range` has already: the
// places and the marks of the block of a caret.
Held :: struct {
	block:  int,
	places: []Place,
	pairs:  []Pair,
	valid:  bool,
}

// The edit that takes the text between two offsets of the source out of
// a document and puts `text` in its place (`range_edit`), for two
// offsets that are places of a caret, `from` not after `to`. The text
// of the block of `to` that stays goes on in the block of `from`, which
// keeps its kind; the blocks between them go. The definitions of links
// in the range stay: they are no text, and other text uses them.
//
// False for a range that has no such edit yet: one with an end in code
// or in a table and the other end in another block (the rest of code
// is no text of a paragraph), but when the range has all of the text of
// its blocks, which then go with their lines; and one from a cell of a
// table to another one.
//
// `gone`: gets the bytes of the source that go and do not come back in
// the edit, in their order: the range with no mark, no space, no
// definition, and no line that stays. What a host puts in again to
// have the text of before.
replace_range :: proc(doc: ^Document, from, to: int, text: string, held := Held{}, allocator := context.allocator, gone: ^[dynamic]u8 = nil) -> (edit: Edit, caret: int, ok: bool) {
	if gone == nil {
		return replace_range_kept(doc, from, to, text, held, allocator, nil)
	}
	kept: [dynamic][2]int
	defer delete(kept)
	edit, caret = replace_range_kept(doc, from, to, text, held, allocator, &kept) or_return
	// The range of the edit with the ranges that stay out: what is
	// between them, in the order of the source.
	slice.sort_by(kept[:], proc(a, b: [2]int) -> bool {return a[0] < b[0]})
	at := edit.start
	for range in kept {
		if range[1] <= at || range[0] >= edit.end {
			continue
		}
		if range[0] > at {
			append(gone, ..doc.source[at:range[0]])
		}
		at = max(at, min(range[1], edit.end))
	}
	if at < edit.end {
		append(gone, ..doc.source[at:edit.end])
	}
	return edit, caret, true
}

// `replace_range`, with the ranges of the source in the edit that stay.
@(private)
replace_range_kept :: proc(doc: ^Document, from, to: int, text: string, held: Held, allocator: mem.Allocator, kept: ^[dynamic][2]int) -> (edit: Edit, caret: int, ok: bool) {
	if doc.count == 0 || from < 0 || to < from || to > len(doc.source) {
		return
	}
	first, last := block_at_offset(doc, from), block_at_offset(doc, to)
	// The maps of the two blocks: the one that the caller has, or one
	// that is made here.
	made: [2][dynamic]Place
	made_pairs: [2][dynamic]Pair
	defer for i in 0 ..< 2 {
		delete(made[i])
		delete(made_pairs[i])
	}
	map_of :: proc(doc: ^Document, block: int, held: Held, places: ^[dynamic]Place, pairs: ^[dynamic]Pair) -> ([]Place, []Pair) {
		if held.valid && held.block == block {
			return held.places, held.pairs
		}
		places^ = block_map(doc, block, pairs)
		return places[:], pairs[:]
	}
	places, pairs := map_of(doc, first, held, &made[0], &made_pairs[0])
	a, b := block_at(doc, first), block_at(doc, last)
	// The first line of the first block: where definitions that stay go.
	line := block_start(doc, first)
	if first != last {
		places_last, pairs_last := map_of(doc, last, held, &made[1], &made_pairs[1])
		verbatim :: proc(b: ^Block) -> bool {return b.kind == .Code || b.kind == .Table}
		if verbatim(a) || verbatim(b) {
			// All of the text of the blocks, or no edit.
			covers(doc, first, last, places, places_last, from, to) or_return
			edit, caret = whole_blocks(doc, line, last, text, allocator, kept)
			return edit, caret, true
		}
		// The marks of the two blocks, in the order of the source.
		both := make([dynamic]Pair, 0, len(pairs) + len(pairs_last))
		append(&both, ..pairs)
		append(&both, ..pairs_last)
		delete(made_pairs[0])
		made_pairs[0] = both
		pairs = both[:]
	} else if a.kind == .Table && address_in(places, first, from).cell != address_in(places, first, to).cell {
		// All of the cells of a table: the table goes with its lines.
		covers(doc, first, last, places, places, from, to) or_return
		edit, caret = whole_blocks(doc, line, last, text, allocator, kept)
		return edit, caret, true
	}
	// From an empty paragraph: what comes in its place is a paragraph of
	// its own, at the line of the empty one (`empty_text`). Not for
	// empty lines only that go: the lines after them are as they were.
	if empty_at(doc, first, from) > 0 && (len(text) > 0 || first != last) {
		led := empty_text(doc, text)
		defer delete(led)
		edit, caret = range_edit(pairs, doc.source, from, to, led, allocator, kept)
	} else {
		edit, caret = range_edit(pairs, doc.source, from, to, text, allocator, kept)
	}
	// All of the text of a paragraph went, and nothing came: its line
	// stays, as an empty line. The paragraph had an empty line before
	// it, which showed as no line; with the text out, that one shows,
	// so one of the two goes with the text, and the caret is in the
	// line where the paragraph was.
	if len(edit.text) == 0 && first > 0 && a.kind == .Paragraph && a.list_depth == 0 && a.quote_depth == 0 && edit.start == line {
		source := doc.source
		line_end, _ := line_at(source, edit.end)
		before := break_before(source, line)
		above := line_start(source, before)
		if line_end == edit.end && before < line && blank(source[above:before]) && block_at(doc, first - 1).kind != .Rule {
			edit.start, caret, line = above, above, above
		}
	}
	// The line under a heading is a line of the heading after its text:
	// it goes after the first line of what stays of the last block, so
	// the first block is the heading that it was, with that text. Only
	// for a range that starts in the text of the heading, not in an
	// empty paragraph after it.
	if first != last && a.kind == .Heading {
		source := doc.source
		lines := block_start(doc, first) + int(a.lines)
		if text_end, placed := place_of(doc, places, {block = first, byte = len(a.text.bytes)}); placed && text_end <= lines {
			_, under := line_at(source, text_end)
			rest := min(block_start(doc, last) + int(b.lines), len(source))
			// The lines after the first one stay where they are: a line
			// with the mark of a quote is no line of a heading.
			if _, next := line_at(source, min(edit.end, len(source))); edit.end <= rest {
				rest = min(rest, next)
			}
			// Not for a heading that has no text then: the line under
			// nothing is text itself.
			// And not for a range that ends after the lines of the last
			// block (in its empty paragraphs): no text of it stays.
			stays := rest < edit.end || (blank(source[line_start(source, edit.start):edit.start]) && len(edit.text) == 0 && blank(bytes.trim_right(source[edit.end:rest], {'\n', '\r'})))
			if under < lines && lines <= edit.end && edit.start < under && !stays {
				nl := line_ending(source)
				out := make([dynamic]u8, 0, len(edit.text) + rest - edit.end + lines - under + 4, allocator)
				append(&out, edit.text)
				append(&out, ..source[edit.end:rest])
				if len(out) == 0 || (out[len(out) - 1] != '\n' && out[len(out) - 1] != '\r') {
					append(&out, nl)
				}
				append(&out, ..source[under:lines])
				if out[len(out) - 1] != '\n' && out[len(out) - 1] != '\r' && rest < len(source) {
					append(&out, nl)
				}
				delete(edit.text, allocator)
				// The line under the heading and the rest of the last
				// block stay.
				if kept != nil {
					append(kept, [2]int{under, lines}, [2]int{edit.end, rest})
				}
				edit = {edit.start, rest, string(out[:])}
			}
		}
	}
	edit, caret = keep_defs(doc, edit, caret, line, allocator, kept)
	return edit, caret, true
}

// The edit that takes some blocks out with their lines, from the start
// of the first line of the first one, and puts `text` there as a
// paragraph of its own.
@(private)
whole_blocks :: proc(doc: ^Document, line, last: int, text: string, allocator: mem.Allocator, kept: ^[dynamic][2]int) -> (edit: Edit, caret: int) {
	_, end := block_source(doc, last)
	out := make([dynamic]u8, 0, len(text) + 4, allocator)
	append(&out, text)
	if len(text) > 0 && end < len(doc.source) {
		// Before what comes after the blocks.
		nl := line_ending(doc.source)
		append(&out, nl)
		append(&out, nl)
	}
	return keep_defs(doc, {line, end, string(out[:])}, line + len(text), line, allocator, kept)
}

// True for a range of the source that has all of the text of some
// blocks: it starts at the first place of the text of the first one or
// before it, and ends at the last place of the text of the last one or
// after it. A cell of a table with no text has no place; the first and
// the last one that have one count.
@(private)
covers :: proc(doc: ^Document, first, last: int, places, places_last: []Place, from, to: int) -> bool {
	for text, cell in block_texts(block_at(doc, first)) {
		_ = text
		if head, placed := place_of(doc, places, {block = first, cell = cell}); placed {
			if from > head {
				return false
			}
			break
		}
	}
	texts := block_texts(block_at(doc, last))
	#reverse for text, cell in texts {
		if tail, placed := place_of(doc, places_last, {block = last, cell = cell, byte = len(text.bytes)}); placed {
			return to >= tail
		}
	}
	return true
}

// An edit with the definitions of links that are in its range kept:
// they go before `line`, the start of a line at the start of the edit or
// before it, as lines of their own with an empty line after them.
// `edit.text` is memory of `allocator`, and so is the text of the
// result.
@(private)
keep_defs :: proc(doc: ^Document, edit: Edit, caret, line: int, allocator := context.allocator, stay: ^[dynamic][2]int = nil) -> (kept: Edit, at: int) {
	size := 0
	for def in doc.defs {
		if def.start >= edit.start && def.end <= edit.end {
			size += def.end - def.start
		}
	}
	if size == 0 || line > edit.start {
		return edit, caret
	}
	nl := line_ending(doc.source)
	out := make([dynamic]u8, 0, size + len(edit.text) + edit.start - line + 16, allocator)
	// A definition is no part of the paragraph before it only with an
	// empty line between the two.
	if before := break_before(doc.source, line); before < line && !blank(doc.source[line_start(doc.source, before):before]) {
		append(&out, nl)
	}
	for def in doc.defs {
		if def.start >= edit.start && def.end <= edit.end {
			append(&out, ..doc.source[def.start:def.end])
			append(&out, nl)
			// A definition that stays did not go.
			if stay != nil {
				append(stay, [2]int{def.start, def.end})
			}
		}
	}
	append(&out, nl)
	moved := len(out)
	append(&out, ..doc.source[line:edit.start])
	if stay != nil {
		append(stay, [2]int{line, edit.start})
	}
	append(&out, edit.text)
	delete(edit.text, allocator)
	return {line, edit.end, string(out[:])}, caret + moved
}

// The edit that puts the character before an address after the one at
// it (the two before it, at the end of a text), and where the caret is
// then: after the two. False when the address has no two characters
// around it that are next to each other in the source.
transpose :: proc(doc: ^Document, places: []Place, at: Address, allocator := context.allocator) -> (edit: Edit, caret: int, ok: bool) {
	text := text_at(doc, at)
	// Not from an empty paragraph or from after the spaces at the end of
	// a text: the two characters are not at that place.
	if text == nil || at.byte > len(text.bytes) || at.empty > 0 || at.spaces > 0 {
		return
	}
	middle := at.byte
	if middle >= len(text.bytes) {
		middle = char_step(text.bytes[:], middle, false)
	}
	last := char_step(text.bytes[:], middle, true)
	if middle <= 0 || last <= middle {
		return
	}
	first := char_step(text.bytes[:], middle, false)
	// Not a mark of the source that shows as text: the two would make
	// another thing of the line (" #" is no heading).
	for span in text.spans {
		if .Mark in span.style && span.start < last && span.end > first {
			return
		}
	}
	a_start, a_end := char_source(doc, places, at, first, middle) or_return
	b_start, b_end := char_source(doc, places, at, middle, last) or_return
	if a_end != b_start {
		return
	}
	// A space that changes places has a character that is no space on
	// each side after it, next to it in the source too. Markdown shows no
	// space at an end of a text or of a line, one space for a run of
	// them, and no bold text with a space inside its mark, so the page
	// would lose the space ("A b" would be " Ab", which shows "Ab"), and
	// the next Control-T would have no two characters. Code shows each
	// space as it is.
	if block_at(doc, at.block).kind != .Code {
		space :: proc(c: u8) -> bool {return c == ' ' || c == '\t'}
		shown_mark :: proc(text: ^Text, i: int) -> bool {
			for span in text.spans {
				if .Mark in span.style && span.start <= i && i < span.end {
					return true
				}
			}
			return false
		}
		if space(text.bytes[first]) {
			// To after the second character: the one after that is its
			// right side.
			if last >= len(text.bytes) || space(text.bytes[last]) || shown_mark(text, last) {
				return
			}
			// The source can have it in another form (an entity): only
			// where it starts counts.
			next_start, _, _ := char_source(doc, places, at, last, char_step(text.bytes[:], last, true))
			if next_start != b_end {
				return
			}
		}
		if space(text.bytes[middle]) {
			// To before the first character: the one before that is its
			// left side.
			if first == 0 {
				return
			}
			before := char_step(text.bytes[:], first, false)
			if space(text.bytes[before]) || shown_mark(text, before) {
				return
			}
			_, before_end, _ := char_source(doc, places, at, before, first)
			if before_end != a_start {
				return
			}
		}
	}
	out := make([]u8, b_end - a_start, allocator)
	copy(out, doc.source[b_start:b_end])
	copy(out[b_end - b_start:], doc.source[a_start:a_end])
	return {a_start, b_end, string(out)}, b_end, true
}
