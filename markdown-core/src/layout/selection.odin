package layout

import "../base"
import "../text"

// A caret position: a paragraph by its number in reading order, and a byte
// offset in the source text of that paragraph.
Position :: struct {
	order, index: int,
}

Selection :: struct {
	active:        bool,
	anchor, focus: Position,
}

@(private)
before :: proc(a, b: Position) -> bool {
	return a.order < b.order || (a.order == b.order && a.index < b.index)
}

// The two ends of the selection in reading order. False when nothing is
// selected.
selection_range :: proc(s: Selection) -> (from, to: Position, ok: bool) {
	if !s.active || s.anchor == s.focus {
		return
	}
	from, to = s.anchor, s.focus
	if before(to, from) {
		from, to = to, from
	}
	return from, to, true
}

// True when a point of the page is on a line of text: in its height, not
// left of where it starts, and not right of the column (the space after a
// short line is the line's; a table wider than the column is all text).
// The margins, the space between blocks, and
// the place of a list marker or a check box are not text. For the pointer:
// a host shows the text cursor only there.
text_at :: proc(l: ^Layout, x, y: f32) -> bool {
	i := first_box_below(l, y)
	if i >= len(l.boxes) {
		return false
	}
	box := l.boxes[i]
	on_line :: proc(l: ^Layout, line: Line, x, y: f32) -> bool {
		para := &l.paras[line.para]
		if para.src == nil || y < line.top || y >= line.top + para.line_height || x < line.x {
			return false
		}
		return x <= max(l.column_x + l.column, line.x + line.line.width)
	}
	if l.doc.blocks[i].kind == .Table {
		// The cells of a row are side by side: each line is a candidate.
		for line in l.lines[box.line_first:box.line_end] {
			if on_line(l, line, x, y) {
				return true
			}
		}
		return false
	}
	// The marker of a list item comes first, and its lines (a long number
	// can wrap) start at the height of the text again. After it the lines
	// of the text go down the page, so the one at y is found without a
	// look at each line: a code block can have many.
	first := box.line_first
	for first < box.line_end && l.paras[l.lines[first].para].src == nil {
		first += 1
	}
	lo, hi := first, box.line_end
	for lo < hi {
		mid := (lo + hi) / 2
		if l.lines[mid].top <= y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	// The last line that starts at or above y.
	return lo > first && on_line(l, l.lines[lo - 1], x, y)
}

// The caret position nearest to a point of the page.
hit_test :: proc(l: ^Layout, x, y: f32) -> (pos: Position, ok: bool) {
	if len(l.boxes) == 0 {
		return
	}
	// The block at y, and the ones around it for a point between blocks or
	// in a block that has no text.
	center := min(first_box_below(l, y), len(l.boxes) - 1)
	best := -1
	best_score: f32 = 1e30
	for reach := 1; best < 0; reach *= 4 {
		first := max(center - reach, 0)
		last := min(center + reach, len(l.boxes) - 1)
		for i in l.boxes[first].line_first ..< l.boxes[last].line_end {
			line := l.lines[i]
			para := &l.paras[line.para]
			if para.src == nil {
				continue
			}
			bottom := line.top + para.line_height
			right := line.x + line.line.width
			dy := y < line.top ? line.top - y : (y >= bottom ? y - bottom : 0)
			dx := x < line.x ? line.x - x : (x > right ? x - right : 0)
			score := dy * 1000 + dx
			if score < best_score {
				best, best_score = i, score
			}
		}
		if first == 0 && last == len(l.boxes) - 1 {
			break
		}
	}
	if best < 0 {
		return
	}
	line := shaped_line(l, best)
	para := &l.paras[line.para]
	return Position{para.order, para.base + text.line_index_for_x(line.line, x - line.x)}, true
}

// The part of a line that is in the selection, as byte offsets in the
// source text of its paragraph.
@(private)
selected_part :: proc(para: ^Para, line: Line, from, to: Position) -> (start, end: int, ok: bool) {
	if para.src == nil || para.order < from.order || para.order > to.order {
		return
	}
	line_start, line_end := para.base + line.line.start, para.base + line.line.end
	start = para.order == from.order ? max(from.index, line_start) : line_start
	end = para.order == to.order ? min(to.index, line_end) : line_end
	return start, end, start < end
}

// Makes the highlight quads of the selection between y0 and y1 (points).
selection_quads :: proc(l: ^Layout, s: Selection, y0, y1: f32, scale, origin_y: f32, out: ^[dynamic]base.Quad) {
	from, to, ok := selection_range(s)
	if !ok {
		return
	}
	for box in l.boxes[first_box_below(l, y0):] {
		if box.top >= y1 {
			break
		}
		for i in box.line_first ..< box.line_end {
			line := l.lines[i]
			para := &l.paras[line.para]
			if line.top + para.line_height < y0 || line.top > y1 {
				continue // a long block: only its lines in the range
			}
			start, end := selected_part(para, line, from, to) or_continue
			line = shaped_line(l, i)^
			x1 := text.line_x_for_index(line.line, start - para.base)
			x2 := text.line_x_for_index(line.line, end - para.base)
			if x2 < x1 {
				x1, x2 = x2, x1
			}
			append(out, rect_quad(line.x + x1, line.top, max(x2 - x1, 2), para.line_height, l.style.selection, 0, scale, origin_y))
		}
	}
}

// The first and the last caret position of the part that is laid out.
select_all :: proc(l: ^Layout) -> (s: Selection) {
	for para in l.paras {
		if para.src == nil {
			continue
		}
		if !s.active {
			s.anchor = Position{para.order, para.base}
			s.active = true
		}
		s.focus = Position{para.order, para.base + para.len}
	}
	return
}

// Appends the selected text to `out` as UTF-8. A new paragraph starts a new
// line; empty lines of a code block stay.
selection_text :: proc(l: ^Layout, s: Selection, out: ^[dynamic]u8) {
	from, to, ok := selection_range(s)
	if !ok {
		return
	}
	last_order := -1
	for line in l.lines {
		para := &l.paras[line.para]
		start, end := selected_part(para, line, from, to) or_continue
		if last_order >= 0 {
			for _ in 0 ..< para.order - last_order {
				append(out, '\n')
			}
		}
		last_order = para.order
		append(out, ..para.src.bytes[start:end])
	}
}

// The first task whose box ends below y, or len(tasks).
@(private)
first_task_below :: proc(l: ^Layout, y: f32) -> int {
	size := task_box_size(l.m)
	lo, hi := 0, len(l.tasks)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.tasks[mid].y + size <= y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The tasks whose boxes are between two heights of the page, for a host
// that puts its own control on each one.
tasks_between :: proc(l: ^Layout, top, bottom: f32) -> []Task {
	first := first_task_below(l, top)
	last := first
	for last < len(l.tasks) && l.tasks[last].y < bottom {
		last += 1
	}
	return l.tasks[first:last]
}
