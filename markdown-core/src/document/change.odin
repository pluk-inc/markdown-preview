package document

import "core:slice"

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
	part_first:    int,
	parts_removed: int,
	parts_added:   int,
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

// Makes `doc` the document `fresh`, and says which range of its blocks
// changed. The blocks at the start and at the end that are the same for a
// layout keep their place in memory, when the range is not in their part.
// `fresh` holds what is left of the two documents after it; the caller
// destroys it.
replace :: proc(doc, fresh: ^Document) -> (change: Change) {
	before, after := doc.count, fresh.count
	// The same blocks at the start, and at the end of what is left. Each
	// is taken over as it is found.
	head, tail := 0, 0
	for old, new := walk(doc, 1), walk(fresh, 1); head < min(before, after); head += 1 {
		a, b := walk_block(&old), walk_block(&new)
		if !layout_equal(a, b) {
			break
		}
		adopt(a, b)
		walk_next(&old)
		walk_next(&new)
	}
	for old, new := walk(doc, -1), walk(fresh, -1); tail < min(before, after) - head; tail += 1 {
		a, b := walk_block(&old), walk_block(&new)
		if !layout_equal(a, b) {
			break
		}
		adopt(a, b)
		walk_next(&old)
		walk_next(&new)
	}
	doc.links, fresh.links = fresh.links, doc.links
	doc.source, fresh.source = fresh.source, doc.source

	change = {first = head, removed = before - head - tail, added = after - head - tail, count = after}
	if change.removed > 0 || change.added > 0 {
		rebuild(doc, fresh, &change)
	}
	return
}

// Puts the blocks `change.added` of `fresh` in the place of the blocks
// `change.removed` of `doc`. The parts that have a block of the range, or
// the block before it or after it, are made again; each other part stays.
@(private)
rebuild :: proc(doc, fresh: ^Document, change: ^Change) {
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
		b := block_at(fresh, change.first + i)
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
