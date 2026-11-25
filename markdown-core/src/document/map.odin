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
	fresh := parse_piece(text[:], 0, len(doc.source), &places, block - first, lead + end - start, last < doc.count)
	base := start - lead
	// The piece must give the block as the document has it. It does not
	// when the limit of the parser for the uses of definitions cuts a
	// use in the piece that a parse of all keeps: then the places are
	// of another text. A parse of all of the source is right each time.
	if block - first >= fresh.count || !layout_equal(block_at(doc, block), block_at(&fresh, block - first)) {
		destroy(&fresh)
		clear(&places)
		text = make([dynamic]u8, len(doc.source))
		copy(text[:], doc.source)
		fresh = parse_piece(text[:], 0, len(doc.source), &places, block)
		base = 0
	}
	// The line break at the end of a code block is no text of it.
	texts := block_texts(block_at(doc, block))
	for len(places) > 0 {
		place := places[len(places) - 1]
		if place.cell < len(texts) && place.text < len(texts[place.cell].bytes) {
			break
		}
		pop(&places)
	}
	place_escapes(&places, text[:])
	// Where the text of the block can start, for a block with no text
	// from the source at all: a code block of empty lines starts after
	// its first line, which is its fence; each other block (a paragraph
	// of a NUL byte) at its own start.
	content := block_start(doc, block) - base
	line := content
	for line < len(text) && text[line] != '\n' && text[line] != '\r' {
		line += 1
	}
	first_line := string(text[min(content, len(text)):line])
	// Code in a fence, not code by its indent, which has no such line.
	if block_at(doc, block).kind == .Code && (strings.contains(first_line, "```") || strings.contains(first_line, "~~~")) {
		content = line
		if content + 1 < len(text) && text[content] == '\r' && text[content + 1] == '\n' {
			content += 1
		}
		content = min(content + 1, len(text))
	}
	place_made(places[:], text[:], content)
	destroy(&fresh)
	for &place in places {
		place.source += base
	}
	return
}

// A character with a backslash before it in the source ("\\*") is the
// two bytes: the parser gives the character only, and the backslash is
// at no other piece. The piece that starts with such a character gets a
// piece of its own for it.
@(private)
place_escapes :: proc(places: ^[dynamic]Place, source: []u8) {
	for i := 0; i < len(places); i += 1 {
		place := places[i]
		if place.made || place.whole || place.source < 1 || source[place.source - 1] != '\\' {
			continue
		}
		// Not a backslash that is text of the piece before.
		if i > 0 && !places[i - 1].made && places[i - 1].source + places[i - 1].source_len >= place.source {
			continue
		}
		rest := place
		rest.text += 1
		rest.text_len -= 1
		rest.source += 1
		rest.source_len -= 1
		places[i] = {place.cell, place.text, 1, place.source - 1, 2, true, false, false, false}
		if rest.text_len > 0 {
			inject_at(places, i + 1, rest)
			i += 1
		}
	}
}

// Gives each piece that the parser made its place in the source, from
// what is between the pieces of the same text around it. A line break
// is its bytes with the spaces (or the backslash) before it, and the
// marks of a quote and the indent of the next line after it: a soft
// line break in a quote goes out with the mark of the next line. Marks
// of bold text and the like that are beside it are no part of it. The
// spaces of an indent at the end of a run of made pieces are the bytes
// right before the text after them.
@(private)
place_made :: proc(places: []Place, source: []u8, content: int) {
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
	// The range of the first line break at `at` or after it and before
	// `limit`, with what goes with it. `at`, `at` when there is none.
	line_break :: proc(source: []u8, at, limit: int) -> (start, end: int) {
		for i in at ..< limit {
			if source[i] != '\n' && source[i] != '\r' {
				continue
			}
			start = i
			for start > at && (source[start - 1] == ' ' || source[start - 1] == '\t') {
				start -= 1
			}
			if start > at && source[start - 1] == '\\' {
				start -= 1
			}
			end = i + 1
			if source[i] == '\r' && end < limit && source[end] == '\n' {
				end += 1
			}
			for end < limit && (source[end] == ' ' || source[end] == '\t' || source[end] == '>') {
				end += 1
			}
			return
		}
		return at, at
	}
	// The start of the spaces and tabs that end at `end` and give an
	// indent of some columns, not before `low`. A tab gives all of the
	// columns that are left: the parser makes spaces of the part of a
	// tab that is no indent of the block.
	indent_before :: proc(source: []u8, end, low, columns: int) -> int {
		at, left := end, columns
		for at > low && left > 0 {
			switch source[at - 1] {
			case ' ':
				left -= 1
			case '\t':
				left = 0
			case:
				return at
			}
			at -= 1
		}
		return at
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
		if a < 0 && b < 0 {
			// No text from the source at all: from where the text of
			// the block can start.
			a = content
		} else if a < 0 {
			// At the start of the text: back from the text after it,
			// over as many line breaks, to each NUL byte, and over the
			// spaces of an indent.
			a = b
			#reverse for place in places[i:j] {
				switch {
				case place.line_break:
					a = break_before(source, a)
				case place.nul:
					for k := a - 1; k >= content; k -= 1 {
						if source[k] == 0 {
							a = k
							break
						}
					}
				case:
					a = indent_before(source, a, content, place.text_len)
				}
			}
		}
		if b < 0 {
			b = len(source)
		}
		// The spaces of an indent, from the end.
		m := j
		for m > i && !places[m - 1].line_break && !places[m - 1].nul {
			place := &places[m - 1]
			place.source = indent_before(source, b, a, place.text_len)
			place.source_len = b - place.source
			place.whole = place.source_len != place.text_len
			b = place.source
			m -= 1
		}
		at := a
		for &place in places[i:m] {
			switch {
			case place.line_break:
				place.source, at = line_break(source, at, b)
				place.source_len = at - place.source
			case place.nul:
				// The byte itself.
				for at < b && source[at] != 0 {
					at += 1
				}
				place.source, place.source_len = at, at < b ? 1 : 0
				at += place.source_len
			case:
				place.source, place.source_len = at, 0
			}
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
	// An empty paragraph after the text: its line of the source.
	if n := empty_of(doc, at); n > 0 {
		return empty_offset(doc, at.block, n), true
	}
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
			// Past its start is after it: a space that is typed into a
			// run of spaces is before the caret.
			at.byte = within > 0 ? place.text + place.text_len : place.text
		} else {
			at.byte = place.text + min(within, place.text_len)
		}
	}
	return
}

// `address_in` for a block of a document: an offset in an empty
// paragraph after the block, or after one, is the address of that
// paragraph (`empties.odin`).
address_for :: proc(doc: ^Document, places: []Place, block, offset: int) -> Address {
	if n := empty_at(doc, block, offset); n > 0 {
		if at, ok := empty_address(doc, block, n); ok {
			return at
		}
	}
	return address_in(places, block, offset)
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
	return address_for(doc, places[:], block, offset)
}
