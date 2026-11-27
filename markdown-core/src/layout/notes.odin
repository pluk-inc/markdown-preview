package layout

import "core:slice"

import "../base"
import "../document"
import "../text"

// Footnotes on the page: what a point is on, for a click that goes from
// a reference to the text of its footnote and back.

// The footnote that a point of the page is on: the number of a reference
// in the text, or (`definition`) the number mark of the text of a
// footnote. False for each other point, and for what is not laid out.
note_at :: proc(l: ^Layout, x: f32, y: f64) -> (number: int, definition: bool, ok: bool) {
	// In the list of the footnotes at the end of the page.
	if l.notes.page != nil && y >= l.notes.top {
		return note_in_list(l.notes.page, x, y)
	}
	p := first_part_below(l, y)
	if p >= len(l.parts) {
		return
	}
	part := &l.parts[p]
	from_top := f32(y - part.top)
	slot := first_box_below(part, from_top)
	if slot >= len(part.boxes) || from_top < part.boxes[slot].top {
		return
	}
	b := &l.doc.parts[p].blocks[slot]
	// The mark of a definition: left of its text, in its first line.
	text_x := l.column_x + list_x(l, b) + f32(b.quote_depth) * l.m.quote_indent
	if b.marker == .Note && b.number > 0 && x < text_x && x >= text_x - l.m.list_indent - 0.8 * l.m.body && from_top < part.boxes[slot].top + l.m.body * l.m.line_height {
		return b.number, true, true
	}
	// Only a block with a number in its text needs the place of the
	// point in the text: the pointer asks for each of its moves, and that
	// place costs a look at each line of the block (a long code block).
	noted := false
	for &t in document.block_texts(b) {
		for span in t.spans {
			noted ||= .Note in span.style
		}
	}
	if !noted || !text_at(l, x, y) {
		return
	}
	span, _ := span_under(l, x, y, {.Note}) or_return
	return span.link, false, true
}

// The span with one of `styles` that a point of the page is on, between
// the two ends of its text. The place nearest to the point is an end of
// the span when the point is on it: the span there, or the one before
// it.
@(private)
span_under :: proc(l: ^Layout, x: f32, y: f64, styles: document.Inline_Set) -> (found: document.Span, src: ^document.Text, ok: bool) {
	at := hit_test(l, x, y) or_return
	src = document.text_at(l.doc, at)
	if src == nil || len(src.spans) == 0 {
		return
	}
	for byte in ([2]int{at.byte, at.byte - 1}) {
		if byte < 0 || byte >= len(src.bytes) {
			continue
		}
		span := document.span_at(src, byte)
		if span.style & styles == {} {
			continue
		}
		start, end := at, at
		start.byte, end.byte = span.start, span.end
		x0, _, _, _, placed0 := caret_place(l, start)
		x1, _, _, _, placed1 := caret_place(l, end, true)
		if placed0 && placed1 && x >= x0 - 1 && x <= x1 + 1 {
			return span^, src, true
		}
	}
	return
}

// The height of the page where a block starts, with the part of the
// block laid out down to it. `changed`: the layout made records, and
// the page can be another height.
block_top :: proc(l: ^Layout, block: int) -> (y: f64, changed: bool, ok: bool) {
	if l.doc == nil || block < 0 || block >= l.doc.count {
		return
	}
	changed = lay_out_block(l, block)
	p, slot := document.locate(l.doc, block)
	part := &l.parts[p]
	if slot >= len(part.boxes) {
		return 0, changed, false
	}
	return part.top + f64(part.boxes[slot].top), changed, true
}

// The footnotes at the end of the page: a hairline, and the numbered list
// of the texts of the footnotes, each with a mark that goes back to the
// place of its reference. For a page that is read: there the texts of
// the footnotes do not show where they are in the source
// (`Layout.notes_at_end`).
//
// The list is a document of its own, made from the footnotes of the
// document (`document.notes_source`), with a layout of its own whose top
// is its place on the page of the owner: its heights are heights of that
// page. It is no part of the document, so no caret is in it.
Notes_Area :: struct {
	source: []u8, // the Markdown of the list
	doc:    ^document.Document,
	page:   ^Layout,
	top:    f64, // of the area on the page
	height: f32, // with the room and the hairline above the list; 0 for none
}

NOTES_ABOVE :: 2.0 // room above the hairline, in body sizes
NOTES_SIZE :: 0.86 // of the text of the list, in sizes of the text of the document

// Makes the list of the footnotes of the document, when it is another
// one than before, or with `force` (another width or style). True when
// it made one or took one away: the page has another height then.
@(private)
notes_begin :: proc(l: ^Layout, force := false) -> bool {
	want: string
	if l.notes_at_end && l.doc != nil {
		want = document.notes_source(l.doc, context.temp_allocator)
	}
	if !force && string(l.notes.source) == want {
		return false
	}
	had := l.notes.height > 0
	notes_destroy(l)
	if want == "" {
		return had
	}
	notes := &l.notes
	notes.source = slice.clone(transmute([]u8)want)
	notes.doc = new(document.Document)
	notes.doc^ = document.parse(want)
	notes.page = new(Layout)
	// Smaller and softer than the text of the document: what a reader
	// goes to when they want it.
	style := l.style
	style.body_size *= NOTES_SIZE
	style.text = l.style.secondary
	begin(notes.page, notes.doc, style, l.width)
	// All of it: a list of footnotes is short beside its document.
	lay_out(notes.page, -1e30, 1e30, 0)
	notes.height = NOTES_ABOVE * l.m.body + 1 + f32(notes.page.content_height)
	return true
}

@(private)
notes_destroy :: proc(l: ^Layout) {
	notes := &l.notes
	if notes.page != nil {
		destroy(notes.page)
		free(notes.page)
	}
	if notes.doc != nil {
		document.destroy(notes.doc)
		free(notes.doc)
	}
	delete(notes.source)
	notes^ = {}
}

// Puts the list at `top` of the page, and returns the height of the page
// below it.
@(private)
notes_place :: proc(l: ^Layout, top: f64) -> f64 {
	notes := &l.notes
	notes.top = top
	if notes.page == nil {
		return top
	}
	notes.page.origin = top + f64(NOTES_ABOVE * l.m.body + 1)
	sum_tops(notes.page)
	return top + f64(notes.height)
}

// The quads of the list between two heights of the page.
@(private)
notes_display :: proc(l: ^Layout, cache: ^text.Glyph_Cache, y0, y1: f64, origin_y: f64, rects, glyphs: ^[dynamic]base.Quad, buffer: ^text.Glyph_Buffer) {
	notes := &l.notes
	if notes.page == nil || notes.top + f64(notes.height) <= y0 || notes.top >= y1 {
		return
	}
	append(rects, rect_quad(l.column_x, NOTES_ABOVE * l.m.body, l.column, 1, l.style.rule, 0, cache.scale, notes.top, origin_y))
	display(notes.page, cache, y0, y1, origin_y, rects, glyphs, buffer)
}

// `note_at` for a point in the list (`list` is its layout): on the mark
// that goes back, or on the number of an item. The footnote is the one
// of the number of the item.
@(private)
note_in_list :: proc(list: ^Layout, x: f32, y: f64) -> (number: int, definition: bool, ok: bool) {
	p := first_part_below(list, y)
	if p >= len(list.parts) {
		return
	}
	part := &list.parts[p]
	from_top := f32(y - part.top)
	slot := first_box_below(part, from_top)
	if slot >= len(part.boxes) || from_top < part.boxes[slot].top {
		return
	}
	block := list.doc.starts[p] + slot
	b := document.block_at(list.doc, block)
	// The number is of the item of the list that the block is in: a
	// footnote can have a list of its own in its text.
	first: ^document.Block
	for i := block; i >= 0; i -= 1 {
		if at := document.block_at(list.doc, i); note_starts(at) {
			first = at
			break
		}
	}
	if first == nil {
		return
	}
	text_x := list.column_x + list_x(list, b)
	on_mark := b == first && x < text_x && x >= text_x - list.m.list_indent - 0.8 * list.m.body && from_top < part.boxes[slot].top + list.m.body * list.m.line_height
	// The link that goes back (its target and its mark), and no other
	// link of the text; on the mark itself, not on the room after it.
	on_back := false
	if !on_mark && text_at(list, x, y) {
		if span, src, hit := span_under(list, x, y, {.Link}); hit {
			on_back = span.link > 0 && span.link <= len(list.doc.links) && list.doc.links[span.link - 1] == document.NOTE_BACK_TARGET && string(src.bytes[span.start:span.end]) == document.NOTE_BACK
		}
	}
	return first.number, true, on_mark || on_back
}

// True for the first block of a footnote in the list of the footnotes:
// of an item of the list itself, and not of a list in a text.
@(private)
note_starts :: proc(b: ^document.Block) -> bool {
	// Also in a quote: a text can start with one.
	return b.marker == .Number && b.list_depth == 1 && b.spacing != .Continuation
}

// The height of the page where the text of a footnote starts: in the
// list at the end of the page when the page has one, or where its
// definition is in the document.
note_top :: proc(l: ^Layout, number: int) -> (y: f64, changed: bool, ok: bool) {
	if list := l.notes.page; list != nil {
		for i in 0 ..< list.doc.count {
			if b := document.block_at(list.doc, i); note_starts(b) && b.number == number {
				return block_top(list, i)
			}
		}
		return
	}
	block := document.note_block(l.doc, number, 0) or_return
	return block_top(l, block)
}
