package layout

import "../document"
import "../base"
import "../text"
import "core:math"

// A place in the document, for a view that must show the same text after
// a new layout (another width, another text size): the line of text at a
// height of the page, by the address of its first byte, and how far down
// that line the height is, in line heights. An offset in points says
// nothing after the lines are broken again; this does.
//
// The address is in the document, so the place is the same text in each
// layout.
Place :: struct {
	using at: document.Address, // of the first byte of the line
	fraction: f32, // below 0 for a height above the line (between two blocks, in blank lines of code)
}

// The place at a height of the page. False when the page has no text at
// or below it.
place_at :: proc(l: ^Layout, y: f64) -> (place: Place, ok: bool) {
	for p in first_part_below(l, y) ..< len(l.parts) {
		part := &l.parts[p]
		y := f32(y - part.top) // from the top of the part
		for i in first_box_below(part, y) ..< len(part.boxes) {
			box := part.boxes[i]
			b := &l.doc.parts[p].blocks[i]
			// The first line of text that ends below y. In a table that is
			// a cell of the row at y, and each line is a candidate. In
			// another block it is the line at y, or the first one for a y
			// above them.
			from := box.line_first
			if b.kind != .Table {
				from = max(line_at_or_above(part, box, y), text_first(part, box))
			}
			for line in part.lines[from:box.line_end] {
				para := &part.paras[line.para]
				if para.src == nil || line.top + para.line_height <= y {
					continue
				}
				// Not limited above the line: the room above it can be many
				// lines high (blank lines of a code block have no line of
				// their own), and all of it is a place.
				fraction := (y - line.top) / para.line_height
				return {{l.doc.starts[p] + i, document.cell_of(b, para.src), para.base + line.line.start}, fraction}, true
			}
			// A block with no text (a rule): the next one.
		}
	}
	return
}

// The first line of the text of a block that is not a table. The marker
// of a list item comes before it, and its lines (a long number can wrap)
// start at the height of the text again.
@(private)
text_first :: proc(part: ^Part, box: Box) -> int {
	first := box.line_first
	for first < box.line_end && part.paras[part.lines[first].para].src == nil {
		first += 1
	}
	return first
}

// The last line of the text of a block that starts at or above y (from
// the top of the part), or the line before the text when none does. Not
// for a table. The lines of the text go down the page, so this does not
// look at each one: a code block can have many.
@(private)
line_at_or_above :: proc(part: ^Part, box: Box, y: f32) -> int {
	first := text_first(part, box)
	lo, hi := first, box.line_end
	for lo < hi {
		mid := (lo + hi) / 2
		if part.lines[mid].top <= y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

// The height of a place in this layout. False while its block is not
// laid out to its end (`lay_out_block`).
place_y :: proc(l: ^Layout, place: Place) -> (y: f64, ok: bool) {
	if place.block < 0 || place.block >= l.doc.count {
		return
	}
	p, slot := document.locate(l.doc, place.block)
	part := &l.parts[p]
	if slot >= blocks_done(part) {
		return
	}
	box := part.boxes[slot]
	b := &l.doc.parts[p].blocks[slot]
	src := document.text_at(l.doc, place.at)
	// The line that has the byte of the place: the last line of its text
	// that starts at or before it.
	found := -1
	if src != nil && b.kind != .Table {
		// The lines of the text are in the order of its bytes.
		lo, hi := text_first(part, box), box.line_end
		for lo < hi {
			mid := (lo + hi) / 2
			line := part.lines[mid]
			if part.paras[line.para].base + line.line.start <= place.byte {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		if lo > text_first(part, box) {
			found = lo - 1
		}
	} else if src != nil {
		for i in box.line_first ..< box.line_end {
			line := part.lines[i]
			para := &part.paras[line.para]
			if para.src == src && para.base + line.line.start <= place.byte {
				found = i
			}
		}
	}
	if found < 0 {
		// The text of the block is another one now: its top.
		return part.top + f64(box.top), true
	}
	line := part.lines[found]
	return part.top + f64(line.top + place.fraction * part.paras[line.para].line_height), true
}

// True when a point of the page is on a line of text: in its height, not
// left of where it starts, and not right of the column (the space after a
// short line is the line's; a table wider than the column is all text).
// The margins, the space between blocks, and
// the place of a list marker or a check box are not text. For the pointer:
// a host shows the text cursor only there.
text_at :: proc(l: ^Layout, x: f32, y: f64) -> bool {
	p := first_part_below(l, y)
	if p >= len(l.parts) {
		return false
	}
	part := &l.parts[p]
	y := f32(y - part.top)
	i := first_box_below(part, y)
	if i >= len(part.boxes) {
		return false
	}
	box := part.boxes[i]
	on_line :: proc(l: ^Layout, part: ^Part, line: Line, x, y: f32) -> bool {
		para := &part.paras[line.para]
		if para.src == nil || y < line.top || y >= line.top + para.line_height || x < line.x {
			return false
		}
		return x <= max(l.column_x + l.column, line.x + line.line.width)
	}
	if l.doc.parts[p].blocks[i].kind == .Table {
		// The cells of a row are side by side: each line is a candidate.
		for line in part.lines[box.line_first:box.line_end] {
			if on_line(l, part, line, x, y) {
				return true
			}
		}
		return false
	}
	at := line_at_or_above(part, box, y)
	return at >= text_first(part, box) && on_line(l, part, part.lines[at], x, y)
}

// The box before or after one, in the parts that have boxes. False at
// the two ends.
@(private)
next_box :: proc(l: ^Layout, part, slot, step: int) -> (p, s: int, ok: bool) {
	p, s = part, slot + step
	for s < 0 || s >= len(l.parts[p].boxes) {
		p += step
		if p < 0 || p >= len(l.parts) {
			return
		}
		s = step > 0 ? 0 : len(l.parts[p].boxes) - 1
	}
	return p, s, true
}

// The caret position nearest to a point of the page, in what is laid out.
hit_test :: proc(l: ^Layout, x: f32, y: f64) -> (pos: document.Address, ok: bool) {
	// The block at y, and the ones around it for a point between blocks or
	// in a block that has no text.
	p := part_at(l, y)
	if p < 0 {
		return
	}
	slot := min(first_box_below(&l.parts[p], f32(y - l.parts[p].top)), len(l.parts[p].boxes) - 1)
	if slot < 0 {
		// A part with no records: the nearest box after it, or before it.
		p, slot = next_box(l, p, -1, 1) or_else (next_box(l, p, 0, -1) or_return)
	}
	Best :: struct {
		part, slot, line: int,
		score:            f64,
	}
	best := Best{-1, -1, -1, 1e30}
	look :: proc(l: ^Layout, p, slot: int, x: f32, y: f64, best: ^Best) {
		part := &l.parts[p]
		box := part.boxes[slot]
		for i in box.line_first ..< box.line_end {
			line := part.lines[i]
			para := &part.paras[line.para]
			if para.src == nil {
				continue
			}
			top := part.top + f64(line.top)
			bottom := top + f64(para.line_height)
			right := line.x + line.line.width
			dy := y < top ? top - y : (y >= bottom ? y - bottom : 0)
			dx := x < line.x ? line.x - x : (x > right ? x - right : 0)
			score := dy * 1000 + f64(dx)
			if score < best.score {
				best^ = {p, slot, i, score}
			}
		}
	}
	look(l, p, slot, x, y, &best)
	// More boxes on each side, in the order down the page, until one has
	// text.
	up_p, up_s, down_p, down_s := p, slot, p, slot
	up, down := true, true
	for reach := 1; (up || down) && (best.line < 0 || reach == 1); reach *= 4 {
		for _ in 0 ..< reach {
			if up {
				up_p, up_s, up = next_box(l, up_p, up_s, -1)
				if up {
					look(l, up_p, up_s, x, y, &best)
				}
			}
			if down {
				down_p, down_s, down = next_box(l, down_p, down_s, 1)
				if down {
					look(l, down_p, down_s, x, y, &best)
				}
			}
		}
	}
	if best.line < 0 {
		return
	}
	line := shaped_line(l, best.part, best.line)
	para := &l.parts[best.part].paras[line.para]
	b := &l.doc.parts[best.part].blocks[best.slot]
	return {l.doc.starts[best.part] + best.slot, document.cell_of(b, para.src), para.base + text.line_index_for_x(line.line, x - line.x)}, true
}

// The part of a line that is in the selection, as byte offsets in the
// source text of its paragraph. `b`, `block`: the block of the line and
// its number.
@(private)
selected_part :: proc(para: ^Para, b: ^document.Block, block: int, line: Line, from, to: document.Address) -> (start, end: int, ok: bool) {
	if para.src == nil {
		return
	}
	// The addresses of the two ends of the line.
	cell := document.cell_of(b, para.src)
	first := document.Address{block, cell, para.base + line.line.start}
	last := document.Address{block, cell, para.base + line.line.end}
	if !document.before(first, to) || !document.before(from, last) {
		return
	}
	start = document.before(first, from) ? from.byte : first.byte
	end = document.before(to, last) ? to.byte : last.byte
	return start, end, start < end
}

// Makes the highlight quads of the selection between y0 and y1 (points).
selection_quads :: proc(l: ^Layout, s: document.Selection, y0, y1: f64, scale: f32, origin_y: f64, out: ^[dynamic]base.Quad) {
	from, to, ok := document.selection_range(s)
	if !ok {
		return
	}
	for p in first_part_below(l, y0) ..< len(l.parts) {
		part := &l.parts[p]
		if part.top >= y1 {
			break
		}
		// The range from the top of the part.
		top, bottom := f32(y0 - part.top), f32(y1 - part.top)
		first := first_box_below(part, top)
		for box, n in part.boxes[first:] {
			if box.top >= bottom {
				break
			}
			block := l.doc.starts[p] + first + n
			b := &l.doc.parts[p].blocks[first + n]
			for i in box.line_first ..< box.line_end {
				line := part.lines[i]
				para := &part.paras[line.para]
				if line.top + para.line_height < top || line.top > bottom {
					continue // a long block: only its lines in the range
				}
				start, end := selected_part(para, b, block, line, from, to) or_continue
				line = shaped_line(l, p, i)^
				x1 := text.line_x_for_index(line.line, start - para.base)
				x2 := text.line_x_for_index(line.line, end - para.base)
				if x2 < x1 {
					x1, x2 = x2, x1
				}
				append(out, rect_quad(line.x + x1, line.top, max(x2 - x1, 2), para.line_height, l.style.selection, 0, scale, part.top, origin_y))
			}
		}
	}
}

// The check box of a task on the page, for a host that puts its own
// control on it.
Task_Place :: struct {
	x:     f32, // points; the side is `task_box_size`
	y:     f64,
	block: ^document.Block, // has the line of the task and its state
}

// Writes the tasks whose boxes are between two heights of the page to
// `out`, down the page. Returns how many there are, which can be more
// than `out` has room for.
tasks_between :: proc(l: ^Layout, top, bottom: f64, out: []Task_Place) -> (count: int) {
	size := f64(task_box_size(l.m))
	// A box can reach out of its part at the two ends (`OVERHANG`), so
	// the parts next to the range are looked at too.
	for p in first_part_below(l, top - OVERHANG) ..< len(l.parts) {
		part := &l.parts[p]
		if part.top - OVERHANG >= bottom {
			break
		}
		// A part has one task for each block at most, so this looks at
		// each one.
		for task in part.tasks {
			// A box stands on a whole point of the page.
			y := math.round(part.top + f64(task.y))
			if y >= bottom {
				break
			}
			if y + size <= top {
				continue
			}
			if count < len(out) {
				out[count] = {task.x, y, &l.doc.parts[p].blocks[task.block]}
			}
			count += 1
		}
	}
	return
}
