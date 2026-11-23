package layout

import "../text"
import "base:runtime"

// The window: the part of the page whose lines keep their shaped text.
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
// fonts give the same glyphs. `keep` and the layout steps release what is
// outside the window. They work on a paragraph at a time, and a line of a
// code block is its own paragraph, so a long code block is not one unit.

// Sets the part of the page that keeps its shaped text, y0 to y1 in
// points, and releases the shaped text outside it.
keep :: proc(l: ^Layout, y0, y1: f32) {
	l.keep_y0, l.keep_y1 = y0, y1
	l.live_first, l.live_end = trim(l, l.live_first, min(l.live_end, len(l.lines)))
}

// The line with its shaped text.
@(private)
shaped_line :: proc(l: ^Layout, index: int) -> ^Line {
	line := &l.lines[index]
	if !text.line_shaped(line.line) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		para := &l.paras[line.para]
		if para.handle == nil {
			shape_para(l, para)
		}
		text.line_restore(&line.line, para.handle)
		note_live(l, index, index + 1)
	}
	return line
}

@(private)
note_live :: proc(l: ^Layout, first, end: int) {
	if l.live_first == l.live_end {
		l.live_first, l.live_end = first, end
	} else {
		l.live_first = min(l.live_first, first)
		l.live_end = max(l.live_end, end)
	}
}

// Releases the paragraphs of the lines [from, to) that are outside the
// window. Returns the range of the lines that can still have shaped text;
// first == end when none has.
@(private)
trim :: proc(l: ^Layout, from, to: int) -> (first, end: int) {
	first, end = to, from
	for i := from; i < to; {
		// The lines of one paragraph are next to each other.
		index := l.lines[i].para
		start, stop := i, i + 1
		for start > 0 && l.lines[start - 1].para == index {
			start -= 1
		}
		for stop < len(l.lines) && l.lines[stop].para == index {
			stop += 1
		}
		i = stop
		para := &l.paras[index]
		if para.handle == nil {
			continue
		}
		if l.lines[stop - 1].top + para.line_height > l.keep_y0 && l.lines[start].top < l.keep_y1 {
			first, end = min(first, start), max(end, stop)
			continue
		}
		for &line in l.lines[start:stop] {
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
