package layout

import "../text"

// Looks at all records of a layout and says what is wrong with them, or
// "" when they agree with each other and with the document. The layout
// keeps sums and ranges that it changes in place (the top of a part, the
// height of a part, the ranges of a box), and a wrong one shows only much
// later, as text at a wrong place. So the tests ask after each change,
// and a build with debug information asks after each step.
check :: proc(l: ^Layout) -> string {
	if l.doc == nil {
		return len(l.parts) == 0 ? "" : "parts with no document"
	}
	if len(l.parts) > len(l.doc.parts) {
		return "more parts than the document has"
	}
	boxes := 0
	top: f64
	for &part, p in l.parts {
		last := p == len(l.parts) - 1
		if part.top != top {
			return "a part does not start where the part before it ends"
		}
		top += f64(part.height)
		count := l.doc.parts[p].count
		if len(part.boxes) > count || (!last && len(part.boxes) != count) {
			return "a part does not have a box for each of its blocks"
		}
		boxes += len(part.boxes)
		bottom: f32
		lines, decor := 0, 0
		for box in part.boxes {
			if box.top < bottom || box.bottom < box.top {
				return "the boxes of a part do not go down the page"
			}
			if box.line_first != lines || box.line_end < lines || box.decor_first != decor || box.decor_end < decor {
				return "the records of a box do not come after the ones of the box before it"
			}
			bottom, lines, decor = box.bottom, box.line_end, box.decor_end
		}
		if lines != len(part.lines) || decor != len(part.decor) {
			return "a part has records that are in no box"
		}
		if part.height != bottom {
			return "the height of a part is not the bottom of its last box"
		}
		for line, i in part.lines {
			if line.para < 0 || line.para >= len(part.paras) {
				return "a line of no paragraph"
			}
			if text.line_shaped(line.line) && (i < part.live_first || i >= part.live_end) {
				return "a line with shaped text outside the range that is known to have some"
			}
		}
		y: f32 = -1e30
		for task in part.tasks {
			if task.block < 0 || task.block >= len(part.boxes) || task.y < y {
				return "the tasks of a part do not go down its blocks"
			}
			y = task.y
		}
	}
	if boxes != l.next_block + (l.in_block ? 1 : 0) {
		return "the boxes are not the blocks that the layout reached"
	}
	if len(l.parts) > 0 && l.y != l.parts[len(l.parts) - 1].height {
		return "the layout is not at the bottom of its last part"
	}
	if boxes > 0 && l.content_height != reached(l) + f64(l.m.page_pad) {
		return "the page height is not the sum of the parts"
	}
	return ""
}
