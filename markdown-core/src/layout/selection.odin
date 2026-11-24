package layout

import "../document"
import "../base"
import "../text"
import "core:math"

// A caret position: a paragraph by its block and its number in reading
// order in that block, and a byte offset in the source text of that
// paragraph. It says the same in each layout of the document.
Position :: struct {
	block, order, index: int,
}

Selection :: struct {
	active:        bool,
	anchor, focus: Position,
}

@(private)
before :: proc(a, b: Position) -> bool {
	if a.block != b.block {
		return a.block < b.block
	}
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

// A place in the document, for a view that must show the same text after
// a new layout (another width, another text size): the line of text at a
// height of the page, by the address of its first byte, and how far down
// that line the height is, in line heights. An offset in points says
// nothing after the lines are broken again; this does.
//
// The address is in the document, not in a layout: the block, the cell
// for a table, and the byte in that text. So it needs no layout to be
// made, and it is the same text when another block got more or fewer
// lines.
Place :: struct {
	block:    int, // its number in the document
	cell:     int, // of a table; 0 in each other block
	byte:     int, // in the text of the block or of the cell
	fraction: f32, // below 0 for a height above the line (between two blocks, in blank lines of code)
}

// The text of a place: of its block, or of its cell in a table. Nil when
// the document has no such text.
@(private)
place_text :: proc(l: ^Layout, block, cell: int) -> ^document.Text {
	if block < 0 || block >= l.doc.count {
		return nil
	}
	return block_text(document.block_at(l.doc, block), cell)
}

@(private)
block_text :: proc(b: ^document.Block, cell: int) -> ^document.Text {
	if b.kind != .Table {
		return &b.text
	}
	return cell >= 0 && cell < len(b.cells) ? &b.cells[cell] : nil
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
				cell := 0
				if b.kind == .Table {
					cell = int(uintptr(para.src) - uintptr(raw_data(b.cells))) / size_of(document.Text)
				}
				return {l.doc.starts[p] + i, cell, para.base + line.line.start, fraction}, true
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
	src := block_text(b, place.cell)
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
hit_test :: proc(l: ^Layout, x: f32, y: f64) -> (pos: Position, ok: bool) {
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
	return Position{l.doc.starts[best.part] + best.slot, para.order, para.base + text.line_index_for_x(line.line, x - line.x)}, true
}

// The part of a line that is in the selection, as byte offsets in the
// source text of its paragraph. `block`: the number of its block.
@(private)
selected_part :: proc(para: ^Para, block: int, line: Line, from, to: Position) -> (start, end: int, ok: bool) {
	if para.src == nil {
		return
	}
	at := Position{block, para.order, 0}
	first, last := Position{from.block, from.order, 0}, Position{to.block, to.order, 0}
	if before(at, first) || before(last, at) {
		return
	}
	line_start, line_end := para.base + line.line.start, para.base + line.line.end
	start = at == first ? max(from.index, line_start) : line_start
	end = at == last ? min(to.index, line_end) : line_end
	return start, end, start < end
}

// Makes the highlight quads of the selection between y0 and y1 (points).
selection_quads :: proc(l: ^Layout, s: Selection, y0, y1: f64, scale: f32, origin_y: f64, out: ^[dynamic]base.Quad) {
	from, to, ok := selection_range(s)
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
			for i in box.line_first ..< box.line_end {
				line := part.lines[i]
				para := &part.paras[line.para]
				if line.top + para.line_height < top || line.top > bottom {
					continue // a long block: only its lines in the range
				}
				start, end := selected_part(para, block, line, from, to) or_continue
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

// The first and the last caret position of the document. It lays out the
// part that each of the two is in (`anchor_y` as for `lay_out`), not what
// is between them: a position says the same with no layout. `changed`:
// it made records.
select_all :: proc(l: ^Layout, anchor_y: f64) -> (s: Selection, changed: bool) {
	// The text line of a part that is the first or the last one.
	edge :: proc(l: ^Layout, p: int, last: bool) -> (block: int, para: Para, ok: bool) {
		part := &l.parts[p]
		for n in 0 ..< len(part.boxes) {
			slot := last ? len(part.boxes) - 1 - n : n
			box := part.boxes[slot]
			for m in 0 ..< box.line_end - box.line_first {
				line := part.lines[last ? box.line_end - 1 - m : box.line_first + m]
				if para = part.paras[line.para]; para.src != nil {
					return l.doc.starts[p] + slot, para, true
				}
			}
		}
		return
	}
	anchor := part_at(l, anchor_y)
	// From the first part down to one that has text.
	for p in 0 ..< len(l.parts) {
		changed |= lay_out_part(l, p, anchor)
		if block, para, ok := edge(l, p, false); ok {
			s.anchor = Position{block, para.order, para.base}
			s.active = true
			break
		}
	}
	// From the last part up. A document with text has an end too.
	for p := len(l.parts) - 1; p >= 0 && s.active; p -= 1 {
		changed |= lay_out_part(l, p, anchor)
		if block, para, ok := edge(l, p, true); ok {
			s.focus = Position{block, para.order, para.base + para.len}
			break
		}
	}
	return
}

// Appends the selected text to `out` as UTF-8, from the blocks that are
// laid out (`lay_out_blocks`). A new paragraph starts a new line; empty
// lines of a code block stay.
selection_text :: proc(l: ^Layout, s: Selection, out: ^[dynamic]u8) {
	from, to, ok := selection_range(s)
	if !ok || l.doc.count == 0 {
		return
	}
	// The number of a paragraph in reading order from the first block of
	// the selection: the numbers of the blocks before it, and its own.
	base, last := 0, -1
	p, slot := document.locate(l.doc, clamp(from.block, 0, l.doc.count - 1))
	for block := from.block; block <= to.block && p < len(l.parts); block += 1 {
		part := &l.parts[p]
		if slot < len(part.boxes) {
			box := part.boxes[slot]
			for line in part.lines[box.line_first:box.line_end] {
				para := &part.paras[line.para]
				start, end := selected_part(para, block, line, from, to) or_continue
				order := base + para.order
				if last >= 0 {
					for _ in 0 ..< order - last {
						append(out, '\n')
					}
				}
				last = order
				append(out, ..para.src.bytes[start:end])
			}
			base += box.orders
		}
		slot += 1
		if slot >= l.doc.parts[p].count {
			p, slot = p + 1, 0
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
