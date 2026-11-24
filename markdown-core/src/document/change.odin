package document

// A change of a document, as the range of its blocks that became other
// blocks. The blocks before the range and after it are the same for a
// layout as before, and they are at the address they had when their part
// was not made again.
Change :: struct {
	first:         int, // the number of the first block of the range
	removed:       int, // how many blocks of the document before were in it
	added:         int, // how many blocks are in it now
	// The parts of the document that were made again: `parts_removed`
	// parts from `part_first` on went, and `parts_added` came for them.
	part_first:    int,
	parts_removed: int,
	parts_added:   int,
}

// The address that an address of the document before the change has now.
// False for an address in the range that changed.
moved :: proc(change: Change, at: Address) -> (now: Address, ok: bool) {
	now = at
	if at.block < change.first {
		return now, true
	}
	if at.block < change.first + change.removed {
		return now, false
	}
	now.block += change.added - change.removed
	return now, true
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

// True when a layout gives two blocks the same records: all that a block
// says but the line of its task mark, the number of its list item, and
// its state in a checked item, which are read when the page is drawn.
@(private)
layout_equal :: proc(a, b: ^Block) -> bool {
	if a.kind != b.kind ||
	   a.level != b.level ||
	   a.language != b.language ||
	   a.marker != b.marker ||
	   a.number != b.number ||
	   a.spacing != b.spacing ||
	   a.list_depth != b.list_depth ||
	   a.quote_depth != b.quote_depth ||
	   a.columns != b.columns ||
	   len(a.cells) != len(b.cells) ||
	   len(a.aligns) != len(b.aligns) {
		return false
	}
	for align, i in a.aligns {
		if align != b.aligns[i] {
			return false
		}
	}
	for &cell, i in a.cells {
		if !text_equal(&cell, &b.cells[i]) {
			return false
		}
	}
	return text_equal(&a.text, &b.text)
}

@(private)
block_destroy :: proc(b: ^Block) {
	text_destroy(&b.text)
	delete(b.language)
	for &cell in b.cells {
		text_destroy(&cell)
	}
	delete(b.cells)
	delete(b.aligns)
	b^ = {}
}

// Gives a block of the document the content of an equal block of the new
// document, at the address it has: the block and each of its cells stay
// where a layout knows them. `fresh` is empty after it.
@(private)
adopt :: proc(old, fresh: ^Block) {
	// The cells stay in the array of the old block.
	cells := old.cells
	for &cell, i in cells {
		text_destroy(&cell)
		cell = fresh.cells[i]
	}
	delete(fresh.cells)
	text_destroy(&old.text)
	delete(old.language)
	delete(old.aligns)
	old^ = fresh^
	old.cells = cells
	fresh^ = {}
}

// Makes `doc` the document `fresh`, and says which range of its blocks
// changed. The blocks at the start and at the end that are the same for a
// layout keep their place in memory, when the range is not in their part.
// `fresh` is used up: it is empty after the call.
replace :: proc(doc, fresh: ^Document) -> (change: Change) {
	before, after := doc.count, fresh.count
	// The same blocks at the start, and at the end of what is left.
	head := 0
	for head < min(before, after) && layout_equal(block_at(doc, head), block_at(fresh, head)) {
		head += 1
	}
	tail := 0
	for tail < min(before, after) - head && layout_equal(block_at(doc, before - 1 - tail), block_at(fresh, after - 1 - tail)) {
		tail += 1
	}
	for i in 0 ..< head {
		adopt(block_at(doc, i), block_at(fresh, i))
	}
	for i in 0 ..< tail {
		adopt(block_at(doc, before - 1 - i), block_at(fresh, after - 1 - i))
	}
	for link in doc.links {
		delete(link)
	}
	delete(doc.links)
	doc.links, fresh.links = fresh.links, nil

	change = {first = head, removed = before - head - tail, added = after - head - tail}
	if change.removed > 0 || change.added > 0 {
		rebuild(doc, fresh, &change)
	}
	destroy(fresh)
	return
}

// Puts the blocks `change.added` of `fresh` in the place of the blocks
// `change.removed` of `doc`. The parts that have a block of the range, or
// the block before it or after it, are made again; each other part stays.
@(private)
rebuild :: proc(doc, fresh: ^Document, change: ^Change) {
	end := change.first + change.removed
	// The part of the first block of the range, or of the block before it
	// for a range at the end. The blocks of that part before the range
	// stay.
	first, keep_before := 0, 0
	if change.first < doc.count {
		first, keep_before = locate(doc, change.first)
	} else if len(doc.parts) > 0 {
		first = len(doc.parts) - 1
		keep_before = doc.parts[first].count
	}
	// The part of the first block after the range, whose blocks from that
	// one on stay. With no block after the range: the last part.
	last, keep_from := len(doc.parts) - 1, 0
	if end < doc.count {
		last, keep_from = locate(doc, end)
	} else if last >= 0 {
		keep_from = doc.parts[last].count
	}

	// The blocks of the new parts, in order: they move out of the parts
	// that go.
	blocks := make([dynamic]Block, 0, keep_before + change.added + PART_BLOCKS, context.temp_allocator)
	if len(doc.parts) > 0 {
		append(&blocks, ..doc.parts[first].blocks[:keep_before])
	}
	for i in 0 ..< change.added {
		b := block_at(fresh, change.first + i)
		append(&blocks, b^)
		b^ = {}
	}
	if last >= 0 {
		append(&blocks, ..doc.parts[last].blocks[keep_from:doc.parts[last].count])
	}
	// The blocks of the range go with their parts.
	removed := len(doc.parts) > 0 ? last - first + 1 : 0
	for p in first ..< first + removed {
		part := doc.parts[p]
		from := p == first ? keep_before : 0
		to := p == last ? keep_from : part.count
		for &b in part.blocks[from:max(from, to)] {
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
