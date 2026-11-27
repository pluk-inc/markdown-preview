package layout

import "../text"

// The window: the range of the page whose lines keep their shaped text.
//
// The records of a block (its place, its lines' ranges and widths, its
// decorations) are small and stay for the full document, so the page
// height, the scroll bar, and the copied text never need the text system.
// The shaped text (the text system's paragraph and line objects) is many
// times larger. It is needed only to make glyph quads, to find the x of a
// caret, and to break lines.
//
// So a procedure that reads glyphs takes its line from `shaped_line`,
// which shapes the line again when it was released: the same text and
// fonts give the same glyphs. `keep` and the layout release what is
// outside the window. They work on a paragraph at a time, and a line of a
// code block is its own paragraph, so a long code block is not one unit.

// Sets the range of the page that keeps its shaped text, y0 to y1 in
// points, and releases the shaped text outside it.
keep :: proc(l: ^Layout, y0, y1: f64) {
	l.keep_y0, l.keep_y1 = y0, y1
	// The list of the footnotes is at heights of the same page.
	if l.notes.page != nil {
		keep(l.notes.page, y0, y1)
	}
	for &part in l.parts {
		if part.live_first < part.live_end {
			part.live_first, part.live_end = trim(l, &part, part.live_first, min(part.live_end, len(part.lines)))
		}
	}
}

// The line of a part with its shaped text.
@(private)
shaped_line :: proc(l: ^Layout, part_index, index: int) -> ^Line {
	part := &l.parts[part_index]
	line := &part.lines[index]
	if !text.line_shaped(line.line) {
		para := &part.paras[line.para]
		if para.handle == nil {
			shape_para(l, part_index, para)
		}
		text.line_restore(&line.line, para.handle)
		note_live(part, index, index + 1)
	}
	return line
}

@(private)
note_live :: proc(part: ^Part, first, end: int) {
	if part.live_first == part.live_end {
		part.live_first, part.live_end = first, end
	} else {
		part.live_first = min(part.live_first, first)
		part.live_end = max(part.live_end, end)
	}
}

// Releases the paragraphs of the lines [from, to) of a part that are
// outside the window. Returns the range of the lines that can still have
// shaped text; first == end when none has.
@(private)
trim :: proc(l: ^Layout, part: ^Part, from, to: int) -> (first, end: int) {
	// The window from the top of the part.
	keep_y0, keep_y1 := f32(l.keep_y0 - part.top), f32(l.keep_y1 - part.top)
	first, end = to, from
	for i := from; i < to; {
		// The lines of one paragraph are next to each other.
		index := part.lines[i].para
		start, stop := i, i + 1
		for start > 0 && part.lines[start - 1].para == index {
			start -= 1
		}
		for stop < len(part.lines) && part.lines[stop].para == index {
			stop += 1
		}
		i = stop
		para := &part.paras[index]
		if para.handle == nil {
			continue
		}
		if part.lines[stop - 1].top + para.line_height > keep_y0 && part.lines[start].top < keep_y1 {
			first, end = min(first, start), max(end, stop)
			continue
		}
		for &line in part.lines[start:stop] {
			text.line_release(&line.line)
		}
		text.paragraph_destroy(para.handle)
		para.handle = nil
	}
	if first >= end {
		return 0, 0
	}
	return
}
