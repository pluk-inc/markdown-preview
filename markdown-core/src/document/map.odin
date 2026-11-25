package document

import "core:strings"
import "core:unicode/utf8"

// Where the text of a block is in the source, and back. A document has
// the text of each block as a reader sees it: with no marks, a run of
// spaces as one space, an entity as its character. An editor puts text
// into the source, at the place of a caret that is in the text of a
// block. Nothing of this is kept in the document: it is made for one
// block when it is asked for, by a parse of the lines around that block
// with a note of where each piece of its text came from.

// The pieces of the text of a block with their places in the source, in
// the order of the text. The caller deletes the result.
block_map :: proc(doc: ^Document, block: int) -> (places: [dynamic]Place) {
	// From a block where a parse can start to the next such block.
	first := block
	for !starts_piece(doc, first) {
		first -= 1
	}
	last := block + 1
	for last < doc.count && !starts_piece(doc, last) {
		last += 1
	}
	start := first == 0 ? 0 : block_start(doc, first)
	end := last < doc.count ? block_start(doc, last) : len(doc.source)
	text, _, _, _, _, lead := piece_text(doc, doc.source[start:end], start, end)
	fresh := parse_piece(text[:], 0, len(doc.source), &places, block - first)
	// The line break at the end of a code block is no text of it.
	texts := block_texts(block_at(doc, block))
	for len(places) > 0 {
		place := places[len(places) - 1]
		if place.cell < len(texts) && place.text < len(texts[place.cell].bytes) {
			break
		}
		pop(&places)
	}
	place_made(places[:], text[:])
	destroy(&fresh)
	for &place in places {
		place.source += start - lead
	}
	return
}

// Gives each piece that the parser made its place in the source: what
// is between the pieces of the same text that are around it. A soft
// line break in a quote is the line break and the mark of the quote on
// the next line; an empty line of a code block is its line break. Of a
// run of made pieces, the spaces of an indent at its end are the bytes
// right before the text after them, and the line breaks have the rest,
// each to the end of its line and the last one all that is left.
@(private)
place_made :: proc(places: []Place, source: []u8) {
	// The start of the line break that ends before `at`, or `at`.
	break_before :: proc(source: []u8, at: int) -> int {
		for i := at - 1; i >= 0; i -= 1 {
			if source[i] == '\n' {
				return i > 0 && source[i - 1] == '\r' ? i - 1 : i
			}
			if source[i] == '\r' {
				return i
			}
		}
		return at
	}
	// The end of the line that `at` is in, after its line break; `limit`
	// when the line goes on to there.
	line_end :: proc(source: []u8, at, limit: int) -> int {
		for i in at ..< limit {
			if source[i] == '\n' {
				return i + 1
			}
			if source[i] == '\r' {
				return i + 1 < limit && source[i + 1] == '\n' ? i + 2 : i + 1
			}
		}
		return limit
	}
	for i := 0; i < len(places); {
		if !places[i].made {
			i += 1
			continue
		}
		cell := places[i].cell
		j := i
		for j < len(places) && places[j].made && places[j].cell == cell {
			j += 1
		}
		// What is around the run: the end of the text before it and the
		// start of the text after it, or -1.
		a, b := -1, -1
		if i > 0 && places[i - 1].cell == cell {
			a = places[i - 1].source + places[i - 1].source_len
		}
		if j < len(places) && places[j].cell == cell {
			b = places[j].source
		}
		breaks := 0
		for place in places[i:j] {
			breaks += int(place.line_break)
		}
		if a < 0 {
			// At the start of the text: as many line breaks back from
			// the text after it.
			a = max(b, 0)
			for _ in 0 ..< breaks {
				a = break_before(source, a)
			}
		}
		if b < 0 {
			// At the end of the text: as many lines on.
			b = a
			for _ in 0 ..< breaks {
				b = line_end(source, b, len(source))
			}
		}
		// The spaces of an indent, from the end.
		m := j
		for m > i && !places[m - 1].line_break {
			place := &places[m - 1]
			place.source = max(b - place.text_len, a)
			place.source_len = b - place.source
			place.whole = place.source_len != place.text_len
			b = place.source
			m -= 1
		}
		at := a
		for &place, n in places[i:m] {
			place.source = at
			place.source_len = i + n == m - 1 ? b - at : (place.line_break ? line_end(source, at, b) - at : 0)
			at += place.source_len
		}
		i = j
	}
}

// The offset in the source where text goes that is put in at an address
// of the text of a block: the end of the text before the address, so it
// is in the marks that the character before it is in (bold text that
// ends at the address gets the new text too). False when the address
// has no place: a table cell with no text (the source can have no room
// for one), a block with no text and no space after its mark.
place_of :: proc(doc: ^Document, places: []Place, at: Address) -> (offset: int, ok: bool) {
	// The last piece of the text of the cell that starts at the address
	// or before it.
	found := -1
	for place, i in places {
		if place.cell == at.cell && place.text <= at.byte {
			found = i
		}
	}
	if found < 0 {
		for place in places {
			if place.cell == at.cell {
				return place.source, true
			}
		}
		// A block with no text: after the space that ends its first
		// line ("- ", "# ").
		b := block_at(doc, at.block)
		if b.kind == .Table || b.kind == .Rule || b.kind == .Code {
			return
		}
		start := block_start(doc, at.block)
		line := strings.index_any(string(doc.source[start:]), "\r\n")
		end := line < 0 ? len(doc.source) : start + line
		if end > start && (doc.source[end - 1] == ' ' || doc.source[end - 1] == '\t') {
			return end, true
		}
		return
	}
	place := places[found]
	within := at.byte - place.text
	if within == 0 && found > 0 && places[found - 1].cell == at.cell {
		// At the start of a piece: the end of the piece before it.
		before := places[found - 1]
		return before.source + before.source_len, true
	}
	if within >= place.text_len {
		return place.source + place.source_len, true
	}
	return place.source + (place.whole ? 0 : within), true
}

// The range of the source of the character before an address of the
// text of a block: its bytes, or all that the source has for it (an
// entity, a run of spaces, a line break with the marks of the next
// line). False at the start of the text.
char_before :: proc(doc: ^Document, places: []Place, at: Address) -> (start, end: int, ok: bool) {
	texts := block_texts(block_at(doc, at.block))
	if at.cell >= len(texts) || at.byte <= 0 {
		return
	}
	bytes := texts[at.cell].bytes[:min(at.byte, len(texts[at.cell].bytes))]
	_, size := utf8.decode_last_rune(bytes)
	first := len(bytes) - size
	for place in places {
		if place.cell != at.cell || first < place.text || first >= place.text + place.text_len {
			continue
		}
		if place.whole {
			return place.source, place.source + place.source_len, place.source_len > 0
		}
		start = place.source + first - place.text
		return start, start + size, true
	}
	return
}

// The address in the text of a block that an offset of the source is at:
// in the text that is in the source there, or at the end of the text
// before it when the offset is in marks or between blocks.
address_in :: proc(places: []Place, block, offset: int) -> (at: Address) {
	at.block = block
	for place in places {
		if place.source > offset {
			break
		}
		within := offset - place.source
		at.cell = place.cell
		if place.whole {
			at.byte = within >= place.source_len ? place.text + place.text_len : place.text
		} else {
			at.byte = place.text + min(within, place.text_len)
		}
	}
	return
}

// `place_of` with a map that is made for the call.
source_of :: proc(doc: ^Document, at: Address) -> (offset: int, ok: bool) {
	places := block_map(doc, at.block)
	defer delete(places)
	return place_of(doc, places[:], at)
}

// `address_in` for the block that has the offset. The document has a
// block.
address_of :: proc(doc: ^Document, offset: int) -> Address {
	block := block_at_offset(doc, offset)
	places := block_map(doc, block)
	defer delete(places)
	return address_in(places[:], block, offset)
}
