package layout

import "../text"

// Looks at all records of a layout and says what is wrong with them, or
// "" when they agree with each other and with the document. The layout
// keeps sums and ranges that it changes in place (the top of a part, the
// height of a part, the ranges of a box), and a wrong one shows only much
// later, as text at a wrong place. So the tests ask after each change,
// and a build with `-debug` (the tests are one) asks after each `lay_out`.
check :: proc(l: ^Layout) -> string {
	if l.doc == nil {
		return len(l.parts) == 0 ? "" : "parts with no document"
	}
	if len(l.parts) != len(l.doc.parts) {
		return "not a part for each part of the document"
	}
	if l.open >= len(l.parts) {
		return "the open part is no part"
	}
	// The first part is below the panel of front matter.
	top := l.origin + f64(l.panel.height)
	for &part, p in l.parts {
		if part.top != top {
			return "a part does not start where the part before it ends"
		}
		top += f64(part.height)
		count := l.doc.parts[p].count
		in_block, y := part.in_block, part.y
		if part.complete {
			if len(part.boxes) != count || in_block || p == l.open {
				return "a complete part does not have a closed box for each of its blocks"
			}
			if part.height != y {
				return "the height of a complete part is not the bottom of its last box"
			}
		} else if len(part.boxes) > count || (len(part.boxes) == count && !in_block) {
			return "a part that is not complete has all its boxes"
		}
		if p != l.open && (part.memory == nil) != (len(part.boxes) == 0) {
			return "the records of a part are not in its own memory"
		}
		bottom: f32
		lines, decor, paras := 0, 0, 0
		for box in part.boxes {
			if box.top < bottom || box.bottom < box.top {
				return "the boxes of a part do not go down the page"
			}
			if box.line_first != lines || box.line_end < lines || box.decor_first != decor || box.decor_end < decor || box.para_first != paras || box.para_end < paras {
				return "the records of a box do not come after the ones of the box before it"
			}
			if box.line_end > len(part.lines) || box.decor_end > len(part.decor) || box.para_end > len(part.paras) {
				return "a box has records that its part does not have"
			}
			for line in part.lines[box.line_first:box.line_end] {
				if line.para < box.para_first || line.para >= box.para_end {
					return "a line of a paragraph of another box"
				}
			}
			bottom, lines, decor, paras = box.bottom, box.line_end, box.decor_end, box.para_end
		}
		if lines != len(part.lines) || decor != len(part.decor) || paras != len(part.paras) {
			return "a part has records that are in no box"
		}
		if len(part.boxes) > 0 && y != bottom {
			return "the layout of a part is not at the bottom of its last box"
		}
		if part.height < y {
			return "a part is lower than what is laid out of it"
		}
		if len(part.boxes) == 0 && part.height != part.y + part.rest {
			return "a part with no records does not have its estimated height"
		}
		for line, i in part.lines {
			if line.para < 0 || line.para >= len(part.paras) {
				return "a line of no paragraph"
			}
			if text.line_shaped(line.line) && (i < part.live_first || i >= part.live_end) {
				return "a line with shaped text outside the range that is known to have some"
			}
		}
		task_y: f32 = -1e30
		for task in part.tasks {
			if task.block < 0 || task.block >= len(part.boxes) || task.y < task_y {
				return "the tasks of a part do not go down its blocks"
			}
			task_y = task.y
		}
	}
	if len(l.parts) > 0 && l.content_height != top - l.origin + f64(l.m.page_pad) {
		return "the page height is not the sum of the parts"
	}
	return ""
}
