package document

import "core:bytes"
import "core:slice"
import "core:strings"

// A change of the source of a document: the bytes from `start` to `end`
// become `text`. A text that is put in has `start == end`; a text that is
// taken out has an empty `text`.
Edit :: struct {
	start, end: int,
	text:       string,
}

// The smallest edit that makes a source the text `now`: what is between
// the bytes that the two have in common at their start and at their end.
// It can start or end in the middle of a character.
edit_between :: proc(source: []u8, now: string) -> (e: Edit) {
	head := slice.prefix_length(source, transmute([]u8)now)
	// Not into the bytes of the start: text that is there two times
	// counts one time.
	rest := min(len(source), len(now)) - head
	tail := 0
	#no_bounds_check for tail < rest && source[len(source) - 1 - tail] == now[len(now) - 1 - tail] {
		tail += 1
	}
	return {head, len(source) - tail, now[head:len(now) - tail]}
}

// True for an edit that changes nothing.
edit_is_empty :: proc(e: Edit) -> bool {
	return e.start == e.end && len(e.text) == 0
}

// A source with an edit, in new memory. The range of the edit is cut to
// the source.
edited :: proc(source: []u8, e: Edit) -> []u8 {
	start := clamp(e.start, 0, len(source))
	end := clamp(e.end, start, len(source))
	out := make([]u8, start + len(e.text) + len(source) - end)
	copy(out, source[:start])
	copy(out[start:], e.text)
	copy(out[start + len(e.text):], source[end:])
	return out
}

// A change of a document, as the range of its blocks that became other
// blocks. The blocks before the range and after it are the same for a
// layout as before, and they are at the address they had when their part
// was not made again.
Change :: struct {
	first:         int, // the number of the first block of the range
	removed:       int, // how many blocks of the document before were in it
	added:         int, // how many blocks are in it now
	count:         int, // the blocks of the document now
	// The parts of the document that were made again: `parts_removed`
	// parts from `part_first` on went, and `parts_added` came for them.
	// None when the range has as many blocks as before: each of them
	// is then at the place in memory of the block that it is for.
	part_first:    int,
	parts_removed: int,
	parts_added:   int,
	// For a change of one block to one block with a text (no table): how
	// many bytes of its text are the same at the start and at the end,
	// and how much longer the text is. An address in those bytes is an
	// address of the same text after the change (`moved`).
	text_head, text_tail: int,
	text_grew:     int,
	text_was:      int, // the bytes of the text before
}

// The address that an address of the document before the change has now.
// One in the range that changed has no text that is its own any more: it
// goes to the start of the range (or to the last block, for a range at
// the end), and `same` is false.
moved :: proc(change: Change, at: Address) -> (now: Address, same: bool) {
	now = at
	if at.block < change.first {
		return now, true
	}
	if at.block >= change.first + change.removed {
		now.block += change.added - change.removed
		return now, true
	}
	// In a block that got other text at its place: text before the
	// change and text after it are the reader's text still.
	if change.removed == 1 && change.added == 1 && at.cell == 0 && change.text_head + change.text_tail > 0 {
		// An address right where text came in is of the text after it:
		// the line that was there is lower now, and a caret is after
		// what it typed. So the text at the end counts first.
		if at.byte >= change.text_was - change.text_tail {
			now.byte += change.text_grew
			return now, true
		}
		if at.byte <= change.text_head {
			return now, true
		}
	}
	return {max(min(change.first, change.count - 1), 0), 0, 0}, false
}

@(private)
text_equal :: proc(a, b: ^Text) -> bool {
	if string(a.bytes[:]) != string(b.bytes[:]) || len(a.spans) != len(b.spans) {
		return false
	}
	for span, i in a.spans {
		other := b.spans[i]
		// Not the number of the link: that is its place in the list of
		// links of a document, and says nothing to a layout.
		if span.start != other.start || span.end != other.end || span.style != other.style {
			return false
		}
	}
	return true
}

// True when a layout gives two blocks the same records: the two have the
// same shape and the same texts. What else a block says (its place in the
// source, its task mark, its state in a checked item) is not read by a
// layout.
@(private)
layout_equal :: proc(a, b: ^Block) -> bool {
	if a.shape != b.shape ||
	   a.language != b.language ||
	   len(a.cells) != len(b.cells) ||
	   !slice.equal(a.aligns[:], b.aligns[:]) {
		return false
	}
	for &cell, i in a.cells {
		if !text_equal(&cell, &b.cells[i]) {
			return false
		}
	}
	return text_equal(&a.text, &b.text)
}

// Gives a block of the document the content of an equal block of the new
// document, at the address it has: the block and each of its cells stay
// where a layout knows them. The new block gets the old content, which
// goes with the new document.
@(private)
adopt :: proc(old, fresh: ^Block) {
	for &cell, i in old.cells {
		cell, fresh.cells[i] = fresh.cells[i], cell
	}
	old^, fresh^ = fresh^, old^
	// The cells stay in the array of the old block.
	old.cells, fresh.cells = fresh.cells, old.cells
}

// A walk over the blocks of a document, from one end.
@(private)
Walk :: struct {
	doc:        ^Document,
	part, slot: int,
	step:       int, // 1 from the first block on, -1 from the last one back
}

@(private)
walk :: proc(doc: ^Document, step: int) -> Walk {
	if step > 0 || len(doc.parts) == 0 {
		return {doc, 0, 0, step}
	}
	last := len(doc.parts) - 1
	return {doc, last, doc.parts[last].count - 1, step}
}

// The block that the walk is at. Nil at the end of it.
@(private)
walk_block :: proc(w: ^Walk) -> ^Block {
	if w.part < 0 || w.part >= len(w.doc.parts) {
		return nil
	}
	return &w.doc.parts[w.part].blocks[w.slot]
}

@(private)
walk_next :: proc(w: ^Walk) {
	w.slot += w.step
	if w.slot >= 0 && w.slot < w.doc.parts[w.part].count {
		return
	}
	w.part += w.step
	if w.part >= 0 && w.part < len(w.doc.parts) {
		w.slot = w.step > 0 ? 0 : w.doc.parts[w.part].count - 1
	}
}

// A walk that starts at the block with a number.
@(private)
walk_from :: proc(doc: ^Document, block, step: int) -> Walk {
	if block < 0 || block >= doc.count {
		return {doc, -1, 0, step}
	}
	part, slot := locate(doc, block)
	return {doc, part, slot, step}
}

// True for a block where a parse of a piece of the source can start: it
// is in no list and no quote, or it is the first block of one that is
// in none, and it is not in the paragraph of a definition of a link.
// The lines before it do not change what it and the text after it are.
@(private)
starts_piece :: proc(doc: ^Document, block: int) -> bool {
	if block > 0 && under_def(doc, block_start(doc, block)) {
		return false
	}
	b := block_at(doc, block)
	if b.list_depth == 0 && b.quote_depth == 0 {
		return true
	}
	if block == 0 {
		return true
	}
	before := block_at(doc, block - 1)
	return before.list_depth == 0 && before.quote_depth == 0
}

// True when the line before an offset is the last line of a definition
// of a link. A block that starts there is the rest of the paragraph
// that the definition was in: with the definition, a line with a deep
// indent is text of the paragraph or a rule; with no definition before
// it, the same line is code.
@(private)
under_def :: proc(doc: ^Document, offset: int) -> bool {
	// The last definition that starts before the offset.
	low, high := 0, len(doc.defs)
	for low < high {
		mid := (low + high) / 2
		if doc.defs[mid].start < offset {
			low = mid + 1
		} else {
			high = mid
		}
	}
	if low == 0 {
		return false
	}
	end := doc.defs[low - 1].end
	return end <= offset && count_lines(doc.source, end, offset) <= 1
}

// How many blocks after an edit are parsed again to see that they are
// the blocks of before: then the text after them is as it was too.
GUARD_BLOCKS :: 2

// An edit that is ready to be made: all that reads the document and
// takes time is done, with no change to the document. See `prepare`.
Pending :: struct {
	edit:         Edit, // cut to the source; its text is not kept
	bytes:        int, // how much longer the source gets
	source:       []u8, // the new source; after `commit`, the old one
	// The first `added` blocks of `fresh` take the place of `count`
	// blocks from `first` on. The blocks of `fresh` after them were
	// parsed only to be compared; the document keeps its own.
	fresh:        Document,
	added:        int,
	first, count: int,
	// Where the text that `fresh` was parsed from starts in the new
	// source. Before the source, when definitions of links from before
	// the piece come first in that text.
	base:         int,
	// For a piece, `fresh` has the definitions of links of the piece,
	// where the new source has them: as many as the document has from
	// `defs_first` on, with the same text.
	defs_first:   int,
	all:          bool, // all of the source was parsed
}

// Makes ready an edit of the source of a document, and changes nothing:
// a caller can do this beside readers of the document, and then make the
// change with `commit` in a short time. The caller ends it with `discard`.
//
// Only the blocks around the edit are parsed when that gives the same
// document as a parse of all of the new source. The piece starts at a
// block that is in no list and no quote, before the edit, and ends some
// blocks after the edit. Those last blocks must come out as they were,
// at their place: then nothing that the edit opened (a code fence, a
// list) reaches into the text after the piece. If they do not, or the
// edit changes the definition of a link, all of the source is parsed.
prepare :: proc(doc: ^Document, edit: Edit) -> (p: Pending) {
	p.edit.start = clamp(edit.start, 0, len(doc.source))
	p.edit.end = clamp(edit.end, p.edit.start, len(doc.source))
	p.bytes = len(edit.text) - (p.edit.end - p.edit.start)
	p.source = edited(doc.source, {p.edit.start, p.edit.end, edit.text})
	// The list of links gets the links of each edit and loses none; a
	// parse of all makes it small again.
	// A table that has all of its rows keeps them in a source of the new
	// size.
	tables := !doc.cells_cut && doc.cells_most <= MIN_TABLE_CELLS + len(p.source)
	if doc.count > 0 && tables && !doc.defs_marked && !doc.defs_cut && len(doc.links) <= 2 * doc.links_parsed + LINKS_SLACK {
		if prepare_piece(doc, &p) {
			return
		}
	}
	p.fresh = parse_owned(p.source)
	// The document takes the source from `p`.
	p.fresh.source = nil
	p.first, p.count, p.added, p.base, p.all = 0, doc.count, p.fresh.count, 0, true
	return
}

// How many links more than two times the links of the last parse of all
// the list of links can have before an edit is a parse of all.
LINKS_SLACK :: 256

// The first word of each name in brackets in a text, as numbers
// (`word_number`). `any`: a name can be one that these do not cover, so
// each definition counts.
@(private)
Names :: struct {
	words: [dynamic]u64,
	any:   bool,
}

@(private)
names_in :: proc(text: []u8) -> (names: Names) {
	for rest := text; len(rest) > 0; {
		open := bytes.index_byte(rest, '[')
		if open < 0 {
			break
		}
		at := open + 1
		for at < len(rest) && (rest[at] == ' ' || rest[at] == '\t') {
			at += 1
		}
		first := at
		for at < len(rest) && !ends_word(rest[at]) {
			at += 1
		}
		// A name that goes on in the next line can have the marks of a
		// quote or a list before its first word.
		names.any ||= first == at && at < len(rest) && (rest[at] == '\n' || rest[at] == '\r')
		names.any ||= !plain_word(rest[first:at])
		append(&names.words, word_number(rest[first:at]))
		rest = rest[open + 1:]
	}
	// For some names only; a text with many is rare.
	names.any ||= len(names.words) > 64
	return
}

// The text that is parsed for a piece of the source: the piece, with the
// definitions of links of the rest of the document that it can use,
// before it and after it as they are in the source (the order says which
// of two with one name counts), and an empty line between. `piece` is
// the piece as it is now; `start` and `old_end` are where it is in the
// source of the document. A link that a definition gives its target has
// the name of the definition in brackets, so a definition counts when the
// first word of its name is the first word in a pair of brackets of the
// piece.
//
// Of the definitions of the document, `before` are before the piece and
// `inside` in it; `led` and `trailed` are in the text before the piece
// and after it; the piece starts at `lead` in the text.
@(private)
piece_text :: proc(doc: ^Document, piece: []u8, start, old_end: int) -> (text: [dynamic]u8, before, inside, led, trailed, lead: int) {
	// A definition is in the lines of one block or between two, so none
	// is over an end of the piece.
	for before < len(doc.defs) && doc.defs[before].end <= start {
		before += 1
	}
	for before + inside < len(doc.defs) && doc.defs[before + inside].start < old_end {
		inside += 1
	}
	text = make([dynamic]u8, 0, len(piece) + 64)
	if len(doc.defs) == inside {
		append(&text, ..piece)
		return
	}
	names := names_in(piece)
	defer delete(names.words)
	used :: proc(names: Names, def: Def) -> bool {
		return len(names.words) > 0 && (names.any || def.always || slice.contains(names.words[:], def.word))
	}
	for def in doc.defs[:before] {
		if used(names, def) {
			append(&text, ..doc.source[def.start:def.end])
			append(&text, '\n')
			led += 1
		}
	}
	if led > 0 {
		append(&text, '\n')
	}
	lead = len(text)
	append(&text, ..piece)
	for def in doc.defs[before + inside:] {
		if used(names, def) {
			if trailed == 0 {
				append(&text, "\n\n")
			}
			append(&text, ..doc.source[def.start:def.end])
			append(&text, '\n')
			trailed += 1
		}
	}
	return
}

// The part of `prepare` that parses a piece. False when the piece does
// not give the document of the new source.
@(private)
prepare_piece :: proc(doc: ^Document, p: ^Pending) -> bool {
	// The piece starts at the last block before the edit where a parse
	// can start. An edit in the first line of that block can make the
	// line a part of the block before it (a line under a paragraph makes
	// it a heading), so the piece then starts one such block earlier.
	first := block_at_offset(doc, p.edit.start)
	for !starts_piece(doc, first) {
		first -= 1
	}
	if first > 0 {
		line := block_start(doc, first)
		line_end := strings.index_any(string(doc.source[line:]), "\r\n")
		if line_end < 0 || p.edit.start <= line + line_end {
			first -= 1
			for !starts_piece(doc, first) {
				first -= 1
			}
		}
	}
	// It ends after the blocks that the edit is in, where the next such
	// block starts, and then has the blocks that are compared.
	last := block_at_offset(doc, p.edit.end) + 1
	for last < doc.count && !starts_piece(doc, last) {
		last += 1
	}
	guard := min(GUARD_BLOCKS, doc.count - last)
	// The blocks that are compared show that they are as they were, not
	// that the lists around them are. A list that the edit makes can go
	// on in a list after it, and then the numbers of later items are
	// others. Only the first block of a list says that its list starts
	// there, so no other block in a list is compared.
	if guard > 0 {
		after := block_at(doc, last)
		if after.list_depth > 0 && after.spacing != .List_Start {
			return false
		}
	}
	end := last + guard
	p.first, p.count = first, last - first
	start := first == 0 ? 0 : block_start(doc, first)
	old_end := end < doc.count ? block_start(doc, end) : len(doc.source)
	piece := p.source[start:old_end + p.bytes]

	text, before, inside, led, trailed, lead := piece_text(doc, piece, start, old_end)
	p.base = start - lead
	p.fresh = parse_piece(text[:], doc.items, len(p.source), end = lead + len(piece), followed = end < doc.count)
	fresh := &p.fresh
	p.added = fresh.count - guard
	// The definitions came out as definitions, and the ones of the piece
	// are the ones it had, with the same text: an edit that changes one
	// changes text at other places. Each block is in the piece.
	ok := len(fresh.defs) == led + inside + trailed && fresh.count >= guard
	for i := 0; ok && i < inside; i += 1 {
		old, new := doc.defs[before + i], fresh.defs[led + i]
		ok = new.start >= lead && new.end <= lead + len(piece) && string(doc.source[old.start:old.end]) == string(text[new.start:new.end])
	}
	if ok && fresh.count > 0 {
		ok = block_start(fresh, 0) >= lead && block_start(fresh, fresh.count - 1) < lead + len(piece)
	}
	// The limit of the parser for the uses of definitions is of the
	// text that it parses. Each use of the piece had room in the limit
	// of the piece, and a parse of all of the source has room for each
	// use of the document: for the ones so far, the ones of the piece,
	// and one more, whichever definition it is of.
	ok &&= !fresh.defs_cut && doc.defs_used + fresh.defs_used + doc.def_longest < defs_limit(len(p.source))
	// The blocks after the edit, as they were, at their place.
	for i := 0; ok && i < guard; i += 1 {
		old, new := last + i, fresh.count - guard + i
		ok = layout_equal(block_at(doc, old), block_at(fresh, new)) && block_start(doc, old) + p.bytes == p.base + block_start(fresh, new)
	}
	if !ok {
		destroy(fresh)
		return false
	}
	// Of the definitions, the ones of the piece stay, where the new
	// source has them.
	p.defs_first = before
	remove_range(&fresh.defs, led + inside, len(fresh.defs))
	remove_range(&fresh.defs, 0, led)
	for &def in fresh.defs {
		def.start += p.base
		def.end += p.base
	}
	return true
}

// Frees what is left of an edit: before `commit`, the new source and the
// new blocks; after it, the old ones.
discard :: proc(p: ^Pending) {
	destroy(&p.fresh)
	delete(p.source)
	p^ = {}
}

// Makes an edit of the source of a document that `prepare` made ready,
// with no change to the document between the two, and says which range
// of its blocks changed. The blocks at the start and at the end of what
// was parsed that are the same for a layout keep their place in memory,
// when the range is not in their part; each block that was not parsed
// stays as it is.
commit :: proc(doc: ^Document, p: ^Pending) -> (change: Change) {
	fresh := &p.fresh
	end := p.first + p.count
	// The lines that the source gets. A line ends at a byte or not by
	// that byte and the next one, so the byte before the edit counts.
	lines :=
		count_lines(p.source, p.edit.start - 1, p.edit.end + p.bytes) -
		count_lines(doc.source, p.edit.start - 1, p.edit.end)

	// The parts that can get other blocks: for the time of the change,
	// the offsets of their blocks count from the start of the new source.
	// Each block after the edit is that much later; for the parts after
	// these, that is one number.
	low, high := 0, -1
	if doc.count > 0 {
		low, _ = locate(doc, max(p.first - 1, 0))
		high, _ = locate(doc, min(end, doc.count - 1))
	}
	for part, i in doc.parts[low:high + 1] {
		for &b, slot in part_blocks(part) {
			move_block(&b, part.source + (doc.starts[low + i] + slot >= end ? p.bytes : 0))
		}
	}
	for part in doc.parts[high + 1:] {
		part.source += p.bytes
		part.line += lines
	}
	for part in fresh.parts {
		for &b in part_blocks(part) {
			move_block(&b, p.base + part.source)
		}
	}

	// The links of the new blocks go to the end of the list.
	if p.all {
		doc.links, fresh.links = fresh.links, doc.links
		doc.links_parsed = len(doc.links)
		doc.defs, fresh.defs = fresh.defs, doc.defs
		doc.defs_marked, doc.defs_cut = fresh.defs_marked, fresh.defs_cut
		doc.defs_used, doc.def_longest = fresh.defs_used, fresh.def_longest
		doc.cells_most, doc.cells_cut = fresh.cells_most, fresh.cells_cut
	} else {
		doc.cells_most = max(doc.cells_most, fresh.cells_most)
		doc.cells_cut ||= fresh.cells_cut
		for part in fresh.parts {
			for &b in part_blocks(part) {
				for &t in block_texts(&b) {
					for &span in t.spans {
						span.link += span.link > 0 ? len(doc.links) : 0
					}
				}
			}
		}
		append(&doc.links, ..fresh.links[:])
		clear(&fresh.links)
		// The definitions of the piece are where the new source has
		// them; the ones after it are as much later as the source is
		// longer.
		copy(doc.defs[p.defs_first:], fresh.defs[:])
		for &def in doc.defs[p.defs_first + len(fresh.defs):] {
			def.start += p.bytes
			def.end += p.bytes
		}
		doc.defs_used += fresh.defs_used
	}
	doc.items = fresh.items
	doc.source, p.source = p.source, doc.source

	// The same blocks at the start, and at the end of what is left. Each
	// is taken over as it is found.
	shortest := min(p.count, p.added)
	head, tail := 0, 0
	for old, new := walk_from(doc, p.first, 1), walk(fresh, 1); head < shortest; head += 1 {
		a, b := walk_block(&old), walk_block(&new)
		if !layout_equal(a, b) {
			break
		}
		adopt(a, b)
		walk_next(&old)
		walk_next(&new)
	}
	for old, new := walk_from(doc, end - 1, -1), walk_from(fresh, p.added - 1, -1); tail < shortest - head; tail += 1 {
		a, b := walk_block(&old), walk_block(&new)
		if !layout_equal(a, b) {
			break
		}
		adopt(a, b)
		walk_next(&old)
		walk_next(&new)
	}
	change = {
		first   = p.first + head,
		removed = p.count - head - tail,
		added   = p.added - head - tail,
		count   = doc.count - p.count + p.added,
	}
	if change.removed == change.added {
		// As many blocks as before: each takes the place of the block
		// that was there, and no other block of a part moves. A layout
		// keeps its records of the other blocks of the part.
		old, new := walk_from(doc, change.first, 1), walk_from(fresh, head, 1)
		for _ in 0 ..< change.added {
			a, b := walk_block(&old), walk_block(&new)
			if change.added == 1 && a.kind != .Table && b.kind != .Table {
				before, after := a.text.bytes[:], b.text.bytes[:]
				change.text_head = slice.prefix_length(before, after)
				rest := min(len(before), len(after)) - change.text_head
				for change.text_tail < rest && before[len(before) - 1 - change.text_tail] == after[len(after) - 1 - change.text_tail] {
					change.text_tail += 1
				}
				change.text_was, change.text_grew = len(before), len(after) - len(before)
			}
			block_destroy(a)
			a^, b^ = b^, {}
			walk_next(&old)
			walk_next(&new)
		}
	} else {
		rebuild(doc, fresh, head, &change)
	}
	// The offsets count from the parts again.
	anchor(doc, low, high + change.parts_added - change.parts_removed)
	return
}

// Makes an edit of the source of a document in one step. For a caller
// with no readers beside it.
apply :: proc(doc: ^Document, edit: Edit) -> Change {
	p := prepare(doc, edit)
	defer discard(&p)
	return commit(doc, &p)
}

// Puts the blocks `change.added` of `fresh`, from the block `from` of it
// on, in the place of the blocks `change.removed` of `doc`. The parts that have a block of the range, or
// the block before it or after it, are made again; each other part stays.
@(private)
rebuild :: proc(doc, fresh: ^Document, from: int, change: ^Change) {
	end := change.first + change.removed
	// The parts from the one of the first block of the range to the one
	// of the first block after it go. For a range at the end, that is the
	// last part two times. Of the first one the blocks before the range
	// stay, of the last one the blocks from the end of the range on.
	first, last, keep_before, keep_from := 0, -1, 0, 0
	if doc.count > 0 {
		first, _ = locate(doc, min(change.first, doc.count - 1))
		last, _ = locate(doc, min(end, doc.count - 1))
		keep_before = change.first - doc.starts[first]
		keep_from = end - doc.starts[last]
	}
	removed := last - first + 1

	// The blocks of the new parts, in order. They move out of the parts
	// that go and out of the new document.
	blocks := make([dynamic]Block, 0, keep_before + change.added + PART_BLOCKS, context.temp_allocator)
	if removed > 0 {
		append(&blocks, ..doc.parts[first].blocks[:keep_before])
	}
	for i in 0 ..< change.added {
		b := block_at(fresh, from + i)
		append(&blocks, b^)
		b^ = {}
	}
	if removed > 0 {
		append(&blocks, ..doc.parts[last].blocks[keep_from:doc.parts[last].count])
	}
	// The blocks of the range go with their parts.
	for p in first ..= last {
		part := doc.parts[p]
		from := p == first ? keep_before : 0
		to := p == last ? keep_from : part.count
		for &b in part.blocks[from:to] {
			block_destroy(&b)
		}
		free(part)
	}

	added := (len(blocks) + PART_BLOCKS - 1) / PART_BLOCKS
	parts := make([dynamic]^Part, 0, len(doc.parts) - removed + added)
	append(&parts, ..doc.parts[:first])
	for rest := blocks[:]; len(rest) > 0; {
		part := new(Part)
		part.count = min(len(rest), PART_BLOCKS)
		copy(part.blocks[:], rest[:part.count])
		rest = rest[part.count:]
		append(&parts, part)
	}
	append(&parts, ..doc.parts[first + removed:])
	delete(doc.parts)
	doc.parts = parts

	clear(&doc.starts)
	doc.count = 0
	for part in doc.parts {
		append(&doc.starts, doc.count)
		doc.count += part.count
	}
	change.part_first, change.parts_removed, change.parts_added = first, removed, added
}
