package document

import "core:slice"

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
// that the two offsets are in (`block_map`).
//
// A mark in the range whose other mark is not in it stays. A style
// that has all of its text in the range goes with its two marks, also
// the ones right outside of the range: text that is typed after "bold"
// went out of "**bold**" is not bold, and the source has no "****".
// The new text comes first, in the styles that end in the range, as
// text that is typed at the place where the range starts would be.
//
// Spaces that the edit puts on the inner side of a mark of bold text
// and the like go to its outer side: Markdown reads "** more**" as no
// bold text. They are the same spaces of the text, with no style.
//
// `caret`: the offset of the place of the range in the source that the
// edit gives, after the new text. Memory of `allocator`, the caller's
// to delete.
range_edit :: proc(pairs: []Pair, source: []u8, from, to: int, text: string, allocator := context.allocator) -> (edit: Edit, caret: int) {
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
	// The marks that stay, in the order of the source: the ones that
	// end a style, then the ones that start one (styles do not cross).
	Mark :: struct {
		start, end: int,
		tight:      bool,
	}
	closes := make([dynamic]Mark, context.temp_allocator)
	opens := make([dynamic]Mark, context.temp_allocator)
	for pair in pairs {
		if pair.close < 0 {
			continue
		}
		open_in := pair.open >= start && pair.open_end <= end
		close_in := pair.close >= start && pair.close_end <= end
		if open_in && !close_in && pair.open_end > pair.open {
			append(&opens, Mark{pair.open, pair.open_end, pair.tight})
		} else if close_in && !open_in && pair.close_end > pair.close {
			append(&closes, Mark{pair.close, pair.close_end, pair.tight})
		}
	}
	by_start :: proc(a, b: Mark) -> bool {return a.start < b.start}
	slice.sort_by(closes[:], by_start)
	slice.sort_by(opens[:], by_start)
	space :: proc(ch: u8) -> bool {return ch == ' ' || ch == '\t'}
	// Spaces before the range, with a mark that ends a style right
	// after them now: one that stays, or the first one after the range
	// when nothing comes between. They go after the marks that end
	// there.
	before := 0
	if len(text) == 0 {
		tail := end
		if len(closes) == 0 && len(opens) == 0 {
			for found := true; found; {
				found = false
				for pair in pairs {
					if pair.close == tail && pair.close_end > tail && pair.open < start {
						append(&closes, Mark{pair.close, pair.close_end, pair.tight})
						tail, found = pair.close_end, true
					}
				}
			}
		}
		if len(closes) > 0 && closes[0].tight {
			for start - before > 0 && space(source[start - before - 1]) {
				before += 1
			}
		}
		if before > 0 {
			end = tail
		} else {
			for len(closes) > 0 && closes[len(closes) - 1].start >= end {
				pop(&closes)
			}
		}
	}
	// Spaces after the range, with a mark that starts a style right
	// before them now. They go before the marks that start there.
	after := 0
	head := start - before
	if len(opens) == 0 && len(closes) == 0 && len(text) == 0 {
		for found := true; found; {
			found = false
			for pair in pairs {
				if pair.close >= 0 && pair.open_end == head && pair.open < head && pair.close >= end {
					inject_at(&opens, 0, Mark{pair.open, pair.open_end, pair.tight})
					head, found = pair.open, true
				}
			}
		}
	}
	if len(opens) > 0 && opens[len(opens) - 1].tight {
		for end + after < len(source) && space(source[end + after]) {
			after += 1
		}
	}
	if after == 0 {
		for len(opens) > 0 && opens[0].end <= start - before {
			ordered_remove(&opens, 0)
		}
		head = start - before
	}
	out := make([dynamic]u8, 0, len(text) + before + after + 8, allocator)
	append(&out, text)
	for mark in closes {
		append(&out, ..source[mark.start:mark.end])
	}
	append(&out, ..source[start - before:start])
	caret = head + len(out)
	append(&out, ..source[end:end + after])
	for mark in opens {
		append(&out, ..source[mark.start:mark.end])
	}
	return {head, end + after, string(out[:])}, caret
}

// The range of the source of the lines that two offsets are in, with
// the line break of the last one: what goes out when the lines go.
lines_range :: proc(source: []u8, from, to: int) -> (start, end: int) {
	start = line_start(source, clamp(from, 0, len(source)))
	_, end = line_at(source, line_start(source, clamp(to, 0, len(source))))
	return
}

// The edit that takes the text between two offsets of the source out of
// a document and puts `text` in its place (`range_edit`), for two
// offsets that are places of a caret, `from` not after `to`. The text
// of the block of `to` that stays goes on in the block of `from`, which
// keeps its kind; the blocks between them go.
//
// False for a range that has no such edit yet: one with an end in code
// or in a table and the other end in another block (the rest of code
// is no text of a paragraph), but when the range has all of the text of
// its blocks, which then go with their lines; and one from a cell of a
// table to another one.
replace_range :: proc(doc: ^Document, from, to: int, text: string, allocator := context.allocator) -> (edit: Edit, caret: int, ok: bool) {
	if doc.count == 0 || from < 0 || to < from || to > len(doc.source) {
		return
	}
	first, last := block_at_offset(doc, from), block_at_offset(doc, to)
	pairs := make([dynamic]Pair, context.temp_allocator)
	places := block_map(doc, first, &pairs)
	defer delete(places)
	a, b := block_at(doc, first), block_at(doc, last)
	if first != last {
		pairs_last := make([dynamic]Pair, context.temp_allocator)
		places_last := block_map(doc, last, &pairs_last)
		defer delete(places_last)
		append(&pairs, ..pairs_last[:])
		verbatim :: proc(b: ^Block) -> bool {return b.kind == .Code || b.kind == .Table}
		if verbatim(a) || verbatim(b) {
			// All of the text of the blocks: from the start of the first
			// text or before it, to the end of the last text or after it.
			texts := block_texts(b)
			head, has_head := place_of(doc, places[:], {first, 0, 0})
			tail, has_tail := len(doc.source), true
			if len(texts) > 0 {
				tail, has_tail = place_of(doc, places_last[:], {last, len(texts) - 1, len(texts[len(texts) - 1].bytes)})
			}
			if (has_head && from > head) || (has_tail && to < tail) {
				return
			}
			start := first == 0 ? 0 : block_start(doc, first)
			_, end := block_source(doc, last)
			out := make([dynamic]u8, 0, len(text) + 4, allocator)
			append(&out, text)
			if len(text) > 0 && end < len(doc.source) {
				// The text is a paragraph of its own before what comes
				// after the blocks.
				nl := line_ending(doc.source)
				append(&out, nl)
				append(&out, nl)
			}
			return {start, end, string(out[:])}, start + len(text), true
		}
	} else if a.kind == .Table && address_in(places[:], first, from).cell != address_in(places[:], first, to).cell {
		return
	}
	// From an empty paragraph: what comes in its place is a paragraph of
	// its own, at the line of the empty one (`empty_text`). Not for
	// empty lines only that go: the lines after them are as they were.
	lead := ""
	if empty_at(doc, first, from) > 0 && (len(text) > 0 || first != last) {
		lead = line_ending(doc.source)
	}
	if lead == "" {
		edit, caret = range_edit(pairs[:], doc.source, from, to, text, allocator)
		return edit, caret, true
	}
	led := make([]u8, len(lead) + len(text), context.temp_allocator)
	copy(led, lead)
	copy(led[len(lead):], text)
	edit, caret = range_edit(pairs[:], doc.source, from, to, string(led), allocator)
	return edit, caret, true
}
