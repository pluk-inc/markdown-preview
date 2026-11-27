package layout

import "../document"
import "../base"
import "../text"
import "core:math"
import "core:strings"

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

// The place of a reader: the line at the first height of the page that
// their view shows, and that height. A layout keeps none: the owner of a
// layout takes it from a frame (`take_place`) and gives it to the layout
// that comes after (`restore_place`).
Reader_Place :: struct {
	known: bool, // false at the top of the page, and with no text at the height
	place: Place,
	y:     f64, // the height of the page that the place was at
}

// The place of a reader whose view shows the page from the height y down.
// None at the top of the page: there the top stays the top, whatever the
// room above the first line is in another layout.
take_place :: proc(l: ^Layout, y: f64) -> Reader_Place {
	if y <= l.origin + 0.5 {
		return {}
	}
	place, ok := place_at(l, y)
	return {ok, place, y}
}

// After a new layout of the same document: lays out the block of the
// place, and moves the top of the page so that the place is at the height
// it had. The offset of the reader's view then shows the same text, with
// no new offset. With no place, the top of the page stays where it is.
restore_place :: proc(l: ^Layout, kept: Reader_Place) {
	if !kept.known {
		return
	}
	lay_out_block(l, kept.place.block)
	if y, ok := place_y(l, kept.place); ok {
		l.origin += kept.y - y
		sum_tops(l)
	}
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
				return {{block = l.doc.starts[p] + i, cell = document.cell_of(b, para.src), byte = para.base + line.line.start}, fraction}, true
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
	found := line_of_byte(part, box, b, src, place.byte)
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
	return {block = l.doc.starts[best.part] + best.slot, cell = document.cell_of(b, para.src), byte = para.base + text.line_index_for_x(line.line, x - line.x)}, true
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
	first := document.Address{block = block, cell = cell, byte = para.base + line.line.start}
	last := document.Address{block = block, cell = cell, byte = para.base + line.line.end}
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
	block: ^document.Block, // has the state of the task
	part:  ^document.Part, // of the block: the line of the task counts from it
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
				out[count] = {task.x, y, &l.doc.parts[p].blocks[task.block], l.doc.parts[p]}
			}
			count += 1
		}
	}
	return
}

// The line of a text of a block that has a byte of it: the last line of
// the text that starts at the byte or before it. -1 for a text with no
// line. `src` is the text; nil gives -1.
@(private)
line_of_byte :: proc(part: ^Part, box: Box, b: ^document.Block, src: ^document.Text, byte: int) -> (found: int) {
	found = -1
	if src != nil && b.kind != .Table {
		// The lines of the text are in the order of its bytes.
		lo, hi := text_first(part, box), box.line_end
		for lo < hi {
			mid := (lo + hi) / 2
			line := part.lines[mid]
			if part.paras[line.para].base + line.line.start <= byte {
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
			if para.src == src && para.base + line.line.start <= byte {
				found = i
			}
		}
	}
	return
}

// The address for a caret at a point of the page. As `hit_test`, and
// also at text that has no line: an empty line of a code block, and a
// block with no text (an item of a list with nothing in it, code in a
// fence with no line of code).
caret_hit :: proc(l: ^Layout, x: f32, y: f64) -> (at: document.Address, upstream: bool, ok: bool) {
	p := part_at(l, y)
	if p < 0 {
		return
	}
	part := &l.parts[p]
	from_top := f32(y - part.top)
	// A block with no text has no line that `hit_test` can find: it is
	// the place when its box is the one with the point, or the nearest
	// one to a point between two boxes.
	near, gap := -1, max(f32)
	for box, slot in part.boxes {
		away := from_top < box.top ? box.top - from_top : max(from_top - box.bottom, 0)
		if away < gap {
			near, gap = slot, away
		}
	}
	if near >= 0 {
		b := &l.doc.parts[p].blocks[near]
		// The empty paragraphs of a block are at the bottom of its box.
		if b.empties > 0 && near < blocks_done(part) {
			each := empty_height(l)
			if into := from_top - (part.boxes[near].bottom - f32(b.empties) * each); into >= 0 {
				n := clamp(int(into / each) + 1, 1, int(b.empties))
				if at, has := document.empty_address(l.doc, l.doc.starts[p] + near, n); has {
					return at, false, true
				}
			}
		}
		// Code in a fence with no line of code is such a block too.
		if (b.kind == .Paragraph || b.kind == .Heading || b.kind == .Code) && len(b.text.bytes) == 0 {
			return {block = l.doc.starts[p] + near}, false, true
		}
	}
	for box, slot in part.boxes {
		if from_top < box.top || from_top >= box.bottom {
			continue
		}
		b := &l.doc.parts[p].blocks[slot]
		block := l.doc.starts[p] + slot
		if b.kind != .Code {
			break
		}
		// The line of the point, counted from the last line with a
		// record above it: each empty line after that one is one line
		// break more in the text.
		height := math.round(l.m.code_size * CODE_LINE_HEIGHT)
		bytes := b.text.bytes[:]
		top, byte := box.top + CODE_PAD, 0
		for i in box.line_first ..< box.line_end {
			line := part.lines[i]
			para := &part.paras[line.para]
			if para.src != &b.text || line.top > from_top {
				continue
			}
			top, byte = line.top, para.base + line.line.end
		}
		down := int((from_top - top) / height)
		if byte > 0 {
			// Below a line with text: the point is in an empty line when
			// the bytes to it are line breaks, and the line itself ends
			// with one or with the text.
			if down < 1 {
				break
			}
			at := byte + down
			if at > len(bytes) || strings.count(string(bytes[byte:at]), "\n") != down || (at < len(bytes) && bytes[at] != '\n') {
				break
			}
			return {block = block, byte = at}, false, true
		}
		if down >= 0 && down < len(bytes) && strings.count(string(bytes[:down + 1]), "\n") == down + 1 {
			return {block = block, byte = down}, false, true
		}
		break
	}
	at = hit_test(l, x, y) or_return
	// The end of a line that goes on in the next line is the start of
	// that one too. For a point in the first of the two or above it,
	// the caret is at the end of that first line.
	if _, top, _, ok_down := caret_y(l, at, false); ok_down && top > y {
		_, top_up, _, _ := caret_y(l, at, true)
		upstream = top_up < top
	}
	return at, upstream, true
}

// Where a caret at an address of the document is: its x, the top of its
// line from the top of the part of its block, the height of the line,
// and that part. A byte where a line of a paragraph ends and the next
// one starts has two places: the start of the second line, and with
// `upstream` the end of the first one. False when the block has no
// records (`lay_out_block` makes them) or no text (a rule).
caret_place :: proc(l: ^Layout, at: document.Address, upstream := false) -> (x, top, height: f32, part_index: int, ok: bool) {
	x, top, height, _, _, part_index, ok = caret_spot(l, at, upstream)
	return
}

// `caret_place` with the bar of the caret in that line too (`caret_bar`):
// its top from the top of the part, and its height.
@(private)
caret_spot :: proc(l: ^Layout, at: document.Address, upstream: bool) -> (x, top, height, bar_top, bar_height: f32, part_index: int, ok: bool) {
	if l.doc == nil || at.block < 0 || at.block >= l.doc.count {
		return
	}
	p, slot := document.locate(l.doc, at.block)
	part := &l.parts[p]
	b := &l.doc.parts[p].blocks[slot]
	src := document.text_at(l.doc, at)
	if slot >= len(part.boxes) || src == nil {
		return
	}
	// A long code block can have its first lines only: the caret has a
	// place when its line is one of them.
	if slot >= blocks_done(part) && at.byte >= part.code_offset {
		return
	}
	box := part.boxes[slot]
	if n := document.empty_of(l.doc, at); n > 0 {
		// An empty paragraph: its line at the bottom of the box, where
		// a paragraph of the page starts.
		// It is a line of body text, whatever its block is (a heading).
		height = text_line_height(l, nil)
		top = box.bottom - height - f32(int(b.empties) - n) * empty_height(l)
		bar_top, bar_height = caret_bar(l, nil, top, height)
		return l.column_x, top, height, bar_top, bar_height, p, true
	}
	found := caret_line(part, box, b, src, at.byte, upstream)
	if found < 0 {
		// Text with no line: an empty paragraph, or the empty lines at
		// the start of a code block. At the start of the block.
		x = l.column_x + list_x(l, b) + f32(b.quote_depth) * l.m.quote_indent
		top = box.top
		// A heading with no text keeps the line of its level
		// (`place_para`), so the caret does not move when the first
		// character comes.
		height = text_line_height(l, b)
		if b.kind == .Code {
			height = math.round(l.m.code_size * CODE_LINE_HEIGHT)
			x += CODE_PAD
			top += CODE_PAD + height * f32(strings.count(string(src.bytes[:min(at.byte, len(src.bytes))]), "\n"))
		}
		bar_top, bar_height = caret_bar(l, b, top, height)
		return x, top, height, bar_top, bar_height, p, true
	}
	line := shaped_line(l, p, found)^
	para := &part.paras[line.para]
	height = para.line_height
	end := para.base + line.line.end
	if at.byte > end && para.mono {
		// An empty line of a code block has no line record: it is below
		// the last line that has one, one line for each line break.
		breaks := strings.count(string(src.bytes[end:min(at.byte, len(src.bytes))]), "\n")
		top = line.top + height * f32(breaks)
		bar_top, bar_height = caret_bar(l, b, top, height)
		return line.x, top, height, bar_top, bar_height, p, true
	}
	x = line.x + text.line_x_for_index(line.line, min(at.byte, end) - para.base)
	// On the line that the text of this line stands on, which a larger
	// font in it (a fallback font) can move.
	baseline := line_baseline(line.top, height, line.line.ascent, line.line.descent)
	bar_top, bar_height = caret_bar(l, b, line.top, height, baseline)
	return x + caret_spaces(l, at, x), line.top, height, bar_top, bar_height, p, true
}

// The line that a caret at a byte of a text is in (`line_of_byte`), or
// with `upstream` the line before it, when that one ends at the byte
// and is of the same paragraph.
@(private)
caret_line :: proc(part: ^Part, box: Box, b: ^document.Block, src: ^document.Text, byte: int, upstream: bool) -> int {
	found := line_of_byte(part, box, b, src, byte)
	if upstream && found > box.line_first {
		line, before := part.lines[found], part.lines[found - 1]
		base := part.paras[line.para].base
		if before.para == line.para && base + line.line.start == byte && base + before.line.end == byte {
			return found - 1
		}
	}
	return found
}

// How far right of `x` a caret is that is after spaces at the end of
// the text of its block (`Address.spaces`), in the font of that text.
// Not out of the column: the spaces at the end of a full line do not
// go to a next line, and the caret stays in the page.
@(private)
caret_spaces :: proc(l: ^Layout, at: document.Address, x: f32) -> f32 {
	count := document.spaces_of(l.doc, at)
	if count <= 0 {
		return 0
	}
	runs := [1]text.Run{{0, 1, block_font(l, document.block_at(l.doc, at.block))}}
	space := text.paragraph_create(" ", runs[:])
	defer text.paragraph_destroy(space)
	return clamp(f32(count) * text.paragraph_natural_width(space), 0, max(l.column_x + l.column - x, 0))
}

// `caret_place` with the top of the line as a height of the page.
caret_y :: proc(l: ^Layout, at: document.Address, upstream: bool) -> (x: f32, y: f64, height: f32, ok: bool) {
	top: f32
	p: int
	x, top, height, p = caret_place(l, at, upstream) or_return
	return x, l.parts[p].top + f64(top), height, true
}

// The place for a caret one line above or below a caret, as near to the
// x `goal` as that line has a place. False when the caret has no place,
// and when what is laid out has no line of text there: the caret is in
// the first or the last line.
caret_line_step :: proc(l: ^Layout, at: document.Address, upstream: bool, goal: f32, down: bool) -> (next: document.Address, next_upstream: bool, ok: bool) {
	_, here, height := caret_y(l, at, upstream) or_return
	// A point above the line or below it; then farther, over what is
	// between two blocks, until the nearest text is of another line.
	// The steps are less than a line, so no line is left out: a block
	// with no text is found only by a point in it.
	reach := f64(max(height / 2, 4))
	for probe := down ? here + f64(height) + 1 : here - 1; probe >= l.origin && probe <= l.origin + l.content_height; probe += down ? reach : -reach {
		next, next_upstream = caret_hit(l, goal, probe) or_return
		_, y, _ := caret_y(l, next, next_upstream) or_return
		if down ? y > here : y < here {
			return next, next_upstream, true
		}
	}
	return {}, false, false
}

// The place at the start or at the end of the line that a caret is in.
// The end of a line that goes on in the next line is the byte where
// that one starts, with `upstream`. False when the caret has no place.
caret_line_end :: proc(l: ^Layout, at: document.Address, upstream: bool, end: bool) -> (next: document.Address, next_upstream: bool, ok: bool) {
	_, _, _, p := caret_place(l, at, upstream) or_return
	// An empty paragraph is a line with one place.
	if document.empty_of(l.doc, at) > 0 {
		return at, false, true
	}
	_, slot := document.locate(l.doc, at.block)
	part := &l.parts[p]
	src := document.text_at(l.doc, at)
	bytes := src.bytes[:]
	next = at
	next.spaces = 0
	found := caret_line(part, part.boxes[slot], &l.doc.parts[p].blocks[slot], src, at.byte, upstream)
	line_start, line_end := 0, -1
	if found >= 0 {
		line := part.lines[found]
		base := part.paras[line.para].base
		line_start, line_end = base + line.line.start, base + line.line.end
	}
	if at.byte > line_end {
		// An empty line of a code block, or a text with no line: from
		// the line break before the byte to the one after it.
		next.byte = document.paragraph_end(bytes, at.byte, end)
		return next, false, true
	}
	if !end {
		next.byte = line_start
		return next, false, true
	}
	next.byte = line_end
	if line_end > line_start && bytes[line_end - 1] == '\n' {
		// The line break is the end of a line of code.
		next.byte = line_end - 1
	} else if line_end < len(bytes) && bytes[line_end] != '\n' {
		next_upstream = true
	}
	// The end of the last line of a text is after the spaces that the
	// source has there.
	return document.with_end_spaces(l.doc, next), next_upstream, true
}

// Where a caret is in a document with no block: where the first line of
// its first paragraph starts when text comes. `top` is from the top of
// the page (`Layout.origin`).
caret_place_empty :: proc(l: ^Layout) -> (x, top, height: f32) {
	return l.column_x, part_start(l, 0), text_line_height(l, nil)
}

// The bar of a caret in a line of the page: as high as the font of the
// text of the line (from the top of its tall letters to the bottom of the
// ones that go below the line), where that text stands in the line. Not
// the height of the line: with a wide line spacing that is much more
// than the text, and the text views of the system draw the caret as high
// as the text, larger in a heading. `b` is the block of the line; nil
// for a line of body text with no block. `baseline` is the line that the
// text stands on, for a line that has shaped text; with none, the text
// is in the middle of the line (`line_baseline`).
@(private)
caret_bar :: proc(l: ^Layout, b: ^document.Block, top, line_height: f32, baseline: Maybe(f32) = nil) -> (bar_top, bar_height: f32) {
	text_font := block_font(l, b)
	if text_font == nil {
		return top, line_height
	}
	ascent, descent, _ := text.font_metrics(text_font)
	bar_height = min(ascent + descent, line_height)
	base_y := baseline.? or_else line_baseline(top, line_height, ascent, descent)
	return clamp(base_y - ascent, top, top + line_height - bar_height), bar_height
}

// The font of the plain text of a block: the code font in a code block,
// the font of its level in a heading, the body font in each other one and
// for no block.
@(private)
block_font :: proc(l: ^Layout, b: ^document.Block) -> base.Font {
	if b != nil && b.kind == .Code {
		return font(l, .Mono, l.m.code_size)
	}
	heading := b != nil && b.kind == .Heading
	return span_font(l, {}, l.m.body * HEADING_SCALE[heading ? b.level : 0], heading)
}

// The height of a line of the text of a paragraph or of a heading; of
// body text for no block.
@(private)
text_line_height :: proc(l: ^Layout, b: ^document.Block) -> f32 {
	if b != nil && b.kind == .Heading {
		return l.m.body * HEADING_SCALE[b.level] * HEADING_LINE_HEIGHT
	}
	return math.round(l.m.body * l.m.line_height)
}

// `caret_y` for the bar of the caret (`caret_bar`): what a host shows.
caret_bar_y :: proc(l: ^Layout, at: document.Address, upstream: bool) -> (x: f32, y: f64, height: f32, ok: bool) {
	lx, _, _, bar_top, bar_height, p := caret_spot(l, at, upstream) or_return
	return lx, l.parts[p].top + f64(bar_top), bar_height, true
}

// `caret_place_empty` for the bar of the caret.
caret_bar_empty :: proc(l: ^Layout) -> (x, top, height: f32) {
	line_height: f32
	x, top, line_height = caret_place_empty(l)
	top, height = caret_bar(l, nil, top, line_height)
	return
}

// The quad of the caret of a document with no block, as `caret_quad`.
caret_quad_empty :: proc(l: ^Layout, scale: f32, origin_y: f64, out: ^[dynamic]base.Quad) {
	x, top, height := caret_bar_empty(l)
	append(out, rect_quad(x - 0.5, top, max(1, 2 / scale), height, l.style.text, 0, scale, l.origin, origin_y))
}

// The quad of a caret at an address, in the display space of
// `selection_quads`. Nothing when the caret has no place.
caret_quad :: proc(l: ^Layout, at: document.Address, upstream: bool, y0, y1: f64, scale: f32, origin_y: f64, out: ^[dynamic]base.Quad) {
	// Not for a caret whose block is out of the range that is shown:
	// its place needs the shaped text of its line.
	if l.doc == nil || at.block < 0 || at.block >= l.doc.count {
		return
	}
	part_index, slot := document.locate(l.doc, at.block)
	part := &l.parts[part_index]
	if slot >= len(part.boxes) || part.top + f64(part.boxes[slot].bottom) < y0 || part.top + f64(part.boxes[slot].top) > y1 {
		return
	}
	x, _, _, top, height, p, ok := caret_spot(l, at, upstream)
	if !ok {
		return
	}
	// One point wide at least, and two device pixels.
	append(out, rect_quad(x - 0.5, top, max(1, 2 / scale), height, l.style.text, 0, scale, l.parts[p].top, origin_y))
}
