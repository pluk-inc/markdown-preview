package layout

import "core:slice"

import "../base"
import "../document"
import "../text"

// Footnotes on the page: what a point is on, for a click that goes from
// a reference to the text of its footnote and back. The text of a
// footnote is where its definition is in the source, in a page that is
// read and in one that is edited.

// The footnote that a point of the page is on: the number of a reference
// in the text, or (`definition`) the number mark of the text of a
// footnote. False for each other point, and for what is not laid out.
note_at :: proc(l: ^Layout, x: f32, y: f64) -> (number: int, definition: bool, ok: bool) {
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
	// The mark of a definition: the number that is drawn left of its
	// text, which is the first line of the block. Not the room between
	// the number and the text.
	if box := part.boxes[slot]; b.marker == .Note && b.number > 0 && box.line_end > box.line_first {
		mark := part.lines[box.line_first]
		if part.paras[mark.para].src == nil && x >= mark.x - 1 && x <= mark.x + mark.line.width + 1 && from_top >= mark.top && from_top < mark.top + part.paras[mark.para].line_height {
			return b.number, true, true
		}
	}
	// A document with no reference has no number in a text.
	if len(l.doc.notes.references) == 0 {
		return
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

// The height of the page where the text of a footnote starts: where its
// definition is in the document.
note_top :: proc(l: ^Layout, number: int) -> (y: f64, changed: bool, ok: bool) {
	block := document.note_block(l.doc, number, 0) or_return
	return block_top(l, block)
}
