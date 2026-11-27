package layout

import "../base"
import "../document"
import "../text"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private = "file")
SOURCE :: "# Title\n\nFirst paragraph with `code` and some more words to wrap over lines.\n\n- one\n- two\n\n```\nline 1\n\n\n\n\nline 6\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nLast é 😀 paragraph.\n"

@(private = "file")
Fixture :: struct {
	doc:   document.Document,
	style: base.Style,
	page:  Layout,
}

@(private = "file")
setup :: proc(f: ^Fixture, source: string, width: f32) {
	f.doc = document.parse(source)
	f.style = base.Style {
		body_font    = text.font_system(.Regular, 15),
		bold_font    = text.font_system(.Bold, 15),
		heading_font = text.font_system(.Semibold, 15),
		code_font    = text.font_system(.Mono, 15),
		body_size    = 15,
		line_height  = 1.6,
		page_padding = 40,
	}
	begin(&f.page, &f.doc, f.style, width)
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	destroy(&f.page)
	document.destroy(&f.doc)
	for font in ([4]base.Font{f.style.body_font, f.style.bold_font, f.style.heading_font, f.style.code_font}) {
		text.font_release(font)
	}
}

// Lays out from the top of the page down to a height, as a reader does
// who goes down the document.
@(private = "file")
step :: proc(l: ^Layout, until: f64) -> bool {
	return lay_out(l, -1e30, until, 0)
}

// The selection of all of the document.
@(private = "file")
all :: proc(l: ^Layout) -> document.Selection {
	return document.select_all(l.doc)
}

// The records of a document that has one part: its tops count from the
// top of the page.
@(private = "file")
only :: proc(l: ^Layout) -> ^Part {
	assert(len(l.parts) == 1)
	return &l.parts[0]
}

@(test)
test_boxes_go_down_the_page :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	testing.expect(t, done(&f.page))
	testing.expect_value(t, len(only(&f.page).boxes), f.doc.count)
	bottom: f32
	for box in only(&f.page).boxes {
		testing.expect(t, box.top >= bottom)
		testing.expect(t, box.bottom > box.top)
		bottom = box.bottom
	}
	testing.expect(t, f.page.content_height > f64(bottom))
}

@(test)
test_steps_give_the_same_layout :: proc(t: ^testing.T) {
	whole, parts: Fixture
	setup(&whole, SOURCE, 600)
	defer teardown(&whole)
	setup(&parts, SOURCE, 600)
	defer teardown(&parts)
	step(&whole.page, 1e30)
	for until: f64 = 40; !done(&parts.page); until += 40 {
		step(&parts.page, until)
	}
	testing.expect_value(t, len(only(&parts.page).lines), len(only(&whole.page).lines))
	testing.expect_value(t, parts.page.content_height, whole.page.content_height)
}

@(test)
test_narrow_page_has_more_lines :: proc(t: ^testing.T) {
	wide, narrow: Fixture
	setup(&wide, SOURCE, 900)
	defer teardown(&wide)
	setup(&narrow, SOURCE, 260)
	defer teardown(&narrow)
	step(&wide.page, 1e30)
	step(&narrow.page, 1e30)
	testing.expect(t, len(only(&narrow.page).lines) > len(only(&wide.page).lines))
}

@(test)
test_select_all_copies_the_text :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	out: [dynamic]u8
	defer delete(out)
	document.selection_text(&f.doc, all(&f.page), &out)
	expected := "Title\nFirst paragraph with code and some more words to wrap over lines.\none\ntwo\nline 1\n\n\n\n\nline 6\na\nb\n1\n2\nLast é 😀 paragraph."
	testing.expect_value(t, string(out[:]), expected)
}

@(test)
test_hit_test_finds_the_line :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	// A point in the last line gives a position in the last paragraph, on a
	// character boundary of its UTF-8 text.
	last := only(&f.page).lines[len(only(&f.page).lines) - 1]
	para := &only(&f.page).paras[last.para]
	pos, ok := hit_test(&f.page, last.x + last.line.width - 1, f64(last.top + 2))
	testing.expect(t, ok)
	testing.expect(t, document.text_at(&f.doc, pos) == para.src)
	testing.expect(t, pos.byte > 0 && pos.byte <= len(para.src.bytes))
	// A point far below the page still gives the last line.
	below, _ := hit_test(&f.page, 0, f.page.content_height + 5000)
	testing.expect(t, document.text_at(&f.doc, below) == para.src)
}

@(test)
test_hit_test_looks_past_blocks_without_text :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "***\n\n***\n\ntext\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	_, ok := hit_test(&f.page, 100, f64(only(&f.page).boxes[0].top))
	testing.expect(t, ok)
}

@(test)
test_marker_of_an_item_that_starts_with_code :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "1. ```\n   code\n   ```\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	markers := 0
	for para in only(&f.page).paras {
		if para.src == nil {
			markers += 1
		}
	}
	testing.expect_value(t, markers, 1)
}

@(test)
test_display_makes_quads_only_for_the_range :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	cache: text.Glyph_Cache
	defer text.cache_destroy(&cache)
	text.cache_set_scale(&cache, 2)
	rects, glyphs: [dynamic]base.Quad
	scratch: text.Glyph_Buffer
	defer delete(rects)
	defer delete(glyphs)
	defer text.glyph_buffer_destroy(&scratch)
	display(&f.page, &cache, 0, 1e30, 0, &rects, &glyphs, &scratch)
	all := len(glyphs)
	testing.expect(t, all > 60)
	testing.expect(t, len(rects) > 0)
	clear(&rects)
	clear(&glyphs)
	display(&f.page, &cache, 0, f64(only(&f.page).boxes[0].bottom), 0, &rects, &glyphs, &scratch)
	testing.expect(t, len(glyphs) > 0 && len(glyphs) < all)
	clear(&glyphs)
	display(&f.page, &cache, f.page.content_height + 10, f.page.content_height + 500, 0, &rects, &glyphs, &scratch)
	testing.expect_value(t, len(glyphs), 0)
}

@(private = "file")
shaped_lines :: proc(l: ^Layout) -> (count: int) {
	for part in l.parts {
		for line in part.lines {
			count += text.line_shaped(line.line) ? 1 : 0
		}
	}
	return
}

@(test)
test_only_the_window_keeps_shaped_text :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	// A window on the first block only; the steps release the rest.
	keep(&f.page, 0, 30)
	for until: f64 = 40; !done(&f.page); until += 40 {
		step(&f.page, until)
	}
	first := only(&f.page).boxes[0]
	testing.expect_value(t, shaped_lines(&f.page), first.line_end - first.line_first)
	for para in only(&f.page).paras {
		inside := para.src == &document.block_at(&f.doc, 0).text
		testing.expect_value(t, para.handle != nil, inside)
	}
	// The copied text needs no shaped text.
	out: [dynamic]u8
	defer delete(out)
	document.selection_text(&f.doc, all(&f.page), &out)
	testing.expect(t, len(out) > 100)
	// A point in a released line shapes that line.
	last := only(&f.page).lines[len(only(&f.page).lines) - 1]
	pos, ok := hit_test(&f.page, last.x + 20, f64(last.top + 2))
	testing.expect(t, ok)
	testing.expect(t, pos.byte > 0)
	testing.expect(t, text.line_shaped(only(&f.page).lines[len(only(&f.page).lines) - 1].line))
	// The window moves away: all of it is released.
	keep(&f.page, -20, -10)
	testing.expect_value(t, shaped_lines(&f.page), 0)
	for para in only(&f.page).paras {
		testing.expect(t, para.handle == nil)
	}
}

@(test)
test_a_long_code_block_is_released_line_by_line :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "```\na\nb\nc\nd\ne\nf\ng\nh\n```\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	testing.expect_value(t, shaped_lines(&f.page), 8)
	third := only(&f.page).lines[2]
	keep(&f.page, f64(third.top + 1), f64(third.top + 2))
	testing.expect_value(t, shaped_lines(&f.page), 1)
	testing.expect(t, text.line_shaped(only(&f.page).lines[2].line))
}

@(test)
test_released_text_has_the_same_glyphs_again :: proc(t: ^testing.T) {
	whole, windowed: Fixture
	setup(&whole, SOURCE, 600)
	defer teardown(&whole)
	setup(&windowed, SOURCE, 600)
	defer teardown(&windowed)
	step(&whole.page, 1e30)
	keep(&windowed.page, -20, -10) // nothing stays shaped
	step(&windowed.page, 1e30)
	testing.expect_value(t, shaped_lines(&windowed.page), 0)

	cache: text.Glyph_Cache
	defer text.cache_destroy(&cache)
	text.cache_set_scale(&cache, 2)
	rects, glyphs, restored: [dynamic]base.Quad
	scratch: text.Glyph_Buffer
	defer delete(rects)
	defer delete(glyphs)
	defer delete(restored)
	defer text.glyph_buffer_destroy(&scratch)
	display(&whole.page, &cache, 0, 1e30, 0, &rects, &glyphs, &scratch)
	display(&windowed.page, &cache, 0, 1e30, 0, &rects, &restored, &scratch)
	testing.expect_value(t, len(restored), len(glyphs))
	for quad, i in glyphs {
		testing.expect_value(t, restored[i].pos, quad.pos)
		testing.expect_value(t, restored[i].uv, quad.uv)
	}
}

@(test)
test_a_task_keeps_a_place_for_its_check_box :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "- [ ] one\n- [x] two\n- plain\n- [ ] three\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	// The plain item has none.
	testing.expect_value(t, len(only(&f.page).tasks), 3)
	one, two := only(&f.page).tasks[0], only(&f.page).tasks[1]
	// A task knows its block, which has its line and its state.
	testing.expect_value(t, one.block, 0)
	testing.expect_value(t, two.block, 1)
	testing.expect_value(t, only(&f.page).tasks[2].block, 3)
	testing.expect(t, two.y > one.y)
	// The box stands left of the text of its item, and the layout draws
	// nothing in its place.
	first := only(&f.page).lines[only(&f.page).boxes[0].line_first]
	size := task_box_size(f.page.m)
	testing.expect(t, one.x + size < first.x)
	for task in ([]int{0, 1, 3}) {
		box := only(&f.page).boxes[task]
		testing.expect_value(t, box.decor_end, box.decor_first)
	}
	// The plain item has its bullet: a circle a quarter of the body size
	// across, a little in from the edge of the step of its list (where the
	// "-" of its "- " is), in the color of the text.
	// Its middle is a little above the middle of the small letters, and
	// the middle of a check box is at the same height in its line.
	plain := only(&f.page).boxes[2]
	testing.expect_value(t, plain.decor_end - plain.decor_first, 1)
	bullet := only(&f.page).decor[plain.decor_first]
	text_line := only(&f.page).lines[plain.line_first]
	body := f.page.m.body
	testing.expect_value(t, bullet.w, 0.25 * body)
	testing.expect_value(t, bullet.h, bullet.w)
	testing.expect_value(t, bullet.radius, bullet.w / 2)
	testing.expect_value(t, bullet.x, text_line.x - f.page.m.list_indent + 0.8 * body)
	line_height := only(&f.page).paras[text_line.para].line_height
	ascent, descent, x_height := text.font_metrics(f.style.body_font)
	baseline := (line_height - (ascent + descent)) / 2 + ascent
	middle := bullet.y + bullet.h / 2 - text_line.top
	testing.expect(t, abs(middle - (baseline - 0.6 * x_height)) < 0.01)
	testing.expect(t, middle > line_height / 2 && middle < baseline - x_height / 2)
	testing.expect(t, abs(one.y + size / 2 - first.top - middle) < 0.01)
	testing.expect_value(t, bullet.color, f.page.style.text)
	// It is drawn from the pixel of the line that its text stands on:
	// of one size and at one distance from that line, at each height of
	// the page. The line is the one of the text itself, which gets a
	// move down the page with an addition of its own: the distance that
	// the bullet keeps is not from a sum of its own.
	testing.expect(t, abs(bullet.y + bullet.to_baseline - text_line.top - baseline) < 0.01)
	testing.expect_value(t, mark_baseline(&f.page, 0, plain, bullet), line_baseline(text_line.top, line_height, text_line.line.ascent, text_line.line.descent))
	first_quad := mark_quad(bullet, text_line.top + baseline, bullet.color, 2, 0, 0)
	for step in 1 ..< 40 {
		moved := bullet
		moved.y += f32(step) * 0.37
		text_top := text_line.top + f32(step) * 0.37
		text_baseline := line_baseline(text_top, line_height, ascent, descent)
		for top in ([]f64{0, f64(step) * 0.13}) {
			quad := mark_quad(moved, text_baseline, bullet.color, 2, top, 0)
			testing.expect_value(t, quad.size, first_quad.size)
			testing.expect_value(t, page_pixel(top, text_baseline, 2) - f64(quad.pos.y), page_pixel(0, text_line.top + baseline, 2) - f64(first_quad.pos.y))
		}
	}
	testing.expect_value(t, first_quad.size.x, first_quad.size.y)
	// A list item that starts with code whose first lines are empty:
	// those lines have no record, and the bullet stays beside the first
	// of them, not beside the first line with text.
	code: Fixture
	setup(&code, "- ```\n\n\n  text\n  ```\n", 600)
	defer teardown(&code)
	step(&code.page, 1e30)
	code_box := only(&code.page).boxes[0]
	code_bullet := only(&code.page).decor[code_box.decor_end - 1]
	testing.expect(t, code_bullet.to_baseline > 0)
	code_line := only(&code.page).lines[code_box.line_first]
	testing.expect(t, code_line.top > code_bullet.y + code_bullet.h)
	testing.expect_value(t, mark_baseline(&code.page, 0, code_box, code_bullet), code_bullet.y + code_bullet.to_baseline)
	// Only the box that a range touches.
	found: [4]Task_Place
	testing.expect_value(t, tasks_between(&f.page, f64(two.y + 1), f64(two.y + size - 1), found[:]), 1)
	testing.expect(t, found[0].block == document.block_at(&f.doc, 1))
	// On a whole point of the page, for the control of the host.
	testing.expect_value(t, found[0].y, math.round(f64(two.y)))
	testing.expect_value(t, tasks_between(&f.page, 0, 1e30, found[:]), 3)
	testing.expect_value(t, tasks_between(&f.page, math.round(f64(only(&f.page).tasks[2].y)) + f64(size), 1e30, found[:]), 0)
	// All of them are counted when the caller has room for fewer.
	testing.expect_value(t, tasks_between(&f.page, 0, 1e30, found[:1]), 3)
}

@(test)
test_a_task_checked_in_place_draws_as_one_parsed_checked :: proc(t: ^testing.T) {
	// The text of a checked item is softer, also its line through text
	// and the text of a later paragraph of the item. A link keeps its color.
	OPEN :: "- [ ] one ~~two~~ [three](https://example.com)\n\n  more\n- [ ] other\n"
	DONE :: "- [x] one ~~two~~ [three](https://example.com)\n\n  more\n- [ ] other\n"
	changed, parsed: Fixture
	setup(&changed, OPEN, 600)
	defer teardown(&changed)
	setup(&parsed, DONE, 600)
	defer teardown(&parsed)
	for f in ([]^Fixture{&changed, &parsed}) {
		f.page.style.text = {0, 0, 0, 255}
		f.page.style.secondary = {200, 200, 200, 255}
		f.page.style.link = {0, 0, 255, 255}
		step(&f.page, 1e30)
	}
	// After the layout, with no new one.
	testing.expect(t, document.set_task_done(&changed.doc, 1, true))

	cache: text.Glyph_Cache
	defer text.cache_destroy(&cache)
	text.cache_set_scale(&cache, 2)
	rects, glyphs, want_rects, want_glyphs: [dynamic]base.Quad
	scratch: text.Glyph_Buffer
	defer delete(rects)
	defer delete(glyphs)
	defer delete(want_rects)
	defer delete(want_glyphs)
	defer text.glyph_buffer_destroy(&scratch)
	display(&changed.page, &cache, 0, 1e30, 0, &rects, &glyphs, &scratch)
	display(&parsed.page, &cache, 0, 1e30, 0, &want_rects, &want_glyphs, &scratch)
	testing.expect_value(t, len(glyphs), len(want_glyphs))
	soft := 0
	for quad, i in want_glyphs {
		testing.expect_value(t, glyphs[i].pos, quad.pos)
		testing.expect_value(t, glyphs[i].color, quad.color)
		soft += quad.color == mix(changed.page.style.secondary, changed.page.style.text, 0.3) ? 1 : 0
	}
	// The soft color is there: the item's text, the line through it, "more".
	testing.expect(t, soft > 8)
}

@(test)
test_the_page_width_is_the_wanted_part_of_the_view :: proc(t: ^testing.T) {
	testing.expect_value(t, page_width(800, 600), 600)
	testing.expect_value(t, page_width(800, 400), 400)
	// All of the view when the host wants no part, and never more than it.
	testing.expect_value(t, page_width(800, 0), 800)
	testing.expect_value(t, page_width(800, 900), 800)
	// The layout breaks its lines in that width.
	SOURCE :: "Words that fill more than one line of a narrow page, and one line of a wide one, we hope.\n"
	wide, narrow: Fixture
	setup(&wide, SOURCE, page_width(800, 0))
	defer teardown(&wide)
	setup(&narrow, SOURCE, page_width(800, 300))
	defer teardown(&narrow)
	step(&wide.page, 1e30)
	step(&narrow.page, 1e30)
	testing.expect(t, len(only(&narrow.page).lines) > len(only(&wide.page).lines))
	for line in only(&narrow.page).lines {
		testing.expect(t, line.x + line.line.width <= 300)
	}
}

@(test)
test_only_a_line_of_text_is_text_for_the_pointer :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "First paragraph.\n\n- [ ] a task\n\nLast paragraph.\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	first := only(&f.page).lines[only(&f.page).boxes[0].line_first]
	item := only(&f.page).lines[only(&f.page).boxes[1].line_first]
	mid :: proc(l: ^Layout, line: Line) -> f64 {
		return f64(line.top + only(l).paras[line.para].line_height / 2)
	}
	// On the text, and right of its end on the same line.
	testing.expect(t, text_at(&f.page, first.x + 5, mid(&f.page, first)))
	testing.expect(t, text_at(&f.page, first.x + first.line.width + 50, mid(&f.page, first)))
	// Not in the margin right of the column.
	testing.expect(t, text_at(&f.page, f.page.column_x + f.page.column - 1, mid(&f.page, first)))
	testing.expect(t, !text_at(&f.page, f.page.column_x + f.page.column + 5, mid(&f.page, first)))
	// Not in the margin left of it, and not between two blocks.
	testing.expect(t, !text_at(&f.page, first.x - 5, mid(&f.page, first)))
	gap := f64(only(&f.page).boxes[0].bottom + only(&f.page).boxes[1].top) / 2
	testing.expect(t, only(&f.page).boxes[1].top > only(&f.page).boxes[0].bottom)
	testing.expect(t, !text_at(&f.page, first.x + 5, gap))
	// Not at the check box of the task, which is left of its text.
	box := only(&f.page).tasks[0]
	testing.expect(t, !text_at(&f.page, box.x + 2, mid(&f.page, item)))
	testing.expect(t, text_at(&f.page, item.x + 2, mid(&f.page, item)))
	// In a code block of many lines, and in a table: the same answers as
	// a look at each line.
	{
		g: Fixture
		setup(&g, "```\none\ntwo\nthree\nfour\nfive\n```\n\n| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\n- item\n", 600)
		defer teardown(&g)
		step(&g.page, 1e30)
		for box in only(&g.page).boxes {
			for line in only(&g.page).lines[box.line_first:box.line_end] {
				para := &only(&g.page).paras[line.para]
				at := f64(line.top + para.line_height / 2)
				testing.expect_value(t, text_at(&g.page, line.x + 1, at), para.src != nil)
				testing.expect(t, !text_at(&g.page, 2, at))
			}
		}
	}
	// A long number: its line comes before the text of the item and is no
	// text for the pointer.
	{
		g: Fixture
		setup(&g, "123456789. first line of the item\n   second paragraph of it\n", 600)
		defer teardown(&g)
		step(&g.page, 1e30)
		texts, marker_lines := 0, 0
		for box in only(&g.page).boxes {
			for line in only(&g.page).lines[box.line_first:box.line_end] {
				para := &only(&g.page).paras[line.para]
				if para.src == nil {
					marker_lines += 1
					continue
				}
				texts += 1
				testing.expect(t, text_at(&g.page, line.x + 1, f64(line.top + para.line_height / 2)))
			}
		}
		testing.expect(t, texts >= 1)
		testing.expect(t, marker_lines >= 1)
	}
	// Not above the page and not below it.
	testing.expect(t, !text_at(&f.page, first.x + 5, -10))
	testing.expect(t, !text_at(&f.page, first.x + 5, f.page.content_height + 100))
}

@(test)
test_a_place_is_the_same_text_at_another_width :: proc(t: ^testing.T) {
	// Long paragraphs, so the lines break at other bytes in another width.
	source := strings.repeat("One two three four five six seven eight nine ten eleven twelve. ", 12)
	defer delete(source)
	doc := strings.concatenate({"# Title\n\n", source, "\n\n- item ", source, "\n\n---\n\n| a | b |\n| - | - |\n| 1 | 2 |\n\n", source, "\n"})
	defer delete(doc)
	wide, narrow: Fixture
	setup(&wide, doc, 900)
	defer teardown(&wide)
	setup(&narrow, doc, 420)
	defer teardown(&narrow)
	step(&wide.page, 1e30)
	// Not in a layout that did not reach the block yet.
	_, early := place_y(&narrow.page, Place{at = {block = len(only(&wide.page).boxes) - 1}})
	testing.expect(t, !early)
	for line in only(&wide.page).lines {
		para := &only(&wide.page).paras[line.para]
		if para.src == nil {
			continue
		}
		// A height in the line: the place is that line.
		y := f64(line.top + para.line_height * 0.25)
		place, ok := place_at(&wide.page, y)
		testing.expect(t, ok)
		if document.block_at(&wide.doc, place.block).kind != .Table {
			testing.expect_value(t, place.byte, para.base + line.line.start)
			testing.expect(t, document.text_at(&wide.doc, place.at) == para.src)
		} else {
			// The first cell of the row at that height.
			testing.expect(t, document.text_at(&wide.doc, place.at) != nil)
		}
		// The same layout gives the height back.
		back, back_ok := place_y(&wide.page, place)
		testing.expect(t, back_ok)
		testing.expect(t, abs(back - y) < 0.01)
		// In another width: the line that has the same byte.
		lay_out_block(&narrow.page, place.block)
		there, there_ok := place_y(&narrow.page, place)
		testing.expect(t, there_ok)
		again, again_ok := place_at(&narrow.page, there)
		testing.expect(t, again_ok)
		testing.expect_value(t, again.block, place.block)
		testing.expect_value(t, again.cell, place.cell)
		testing.expect(t, again.byte <= place.byte)
	}
	// Between two blocks: the next line, from above it. Below the page: none.
	gap := f64(only(&wide.page).boxes[0].bottom + only(&wide.page).boxes[1].top) / 2
	between, _ := place_at(&wide.page, gap)
	testing.expect_value(t, between.block, 1)
	testing.expect(t, between.fraction < 0)
	_, below := place_at(&wide.page, wide.page.content_height + 100)
	testing.expect(t, !below)
}

@(test)
test_a_place_in_blank_lines_of_code_keeps_its_height :: proc(t: ^testing.T) {
	// Blank lines of a code block have no line of their own.
	f: Fixture
	setup(&f, "```\nA\n\n\n\n\n\n\n\n\n\n\n\n\nB\n```\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	box := only(&f.page).boxes[0]
	testing.expect_value(t, box.line_end - box.line_first, 2)
	a, b := only(&f.page).lines[box.line_first], only(&f.page).lines[box.line_first + 1]
	height := only(&f.page).paras[a.para].line_height
	testing.expect(t, b.top - a.top > 10 * height)
	// Near the start of the blank run, far above B.
	y := f64(a.top + 2.5 * height)
	place, ok := place_at(&f.page, y)
	testing.expect(t, ok)
	back, back_ok := place_y(&f.page, place)
	testing.expect(t, back_ok)
	testing.expect(t, abs(back - y) < 0.01)
}

@(test)
test_a_place_is_the_same_text_when_a_block_before_it_got_a_line :: proc(t: ^testing.T) {
	// Another app adds a line to a code block above the reader. The block
	// of the place and its text are as they were.
	TAIL :: "\n\nSome words of the paragraph that the reader is in, enough of them for more than one line of text in this width, and some more.\n"
	before, after: Fixture
	setup(&before, "```\none\ntwo\n```" + TAIL, 300)
	defer teardown(&before)
	setup(&after, "```\none\n\ninserted\ntwo\n```" + TAIL, 300)
	defer teardown(&after)
	step(&before.page, 1e30)
	step(&after.page, 1e30)
	// The last line of the paragraph.
	last := only(&before.page).lines[len(only(&before.page).lines) - 1]
	height := only(&before.page).paras[last.para].line_height
	place, ok := place_at(&before.page, f64(last.top + height / 2))
	testing.expect(t, ok)
	testing.expect_value(t, place.block, 1)
	there, there_ok := place_y(&after.page, place)
	testing.expect(t, there_ok)
	same := only(&after.page).lines[len(only(&after.page).lines) - 1]
	testing.expect(t, abs(there - f64(same.top + height / 2)) < 0.01)
}

// A document of more parts than one: paragraphs that wrap, some headings,
// tasks, a table, and a code block, many times.
@(private = "file")
long_source :: proc(sections: int) -> string {
	b := strings.builder_make()
	for i in 0 ..< sections {
		fmt.sbprintf(&b, "## Section %d\n\n", i)
		fmt.sbprintf(&b, "Paragraph %d with enough words in it to go over the end of a line in a narrow page, and `code`.\n\n", i)
		fmt.sbprintf(&b, "- [ ] open task %d\n- [x] done task %d\n- plain %d\n\n", i, i, i)
		fmt.sbprintf(&b, "| a%d | b |\n| - | - |\n| 1 | 2 |\n\n", i)
		fmt.sbprintf(&b, "```\ncode %d\n\nmore\n```\n\n", i)
	}
	return strings.to_string(b)
}

// Blocks for each section of `long_source`.
@(private = "file")
SECTION_BLOCKS :: 7

@(private = "file")
expect_ok :: proc(t: ^testing.T, l: ^Layout, loc := #caller_location) {
	testing.expect_value(t, check(l), "", loc)
}

@(test)
test_a_long_document_has_its_records_in_parts :: proc(t: ^testing.T) {
	source := long_source(40)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	testing.expect_value(t, f.doc.count, 40 * SECTION_BLOCKS)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	// A part of the layout for each part of the document, with a box for
	// each of its blocks, and each part starts where the one before ends.
	testing.expect_value(t, len(f.page.parts), len(f.doc.parts))
	testing.expect(t, len(f.page.parts) >= 4)
	for part, p in f.page.parts {
		testing.expect_value(t, len(part.boxes), f.doc.parts[p].count)
		testing.expect(t, part.height > 0)
		if p > 0 {
			before := f.page.parts[p - 1]
			testing.expect_value(t, part.top, before.top + f64(before.height))
		}
	}
	last := f.page.parts[len(f.page.parts) - 1]
	testing.expect_value(t, f.page.content_height, last.top + f64(last.height) + f64(f.page.m.page_pad))
}

@(test)
test_small_steps_give_the_same_parts :: proc(t: ^testing.T) {
	source := long_source(30)
	defer delete(source)
	whole, stepped: Fixture
	setup(&whole, source, 500)
	defer teardown(&whole)
	setup(&stepped, source, 500)
	defer teardown(&stepped)
	step(&whole.page, 1e30)
	// Steps that end in the middle of parts, and of code blocks.
	for until: f64 = 25; !done(&stepped.page); until += 25 {
		step(&stepped.page, until)
		expect_ok(t, &stepped.page)
	}
	testing.expect_value(t, stepped.page.content_height, whole.page.content_height)
	testing.expect_value(t, len(stepped.page.parts), len(whole.page.parts))
	for part, p in whole.page.parts {
		other := stepped.page.parts[p]
		testing.expect_value(t, other.top, part.top)
		testing.expect_value(t, other.height, part.height)
		testing.expect_value(t, len(other.lines), len(part.lines))
		testing.expect_value(t, len(other.decor), len(part.decor))
		testing.expect_value(t, len(other.tasks), len(part.tasks))
		for box, i in part.boxes {
			testing.expect_value(t, other.boxes[i], box)
		}
		for line, i in part.lines {
			testing.expect_value(t, other.lines[i].top, line.top)
			testing.expect_value(t, other.lines[i].x, line.x)
		}
	}
}

@(test)
test_a_place_in_a_later_part_has_the_number_of_its_block :: proc(t: ^testing.T) {
	source := long_source(40)
	defer delete(source)
	wide, narrow: Fixture
	setup(&wide, source, 800)
	defer teardown(&wide)
	setup(&narrow, source, 300)
	defer teardown(&narrow)
	step(&wide.page, 1e30)
	for &part, p in wide.page.parts {
		for box, i in part.boxes {
			block := wide.doc.starts[p] + i
			b := document.block_at(&wide.doc, block)
			if b.kind == .Table {
				continue
			}
			// The first line of the text of the block.
			line := part.lines[text_first(&part, box)]
			para := &part.paras[line.para]
			y := part.top + f64(line.top + para.line_height / 2)
			place, ok := place_at(&wide.page, y)
			testing.expect(t, ok)
			testing.expect_value(t, place.block, block)
			back, back_ok := place_y(&wide.page, place)
			testing.expect(t, back_ok)
			testing.expect(t, abs(back - y) < 0.01)
			testing.expect(t, text_at(&wide.page, line.x + 1, y))
			// The caret there is in the paragraph of that line.
			pos, hit := hit_test(&wide.page, line.x + 1, y)
			testing.expect(t, hit)
			testing.expect(t, document.text_at(&wide.doc, pos) == para.src)
		}
	}
	// The narrow layout is laid out only down to the place, in a later
	// part, and has the same text there.
	block := 3 * document.PART_BLOCKS + 1
	_, early := place_y(&narrow.page, Place{at = {block = block}})
	testing.expect(t, !early)
	lay_out_block(&narrow.page, block)
	expect_ok(t, &narrow.page)
	y, ok := place_y(&narrow.page, Place{at = {block = block}})
	testing.expect(t, ok)
	again, again_ok := place_at(&narrow.page, y)
	testing.expect(t, again_ok)
	testing.expect_value(t, again.block, block)
	testing.expect(t, !done(&narrow.page))
}

@(test)
test_the_tasks_of_all_parts_go_down_the_page :: proc(t: ^testing.T) {
	SECTIONS :: 40
	source := long_source(SECTIONS)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	step(&f.page, 1e30)
	found := make([]Task_Place, 2 * SECTIONS + 8)
	defer delete(found)
	testing.expect_value(t, tasks_between(&f.page, 0, 1e30, found), 2 * SECTIONS)
	size := f64(task_box_size(f.page.m))
	for task, i in found[:2 * SECTIONS] {
		// Open and done in turn, as the source has them.
		testing.expect_value(t, task.block.marker, i % 2 == 0 ? document.Marker.Task_Open : document.Marker.Task_Done)
		testing.expect_value(t, task.y, math.round(task.y))
		if i > 0 {
			testing.expect(t, task.y > found[i - 1].y)
		}
		// A range that has only this box gives only it, in each part.
		one: [2]Task_Place
		testing.expect_value(t, tasks_between(&f.page, task.y + 1, task.y + size - 1, one[:]), 1)
		testing.expect(t, one[0].block == task.block)
	}
	// A range over the border of two parts has the tasks of the two: from
	// the last task above the border to the first one below it.
	border := f.page.parts[1].top
	above := 0
	for found[above + 1].y < border {
		above += 1
	}
	two: [4]Task_Place
	testing.expect_value(t, tasks_between(&f.page, found[above].y, found[above + 1].y + size, two[:]), 2)
	testing.expect(t, two[0].block == found[above].block && two[1].block == found[above + 1].block)
}

@(test)
test_the_text_of_all_parts_is_copied_in_order :: proc(t: ^testing.T) {
	source := long_source(30)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	step(&f.page, 1e30)
	out: [dynamic]u8
	defer delete(out)
	document.selection_text(&f.doc, all(&f.page), &out)
	copied := string(out[:])
	at := 0
	for i in 0 ..< 30 {
		for want in ([]string{fmt.tprintf("Section %d\n", i), fmt.tprintf("open task %d\n", i), fmt.tprintf("a%d\n", i), fmt.tprintf("code %d\n\nmore", i)}) {
			found := strings.index(copied[at:], want)
			testing.expect(t, found >= 0)
			at += max(found, 0)
		}
	}
}

@(test)
test_a_range_in_a_later_part_shows_and_keeps_only_that_part :: proc(t: ^testing.T) {
	source := long_source(40)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	// The window is in the third part; the steps release the rest.
	step(&f.page, 1e30)
	third := f.page.parts[2]
	from, to := third.top + 10, third.top + f64(third.height) - 10
	keep(&f.page, from, to)
	expect_ok(t, &f.page)
	for part, p in f.page.parts {
		shaped := 0
		for line in part.lines {
			shaped += text.line_shaped(line.line) ? 1 : 0
		}
		testing.expect_value(t, shaped > 0, p == 2)
	}
	cache: text.Glyph_Cache
	defer text.cache_destroy(&cache)
	text.cache_set_scale(&cache, 2)
	rects, glyphs: [dynamic]base.Quad
	scratch: text.Glyph_Buffer
	defer delete(rects)
	defer delete(glyphs)
	defer text.glyph_buffer_destroy(&scratch)
	// The quads count from the origin, whatever the height of the page.
	origin := math.floor(from * 2)
	display(&f.page, &cache, from, to, origin, &rects, &glyphs, &scratch)
	testing.expect(t, len(glyphs) > 100)
	for quad in glyphs {
		testing.expect(t, quad.pos.y > -100 && f64(quad.pos.y) < (to - from) * 2 + 100)
	}
	expect_ok(t, &f.page)
}

@(test)
test_a_check_box_that_reaches_out_of_its_part_is_found :: proc(t: ^testing.T) {
	// One task for each block, and lines that are lower than a check box:
	// the box of the last task of a part ends below the part.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	COUNT :: 2 * document.PART_BLOCKS + 3
	for i in 0 ..< COUNT {
		fmt.sbprintf(&b, "- [ ] task %d\n", i)
	}
	f: Fixture
	setup(&f, strings.to_string(b), 500)
	defer teardown(&f)
	f.style.line_height = 0.6
	begin(&f.page, &f.doc, f.style, 500)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	found := make([]Task_Place, COUNT)
	defer delete(found)
	testing.expect_value(t, tasks_between(&f.page, 0, 1e30, found), COUNT)
	size := f64(task_box_size(f.page.m))
	first := f.page.parts[0]
	last := found[document.PART_BLOCKS - 1]
	testing.expect(t, last.y + size > first.top + f64(first.height))
	// Each box is found by its last point and by its first one.
	for task in found {
		one: [4]Task_Place
		count := tasks_between(&f.page, task.y + size - 1, task.y + size - 0.5, one[:])
		testing.expect(t, count >= 1 && one[0].block == task.block)
		count = tasks_between(&f.page, task.y, task.y + 0.5, one[:])
		testing.expect(t, count >= 1 && one[count - 1].block == task.block)
	}
}

// The lines of all parts, with their tops on the page from the top of
// the page.
@(private = "file")
page_lines :: proc(l: ^Layout) -> (lines: [dynamic]f64) {
	for part in l.parts {
		for line in part.lines {
			append(&lines, part.top - l.origin + f64(line.top), f64(line.x), f64(line.line.width))
		}
	}
	return
}

@(test)
test_a_new_layout_has_a_height_for_each_part_and_no_records :: proc(t: ^testing.T) {
	source := long_source(60)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	expect_ok(t, &f.page)
	testing.expect_value(t, len(f.page.parts), len(f.doc.parts))
	for part in f.page.parts {
		testing.expect(t, part.height > 0)
		testing.expect_value(t, len(part.boxes), 0)
	}
	estimated := f.page.content_height
	step(&f.page, 1e30)
	// The estimate is near the real height: the scroll bar of a document
	// that nobody went through is near the real one.
	testing.expect(t, abs(estimated - f.page.content_height) < 0.2 * f.page.content_height)
}

@(test)
test_a_view_far_down_lays_out_only_what_it_shows :: proc(t: ^testing.T) {
	source := long_source(60)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	// A view of 600 points at the middle of the page.
	y := f.page.content_height / 2
	testing.expect(t, lay_out(&f.page, y, y + 600, y))
	expect_ok(t, &f.page)
	with_records := 0
	for part in f.page.parts {
		with_records += len(part.boxes) > 0 ? 1 : 0
	}
	testing.expect(t, with_records >= 1 && with_records <= 3)
	testing.expect_value(t, len(f.page.parts[0].boxes), 0)
	// Text is there, and a caret in it.
	place, ok := place_at(&f.page, y + 300)
	testing.expect(t, ok)
	testing.expect(t, place.block > 0)
	_, hit := hit_test(&f.page, 200, y + 300)
	testing.expect(t, hit)
	// The same range again is no work.
	testing.expect(t, laid_out(&f.page, y, y + 600))
	testing.expect(t, !laid_out(&f.page, y, y + 6000))
	testing.expect(t, !lay_out(&f.page, y, y + 600, y))
	// The end of the document, with the view where it is: the last parts
	// get their real heights, and the text of the view stays.
	top := f.page.parts[part_at(&f.page, y)].top
	testing.expect(t, lay_out_end(&f.page, 1200, y))
	expect_ok(t, &f.page)
	last := f.page.parts[len(f.page.parts) - 1]
	testing.expect(t, last.complete)
	testing.expect_value(t, f.page.parts[part_at(&f.page, y)].top, top)
	testing.expect_value(t, f.page.origin, 0)
	testing.expect(t, !lay_out_end(&f.page, 1200, y))
}

@(test)
test_a_part_above_the_view_moves_the_top_of_the_page_not_the_view :: proc(t: ^testing.T) {
	source := long_source(60)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	y := f.page.content_height / 2
	lay_out(&f.page, y, y + 600, y)
	anchor := part_at(&f.page, y)
	top := f.page.parts[anchor].top
	bottom := f.page.origin + f.page.content_height
	testing.expect_value(t, f.page.origin, 0)
	// The reader goes up: the range now has the part above.
	above := f.page.parts[anchor - 1]
	testing.expect(t, lay_out(&f.page, above.top + f64(above.height) - 10, y + 600, y))
	expect_ok(t, &f.page)
	testing.expect(t, f.page.parts[anchor - 1].complete)
	// The part of the view and the end of the page are where they were.
	testing.expect_value(t, f.page.parts[anchor].top, top)
	testing.expect_value(t, f.page.origin + f.page.content_height, bottom)
	// The top of the page took the difference.
	testing.expect_value(t, f.page.origin, f64(above.height) - f64(f.page.parts[anchor - 1].height))
	testing.expect_value(t, f.page.parts[0].top, f.page.origin)
}

@(test)
test_parts_laid_out_in_any_order_give_the_same_page :: proc(t: ^testing.T) {
	source := long_source(40)
	defer delete(source)
	down, up, mixed: Fixture
	setup(&down, source, 500)
	defer teardown(&down)
	setup(&up, source, 500)
	defer teardown(&up)
	setup(&mixed, source, 500)
	defer teardown(&mixed)
	step(&down.page, 1e30)
	// From the last part to the first, with the view at the end.
	end: f64
	for p := len(up.page.parts) - 1; p >= 0; p -= 1 {
		lay_out_part(&up.page, p, len(up.page.parts) - 1)
		expect_ok(t, &up.page)
		if p == len(up.page.parts) - 1 {
			// The end of the page with the real height of the last part.
			end = up.page.origin + up.page.content_height
		}
	}
	// Some of one part, then another part, then the rest of the first:
	// the part goes out of work and comes back.
	lay_out(&mixed.page, 0, 150, 0)
	testing.expect(t, !mixed.page.parts[0].complete && len(mixed.page.parts[0].boxes) > 0)
	lay_out_part(&mixed.page, 2, 0)
	expect_ok(t, &mixed.page)
	testing.expect(t, mixed.page.parts[0].memory != nil)
	lay_out_part(&mixed.page, 0, 0)
	step(&mixed.page, 1e30)
	expect_ok(t, &mixed.page)

	want := page_lines(&down.page)
	defer delete(want)
	for f in ([]^Fixture{&up, &mixed}) {
		testing.expect(t, done(&f.page))
		testing.expect(t, abs(f.page.content_height - down.page.content_height) < 0.01)
		got := page_lines(&f.page)
		defer delete(got)
		testing.expect_value(t, len(got), len(want))
		for value, i in want {
			testing.expect(t, abs(got[i] - value) < 0.01)
		}
		// The text that is copied is the same too.
		a, b: [dynamic]u8
		defer delete(a)
		defer delete(b)
		document.selection_text(&down.doc, all(&down.page), &a)
		document.selection_text(&f.doc, all(&f.page), &b)
		testing.expect_value(t, string(b[:]), string(a[:]))
	}
	// With the view at the end, the end stayed where it was after the
	// last part, and the top of the page moved.
	testing.expect_value(t, up.page.origin + up.page.content_height, end)
	testing.expect(t, up.page.origin != 0)
}

@(test)
test_a_long_code_block_is_laid_out_down_to_the_view_only :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "```\n")
	for i in 0 ..< 3000 {
		fmt.sbprintf(&b, "line %d\n", i)
	}
	strings.write_string(&b, "```\n\nafter\n")
	f: Fixture
	setup(&f, strings.to_string(b), 500)
	defer teardown(&f)
	estimated := f.page.content_height
	lay_out(&f.page, 0, 600, 0)
	expect_ok(t, &f.page)
	part := f.page.parts[0]
	testing.expect(t, !part.complete)
	testing.expect(t, len(part.lines) > 10 && len(part.lines) < 200)
	// The card of the block is there for what is laid out of it.
	testing.expect_value(t, len(part.decor), 2)
	card := part.decor[1].h
	testing.expect(t, part.decor[1].y + card >= part.y)
	// The rest of the block is in the height as an estimate.
	testing.expect(t, abs(f.page.content_height - estimated) < 0.05 * estimated)
	// Farther down the same block: it goes on where it was.
	lay_out(&f.page, 3000, 3600, 3000)
	expect_ok(t, &f.page)
	testing.expect(t, len(f.page.parts[0].lines) > len(part.lines))
	testing.expect(t, f.page.parts[0].decor[1].h > card)
	step(&f.page, 1e30)
	testing.expect(t, done(&f.page))
	testing.expect_value(t, len(f.page.parts[0].lines), 3001)
	testing.expect(t, abs(f.page.content_height - estimated) < 0.05 * estimated)
}

@(test)
test_a_selection_needs_no_layout :: proc(t: ^testing.T) {
	source := long_source(40)
	defer delete(source)
	whole, far: Fixture
	setup(&whole, source, 500)
	defer teardown(&whole)
	setup(&far, source, 300)
	defer teardown(&far)
	step(&whole.page, 1e30)
	// A selection made in one layout: from a line of part 1 to a line of
	// part 3.
	a, _ := hit_test(&whole.page, 120, whole.page.parts[1].top + 40)
	b, _ := hit_test(&whole.page, 300, whole.page.parts[3].top + 200)
	testing.expect(t, document.before(a, b))
	selection := document.Selection{true, b, a}
	want, got: [dynamic]u8
	defer delete(want)
	defer delete(got)
	document.selection_text(&whole.doc, selection, &want)
	testing.expect(t, len(want) > 500)
	// The same addresses with a layout of another width that has no
	// records: the same text, and still no records.
	document.selection_text(&far.doc, selection, &got)
	testing.expect_value(t, string(got[:]), string(want[:]))
	for part in far.page.parts {
		testing.expect_value(t, len(part.boxes), 0)
	}
	// The highlight is made for the lines that a view shows, in a part
	// between the two ends: all of each line of text there.
	y := far.page.parts[2].top + 100
	lay_out(&far.page, y, y + 400, y)
	expect_ok(t, &far.page)
	quads: [dynamic]base.Quad
	defer delete(quads)
	selection_quads(&far.page, selection, y, y + 400, 2, 0, &quads)
	testing.expect(t, len(quads) > 5)
	// And none for a view outside the selection.
	clear(&quads)
	lay_out(&far.page, 0, 200, 0)
	expect_ok(t, &far.page)
	selection_quads(&far.page, selection, 0, 200, 2, 0, &quads)
	testing.expect_value(t, len(quads), 0)
}

@(test)
test_select_all_is_all_of_the_text_with_no_layout :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	all_text := document.select_all(&f.doc)
	testing.expect(t, all_text.active)
	testing.expect_value(t, all_text.anchor, document.Address{block = 0})
	// The last block is the paragraph after the table.
	last := f.doc.count - 1
	testing.expect_value(t, all_text.focus, document.Address{block = last, byte = len(document.block_at(&f.doc, last).text.bytes)})
	testing.expect_value(t, len(only(&f.page).boxes), 0)
	// A document with no text has no selection.
	empty: Fixture
	setup(&empty, "***\n\n***\n", 500)
	defer teardown(&empty)
	testing.expect(t, !document.select_all(&empty.doc).active)
}

@(test)
test_a_new_layout_puts_the_readers_place_at_the_height_it_had :: proc(t: ^testing.T) {
	source := long_source(60)
	defer delete(source)
	f: Fixture
	setup(&f, source, 800)
	defer teardown(&f)
	// A reader far down the page.
	y := f.page.content_height * 0.6
	lay_out(&f.page, y, y + 600, y)
	kept := take_place(&f.page, y)
	testing.expect(t, kept.known)
	testing.expect_value(t, kept.y, y)
	// Some widths one after the other, as a live resize gives them. The
	// place is taken one time, so the steps do not add up.
	for width in ([]f32{640, 500, 380, 300, 420, 800}) {
		begin(&f.page, &f.doc, f.style, width)
		restore_place(&f.page, kept)
		expect_ok(t, &f.page)
		// The same text is at the same height of the page, so a view at
		// the same offset shows it.
		at, ok := place_y(&f.page, kept.place)
		testing.expect(t, ok)
		testing.expect(t, abs(at - y) < 0.01)
		lay_out(&f.page, y, y + 600, y)
		again, found := place_at(&f.page, y)
		testing.expect(t, found)
		testing.expect_value(t, again.block, kept.place.block)
		testing.expect_value(t, again.cell, kept.place.cell)
		testing.expect(t, again.byte <= kept.place.byte)
		// Only the part of the place and what the view shows has records.
		testing.expect_value(t, len(f.page.parts[0].boxes), 0)
	}
	// The top of the page moved for it.
	testing.expect(t, f.page.origin != 0)
	testing.expect_value(t, f.page.parts[0].top, f.page.origin)
}

@(test)
test_a_reader_at_the_top_stays_at_the_top :: proc(t: ^testing.T) {
	source := long_source(20)
	defer delete(source)
	f: Fixture
	setup(&f, source, 800)
	defer teardown(&f)
	lay_out(&f.page, 0, 600, 0)
	// At the top, and a little into the room above the first line.
	testing.expect(t, !take_place(&f.page, 0).known)
	testing.expect(t, !take_place(&f.page, 0.4).known)
	kept := take_place(&f.page, 0)
	begin(&f.page, &f.doc, f.style, 300)
	restore_place(&f.page, kept)
	expect_ok(t, &f.page)
	testing.expect_value(t, f.page.origin, 0)
	// Below all of the text there is no place, and nothing moves.
	lay_out_end(&f.page, 600, 0)
	below := take_place(&f.page, f.page.origin + f.page.content_height + 50)
	testing.expect(t, !below.known)
}

@(test)
test_a_new_layout_keeps_the_top_of_the_page :: proc(t: ^testing.T) {
	source := long_source(60)
	defer delete(source)
	f: Fixture
	setup(&f, source, 500)
	defer teardown(&f)
	// The top of the page moved: a part above the view got its height.
	y := f.page.content_height / 2
	lay_out(&f.page, y, y + 600, y)
	anchor := part_at(&f.page, y)
	lay_out_part(&f.page, anchor - 1, anchor)
	origin := f.page.origin
	testing.expect(t, origin != 0)
	// A new layout with no place (a new document) starts where it was.
	begin(&f.page, &f.doc, f.style, 400)
	expect_ok(t, &f.page)
	testing.expect_value(t, f.page.origin, origin)
	testing.expect_value(t, f.page.parts[0].top, origin)
}

// Makes the document of a fixture the one of another source, in place.
@(private = "file")
change_to :: proc(f: ^Fixture, source: string) -> document.Change {
	change := document.apply(&f.doc, document.edit_between(f.doc.source, source))
	apply_change(&f.page, change)
	return change
}

@(test)
test_a_changed_block_lays_out_its_part_again_and_keeps_the_others :: proc(t: ^testing.T) {
	SECTIONS :: 60
	before := long_source(SECTIONS)
	defer delete(before)
	// A paragraph of four lines more, in the middle.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	half := strings.index(before, "## Section 30\n")
	strings.write_string(&b, before[:half])
	strings.write_string(&b, "A new paragraph that goes over more than one line of this narrow page, so that the text below it goes down by some lines, and then some more words.\n\n")
	strings.write_string(&b, before[half:])
	after := strings.to_string(b)

	f, fresh: Fixture
	setup(&f, before, 500)
	defer teardown(&f)
	setup(&fresh, after, 500)
	defer teardown(&fresh)
	step(&f.page, 1e30)
	step(&fresh.page, 1e30)
	memory := make([]rawptr, len(f.page.parts))
	defer delete(memory)
	for part, p in f.page.parts {
		memory[p] = part.memory
	}
	// A reader below the change.
	y := f.page.content_height * 0.8
	kept := take_place(&f.page, y)

	change := change_to(&f, after)
	expect_ok(t, &f.page)
	testing.expect_value(t, change.removed, 0)
	testing.expect_value(t, change.added, 1)
	testing.expect_value(t, change.parts_removed, 1)
	// Only the part of the change has no records; each other part has
	// the records it had, in the memory it had.
	for part, p in f.page.parts {
		if p == change.part_first || (change.parts_added == 2 && p == change.part_first + 1) {
			testing.expect_value(t, len(part.boxes), 0)
			continue
		}
		old := p < change.part_first ? p : p - change.parts_added + change.parts_removed
		testing.expect(t, part.complete)
		testing.expect(t, part.memory == memory[old])
	}
	// The reader's place, with the number that its block has now, is put
	// back at the height it had: the text of their view did not move.
	now, same := document.moved(change, kept.place.at)
	testing.expect(t, same)
	testing.expect_value(t, now.block, kept.place.block + 1)
	kept.place.at = now
	restore_place(&f.page, kept)
	expect_ok(t, &f.page)
	at, found := place_y(&f.page, kept.place)
	testing.expect(t, found)
	testing.expect(t, abs(at - y) < 0.01)
	// With the changed part laid out, the page is the one that a new
	// layout of the new text gives.
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	testing.expect(t, abs(f.page.content_height - fresh.page.content_height) < 0.01)
	want, got := page_lines(&fresh.page), page_lines(&f.page)
	defer delete(want)
	defer delete(got)
	testing.expect_value(t, len(got), len(want))
	for value, i in want {
		testing.expect(t, abs(got[i] - value) < 0.01)
	}
}

@(test)
test_a_change_while_a_part_is_in_work_and_of_all_of_the_document :: proc(t: ^testing.T) {
	before, after := long_source(30), long_source(12)
	defer delete(before)
	defer delete(after)
	f, fresh: Fixture
	setup(&f, before, 500)
	defer teardown(&f)
	setup(&fresh, after, 500)
	defer teardown(&fresh)
	// Some of the first part is laid out and is in work.
	lay_out(&f.page, 0, 150, 0)
	testing.expect(t, f.page.open == 0)
	// Fewer sections: the end of the document goes.
	change_to(&f, after)
	expect_ok(t, &f.page)
	testing.expect_value(t, len(f.page.parts), len(f.doc.parts))
	step(&f.page, 1e30)
	step(&fresh.page, 1e30)
	expect_ok(t, &f.page)
	testing.expect(t, abs(f.page.content_height - fresh.page.content_height) < 0.01)
	// To an empty document, and to one with no block in common.
	change_to(&f, "")
	expect_ok(t, &f.page)
	testing.expect_value(t, len(f.page.parts), 0)
	change_to(&f, "# Other\n\nText.\n")
	expect_ok(t, &f.page)
	step(&f.page, 1e30)
	testing.expect_value(t, len(only(&f.page).boxes), 2)
	// The same text again changes nothing.
	memory := only(&f.page).memory
	same := change_to(&f, "# Other\n\nText.\n")
	testing.expect_value(t, same.parts_removed + same.parts_added, 0)
	testing.expect(t, only(&f.page).memory == memory)
}

@(test)
test_a_place_on_a_rule_or_in_blank_code_lines_is_the_text_below :: proc(t: ^testing.T) {
	// A view whose first height is on a rule, with text far below it.
	f: Fixture
	setup(&f, "First.\n\n---\n\n```\n\n\n\n\n\n\n\n\ncode\n```\n\nLast.\n", 500)
	defer teardown(&f)
	lay_out(&f.page, 0, 60, 0)
	expect_ok(t, &f.page)
	rule := only(&f.page).boxes[1]
	// With records only down to the rule there is no line below it yet.
	y := f64(rule.top)
	early := take_place(&f.page, y)
	// With the block below it laid out, the place is its first line of
	// text, from far above it.
	lay_out(&f.page, y, y + 600, y)
	expect_ok(t, &f.page)
	kept := take_place(&f.page, y)
	testing.expect(t, kept.known)
	testing.expect_value(t, kept.place.block, 2)
	testing.expect(t, kept.place.fraction < 0)
	testing.expect(t, !early.known || early.place == kept.place)
	begin(&f.page, &f.doc, f.style, 300)
	restore_place(&f.page, kept)
	expect_ok(t, &f.page)
	at, ok := place_y(&f.page, kept.place)
	testing.expect(t, ok)
	testing.expect(t, abs(at - y) < 0.01)
}

@(test)
test_a_layout_after_edits_is_the_layout_of_its_source :: proc(t: ^testing.T) {
	PIECES := []string{"x", "\n\n", "# ", "- ", "> ", "```\n", "| a |\n| - |\n", "\n\nA new paragraph with some words in it.\n\n"}
	// Keys of an editor: most give a block other text and leave the
	// number of blocks, so only the records of that block are made
	// again; some words more make its text one line higher.
	KEYS := []string{"x", " ", "word ", "*", "`", "some words more that make this text a line longer than it was, ", "\n", "é", "| "}
	// The first run compares each tenth edit, the second one each edit.
	for each, run in ([]int{10, 1}) {
		before := long_source(30)
		defer delete(before)
		f: Fixture
		setup(&f, before, 500)
		defer teardown(&f)
		lay_out(&f.page, 0, 600, 0)
		// The same numbers each run.
		state := rand.create(0x9e3779b97f4a7c15 + u64(run))
		context.random_generator = rand.default_random_generator(&state)
		in_place := 0
		for edit in 0 ..< (run == 0 ? 80 : 160) {
			e: document.Edit
			e.start = rand.int_max(len(f.doc.source) + 1)
			e.end = e.start
			if run == 1 {
				if rand.int_max(5) == 0 {
					e.end = min(e.start + rand.int_max(4), len(f.doc.source))
				} else {
					e.text = KEYS[rand.int_max(len(KEYS))]
				}
			} else if rand.int_max(2) == 0 {
				e.text = PIECES[rand.int_max(len(PIECES))]
			} else {
				e.end = min(e.start + rand.int_max(30), len(f.doc.source))
			}
			now := document.edited(f.doc.source, e)
			defer delete(now)
			change := change_to(&f, string(now))
			in_place += int(change.added > 0 && change.parts_added == 0)
			expect_ok(t, &f.page)
			// A view at some height of the page, as after a scroll.
			y := f.page.origin + f64(rand.int_max(1000)) / 1000 * f.page.content_height
			lay_out(&f.page, y, y + 600, y)
			expect_ok(t, &f.page)
			// Each tenth edit: all of it laid out has the lines of a new
			// layout of the same source, at the same places. The edits
			// between leave parts with no records and parts with records
			// of before, as a view that scrolls does.
			if edit % each != each - 1 {
				continue
			}
			step(&f.page, 1e30)
			expect_ok(t, &f.page)
			fresh: Fixture
			setup(&fresh, string(f.doc.source), 500)
			defer teardown(&fresh)
			step(&fresh.page, 1e30)
			testing.expect(t, abs(f.page.content_height - fresh.page.content_height) < 0.01)
			want, got := page_lines(&fresh.page), page_lines(&f.page)
			defer delete(want)
			defer delete(got)
			testing.expect_value(t, len(got), len(want))
			for value, i in want[:min(len(want), len(got))] {
				testing.expect(t, abs(got[i] - value) < 0.01)
			}
		}
		// Many of the keys changed a block in its place.
		if run == 1 {
			testing.expect(t, in_place > 60, fmt.tprintf("%d edits in place", in_place))
		}
	}
}

@(test)
test_a_caret_has_the_place_of_its_address :: proc(t: ^testing.T) {
	// A paragraph of some lines, a code block with an empty line, a rule.
	f: Fixture
	setup(&f, "One paragraph with enough words in it to go over the end of a line in a narrow page, and then some.\n\n```\nfirst\n\nthird\n```\n\n---\n", 300)
	defer teardown(&f)
	expect_ok(t, &f.page)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	place :: proc(f: ^Fixture, at: document.Address) -> (x, top, height: f32, ok: bool) {
		x, top, height, _, ok = caret_place(&f.page, at)
		return
	}
	// Along a line the caret goes right; at the start of the next line
	// it is at the left again, one line lower.
	x0, top0, height, ok0 := place(&f, {block = 0})
	x5, top5, _, ok5 := place(&f, {block = 0, byte = 5})
	testing.expect(t, ok0 && ok5)
	testing.expect(t, x5 > x0 && top5 == top0 && height > 0)
	second := f.page.parts[0].lines[1]
	x, top, _, _ := place(&f, {block = 0, byte = second.line.start})
	testing.expect_value(t, x, second.x)
	testing.expect_value(t, top, second.top)
	testing.expect(t, top > top0)
	// The end of the text is at the end of its last line.
	last := f.page.parts[0].lines[f.page.parts[0].boxes[0].line_end - 1]
	x, top, _, _ = place(&f, {block = 0, byte = len(document.block_at(&f.doc, 0).text.bytes)})
	testing.expect(t, top == last.top && x > last.x)
	// "first\n\nthird": the empty line has no line record, and the caret
	// is one line below "first" on it, and "third" one more.
	_, first, line, _ := place(&f, {block = 1})
	x, top, _, _ = place(&f, {block = 1, byte = 6})
	testing.expect(t, abs(top - (first + line)) < 0.01)
	_, third, _, _ := place(&f, {block = 1, byte = 7})
	testing.expect(t, abs(third - (first + 2 * line)) < 0.01)
	// A rule has no text, and so no caret.
	_, _, _, ok := place(&f, {block = 2})
	testing.expect(t, !ok)
	// A block with no records has none either.
	g: Fixture
	setup(&g, "Not laid out.\n", 300)
	defer teardown(&g)
	expect_ok(t, &g.page)
	_, _, _, ok = place(&g, {block = 0})
	testing.expect(t, !ok)
}

@(test)
test_the_caret_of_an_empty_document_is_where_its_first_text_starts :: proc(t: ^testing.T) {
	empty: Fixture
	setup(&empty, "", 300)
	defer teardown(&empty)
	step(&empty.page, 1e30)
	expect_ok(t, &empty.page)
	x, top, height := caret_place_empty(&empty.page)
	out: [dynamic]base.Quad
	defer delete(out)
	caret_quad_empty(&empty.page, 2, 0, &out)
	testing.expect_value(t, len(out), 1)
	// The same place as the caret before the first character typed.
	typed: Fixture
	setup(&typed, "a\n", 300)
	defer teardown(&typed)
	step(&typed.page, 1e30)
	expect_ok(t, &typed.page)
	tx, ttop, theight, p, ok := caret_place(&typed.page, {block = 0})
	testing.expect(t, ok)
	testing.expect_value(t, x, tx)
	testing.expect_value(t, empty.page.origin + f64(top), typed.page.parts[p].top + f64(ttop))
	testing.expect_value(t, height, theight)
}

// The top of the line of a caret, as a height of the page.
@(private = "file")
caret_top :: proc(t: ^testing.T, f: ^Fixture, at: document.Address, upstream := false, loc := #caller_location) -> f64 {
	_, y, _, ok := caret_y(&f.page, at, upstream)
	testing.expect(t, ok, loc = loc)
	return y
}

@(test)
test_a_caret_goes_up_and_down_by_one_line :: proc(t: ^testing.T) {
	// A paragraph of some lines, a short one, and a code block with an
	// empty line.
	f: Fixture
	setup(&f, "One paragraph with enough words in it to go over the end of a line in a narrow page, and then some.\n\nSecond.\n\n```\nfirst\n\nthird\n```\n", 300)
	defer teardown(&f)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	Stop :: struct {
		at:       document.Address,
		upstream: bool,
	}
	// Down from the start, with the x of a place in the first line: each
	// step is one line lower, and no line is left out.
	x, _, _, _, _ := caret_place(&f.page, {block = 0, byte = 6})
	path: [dynamic]Stop
	defer delete(path)
	append(&path, Stop{{block = 0, byte = 6}, false})
	for len(path) < 40 {
		last := path[len(path) - 1]
		next, upstream := caret_line_step(&f.page, last.at, last.upstream, x, true) or_break
		testing.expect(t, caret_top(t, &f, next, upstream) > caret_top(t, &f, last.at, last.upstream))
		append(&path, Stop{next, upstream})
	}
	first_lines := 0
	for stop in path {
		first_lines += int(stop.at.block == 0)
	}
	testing.expect(t, first_lines >= 3)
	// The short paragraph, and the three lines of the code block: the
	// empty one between two with text too.
	testing.expect_value(t, len(path), first_lines + 4)
	testing.expect_value(t, path[first_lines].at.block, 1)
	testing.expect_value(t, path[first_lines + 2].at, document.Address{block = 2, byte = 6})
	testing.expect_value(t, path[len(path) - 1].at.block, 2)
	// And up again, through the same lines.
	at := path[len(path) - 1]
	for i := len(path) - 2; i >= 0; i -= 1 {
		next, upstream, ok := caret_line_step(&f.page, at.at, at.upstream, x, false)
		testing.expect(t, ok)
		testing.expect_value(t, caret_top(t, &f, next, upstream), caret_top(t, &f, path[i].at, path[i].upstream))
		at = {next, upstream}
	}
	_, _, ok := caret_line_step(&f.page, at.at, at.upstream, x, false)
	testing.expect(t, !ok)
}

@(test)
test_a_caret_goes_through_each_block_with_no_text :: proc(t: ^testing.T) {
	// Six headings with no text between two paragraphs: each is a line
	// for the caret, down and up.
	f: Fixture
	setup(&f, "a\n\n# \n\n# \n\n# \n\n# \n\n# \n\n# \n\nz\n", 300)
	defer teardown(&f)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	at := document.Address{block = 0}
	for block in 1 ..= 7 {
		next, _, ok := caret_line_step(&f.page, at, false, 40, true)
		testing.expect(t, ok)
		testing.expect_value(t, next.block, block)
		at = next
	}
	for block := 6; block >= 0; block -= 1 {
		next, _, ok := caret_line_step(&f.page, at, false, 40, false)
		testing.expect(t, ok)
		testing.expect_value(t, next.block, block)
		at = next
	}
}

@(test)
test_a_caret_goes_to_the_two_ends_of_its_line :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "One paragraph with enough words in it to go over the end of a line in a narrow page, and then some.\n\n```\nfirst\n\nthird  \n```\n", 300)
	defer teardown(&f)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	// In the second line of the paragraph: the two ends are in that
	// line, the start at the left and the end right of each place of it.
	second, second_up, found := caret_line_step(&f.page, {block = 0, byte = 6}, false, 60, true)
	testing.expect(t, found)
	start, start_up, _ := caret_line_end(&f.page, second, second_up, false)
	end, end_up, _ := caret_line_end(&f.page, second, second_up, true)
	top := caret_top(t, &f, second, second_up)
	testing.expect(t, start.byte > 0 && end.byte > start.byte)
	testing.expect_value(t, caret_top(t, &f, start, start_up), top)
	testing.expect_value(t, caret_top(t, &f, end, end_up), top)
	sx, _, _, _, _ := caret_place(&f.page, start, start_up)
	ex, _, _, _, _ := caret_place(&f.page, end, end_up)
	x0, _, _, _, _ := caret_place(&f.page, {block = 0})
	testing.expect_value(t, sx, x0)
	testing.expect(t, ex > sx + 100)
	// The end of the line is the byte where the next line starts: the
	// same address is at the start of that line with no side, and the
	// two ends of the line from there are the same two.
	testing.expect(t, end_up && !start_up)
	testing.expect(t, caret_top(t, &f, end, false) > top)
	again, again_up, _ := caret_line_end(&f.page, end, end_up, true)
	testing.expect(t, again == end && again_up)
	back, _, _ := caret_line_end(&f.page, end, end_up, false)
	testing.expect_value(t, back, start)
	// A click right of the text of the first line is at the end of that
	// line, not at the start of the next one.
	first_top := caret_top(t, &f, {block = 0})
	right, right_up, hit := caret_hit(&f.page, 290, first_top + 4)
	testing.expect(t, hit && right_up)
	testing.expect_value(t, caret_top(t, &f, right, right_up), first_top)
	testing.expect_value(t, right, start)
	// The first line starts at the start of the text.
	first, _, _ := caret_line_end(&f.page, {block = 0, byte = 6}, false, false)
	testing.expect_value(t, first, document.Address{block = 0})
	// A line of code ends before its line break, after the spaces that
	// it ends with; an empty line is its own two ends.
	code_end, code_up, _ := caret_line_end(&f.page, {block = 1, byte = 2}, false, true)
	testing.expect_value(t, code_end, document.Address{block = 1, byte = 5})
	testing.expect(t, !code_up)
	code_start, _, _ := caret_line_end(&f.page, {block = 1, byte = 9}, false, false)
	testing.expect_value(t, code_start, document.Address{block = 1, byte = 7})
	spaces_end, _, _ := caret_line_end(&f.page, {block = 1, byte = 9}, false, true)
	testing.expect_value(t, spaces_end, document.Address{block = 1, byte = 14})
	for end_of in ([]bool{false, true}) {
		empty, _, _ := caret_line_end(&f.page, {block = 1, byte = 6}, false, end_of)
		testing.expect_value(t, empty, document.Address{block = 1, byte = 6})
	}
}

@(test)
test_the_end_of_a_line_with_no_space_is_in_that_line :: proc(t: ^testing.T) {
	// Text that a line cuts between two characters: the end of the
	// first line is the start of the second one, and the caret shows at
	// the end of the first.
	f: Fixture
	setup(&f, "\u65e5\u672c\u8a9e\u306e\u6587\u7ae0\u304c\u3053\u3053\u306b\u3042\u308a\u307e\u3059\u3002\u65e5\u672c\u8a9e\u306e\u6587\u7ae0\u304c\u3053\u3053\u306b\u3042\u308a\u307e\u3059\u3002\u65e5\u672c\u8a9e\u306e\u6587\u7ae0\u304c\u3053\u3053\u306b\u3042\u308a\u307e\u3059\u3002\n", 200)
	defer teardown(&f)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	top := caret_top(t, &f, {block = 0, byte = 3})
	end, upstream, ok := caret_line_end(&f.page, {block = 0, byte = 3}, false, true)
	testing.expect(t, ok && upstream && end.byte > 3)
	testing.expect_value(t, caret_top(t, &f, end, upstream), top)
	// The end again from there is the same place, not the next line's.
	again, again_up, _ := caret_line_end(&f.page, end, upstream, true)
	testing.expect(t, again == end && again_up)
}

@(test)
test_each_empty_paragraph_shows_as_a_line :: proc(t: ^testing.T) {
	// The same two paragraphs with one empty line after each, and with
	// more: each line more is a line of the page, so what is after it
	// is lower.
	reader, editor: Fixture
	setup(&reader, "first\n\nsecond\n", 300)
	defer teardown(&reader)
	step(&reader.page, 1e30)
	expect_ok(t, &reader.page)
	setup(&editor, "first\n\n\n\nsecond\n\n", 300)
	defer teardown(&editor)
	step(&editor.page, 1e30)
	expect_ok(t, &editor.page)
	testing.expect_value(t, int(document.block_at(editor.page.doc, 0).empties), 2)
	testing.expect_value(t, int(document.block_at(editor.page.doc, 1).empties), 1)
	each := f64(empty_height(&editor.page))
	testing.expect_value(t, caret_top(t, &editor, {block = 1}), caret_top(t, &reader, {block = 1}) + 2 * each)
	testing.expect_value(t, editor.page.content_height, reader.page.content_height + 3 * each)
	// The caret goes down through "first", its two empty paragraphs,
	// "second", and the one after it; a click in each line is that line.
	path := []document.Address{{block = 0, byte = 2}, {block = 0, byte = 5, empty = 1}, {block = 0, byte = 5, empty = 2}, {block = 1, byte = 2}, {block = 1, byte = 6, empty = 1}}
	x, _, _, _ := caret_y(&editor.page, path[0], false)
	for at, i in path {
		cx, y, height, ok := caret_y(&editor.page, at, false)
		testing.expect(t, ok)
		hit, _, found := caret_hit(&editor.page, cx + 1, y + f64(height) / 2)
		testing.expect(t, found)
		testing.expect_value(t, hit, at)
		if i + 1 < len(path) {
			next, _, moved := caret_line_step(&editor.page, at, false, x, true)
			testing.expect(t, moved)
			testing.expect_value(t, next.block, path[i + 1].block)
			testing.expect_value(t, document.empty_of(editor.page.doc, next), document.empty_of(editor.page.doc, path[i + 1]))
			testing.expect(t, caret_top(t, &editor, next) > y)
		}
	}
	// And up again.
	at := path[len(path) - 1]
	for i := len(path) - 2; i >= 0; i -= 1 {
		next, _, moved := caret_line_step(&editor.page, at, false, x, false)
		testing.expect(t, moved)
		testing.expect_value(t, caret_top(t, &editor, next), caret_top(t, &editor, path[i]))
		at = next
	}
	// An empty paragraph is a line with one place.
	for end in ([]bool{false, true}) {
		same, _, ok := caret_line_end(&editor.page, {block = 0, byte = 5, empty = 1}, false, end)
		testing.expect(t, ok)
		testing.expect_value(t, same, document.Address{block = 0, byte = 5, empty = 1})
	}
}

@(test)
test_a_click_puts_a_caret_at_text_with_no_line :: proc(t: ^testing.T) {
	// A code block with empty lines, at its start and between two lines
	// with text, and a list item with nothing in it.
	f: Fixture
	setup(&f, "```\n\nfirst\n\n\nfourth\n```\n\n- \n- item\n", 300)
	defer teardown(&f)
	step(&f.page, 1e30)
	expect_ok(t, &f.page)
	// A point in the middle of the line of each address is that address.
	for at in ([]document.Address{{block = 0}, {block = 0, byte = 7}, {block = 0, byte = 8}, {block = 1}}) {
		x, top, height, p, ok := caret_place(&f.page, at)
		testing.expect(t, ok)
		hit, _, found := caret_hit(&f.page, x + 1, f.page.parts[p].top + f64(top + height / 2))
		testing.expect(t, found)
		testing.expect_value(t, hit, at)
	}
	// A point in a line with text is in that text, as before.
	x, top, height, p, _ := caret_place(&f.page, {block = 0, byte = 3})
	hit, _, found := caret_hit(&f.page, x, f.page.parts[p].top + f64(top + height / 2))
	testing.expect(t, found && hit.block == 0 && hit.byte >= 1 && hit.byte <= 6)
}

@(test)
test_a_mark_that_shows_has_the_secondary_color :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "text\n", 500)
	defer teardown(&f)
	f.page.style.text = {20, 20, 20, 255}
	f.page.style.secondary = {120, 120, 120, 255}
	f.page.style.link = {0, 0, 255, 255}
	para: Para
	// A mark of the source that shows at the caret, also the mark of a
	// link and one in a task that is done.
	testing.expect_value(t, span_color(&f.page, &para, {.Mark}, false), f.page.style.secondary)
	testing.expect_value(t, span_color(&f.page, &para, {.Mark}, true), f.page.style.secondary)
	// Each other span as before.
	testing.expect_value(t, span_color(&f.page, &para, {.Link}, false), f.page.style.link)
	testing.expect_value(t, span_color(&f.page, &para, {}, false), f.page.style.text)
	testing.expect_value(t, span_color(&f.page, &para, {}, true), done_color(&f.page))
}

// The number of an item is one line right-aligned to its text, also with
// many digits: it does not break into a second line.
@(test)
test_the_number_of_an_item_is_one_line :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "123456. many digits\n124. b\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	page := only(&f.page)
	for i in 0 ..< 2 {
		box := page.boxes[i]
		// The lines of the box: its text, and its number, which has no
		// source.
		numbers, text_top, number_top := 0, f32(-1), f32(-1)
		for line in page.lines[box.line_first:box.line_end] {
			if page.paras[line.para].src == nil {
				numbers += 1
				number_top = line.top
			} else if text_top < 0 {
				text_top = line.top
			}
		}
		testing.expect_value(t, numbers, 1)
		testing.expect(t, abs(number_top - text_top) < 1, "the number is on the line of the text")
	}
}

// The panel of front matter is an area above the first part: a text for
// each key and each value, pills for the items of a sequence, and a
// hairline below. The page is as much higher, each part is as much
// lower, and no text of the panel is text that a caret or a selection
// can be in.
@(test)
test_front_matter_is_a_panel_above_the_first_part :: proc(t: ^testing.T) {
	plain: Fixture
	setup(&plain, "# Title\n\nText.\n", 600)
	defer teardown(&plain)
	step(&plain.page, 1e30)
	f: Fixture
	setup(&f, "---\ntitle: A draft\ntags: [one, two]\nempty:\n---\n# Title\n\nText.\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	panel := &f.page.panel
	testing.expect(t, panel.height > 3 * f.page.m.body)
	testing.expect_value(t, f.page.parts[0].top, f.page.origin + f64(panel.height))
	testing.expect_value(t, f.page.content_height, plain.page.content_height + f64(panel.height))
	// The records of the first part are the ones of a page with no panel.
	testing.expect_value(t, only(&f.page).boxes[0].top, only(&plain.page).boxes[0].top)
	testing.expect_value(t, len(only(&f.page).lines), len(only(&plain.page).lines))
	// Three keys, a value, two pills, and the dash of a value that is
	// empty: one line each. The two pills and the hairline.
	testing.expect_value(t, len(panel.texts), 7)
	testing.expect_value(t, len(panel.lines), 7)
	testing.expect_value(t, len(panel.decor), 3)
	rule := panel.decor[2]
	testing.expect_value(t, rule.h, f32(1))
	testing.expect_value(t, rule.w, f.page.column)
	testing.expect(t, rule.y + rule.h < panel.height)
	for line in panel.lines {
		testing.expect(t, line.top >= f.page.m.page_pad * TOP_PAD && line.top < rule.y)
	}
	// The two pills are in one row, beside each other, right of the keys,
	// each with its text in it.
	one, two := panel.decor[0], panel.decor[1]
	testing.expect(t, one.radius > 0 && one.y == two.y && two.x > one.x + one.w)
	testing.expect(t, one.x >= f.page.column_x + PANEL_KEYS * f.page.column)
	testing.expect(t, panel.lines[3].x > one.x && panel.lines[3].x + panel.lines[3].line.width < one.x + one.w)
	testing.expect(t, panel.lines[4].x > two.x && panel.lines[4].x + panel.lines[4].line.width < two.x + two.w)
	// A point on a text of the panel is on no text of the document, and
	// a caret there goes to the text of the document.
	key := panel.lines[0]
	testing.expect(t, !text_at(&f.page, key.x + 2, f.page.origin + f64(key.top) + 4))
	at, _, placed := caret_hit(&f.page, key.x + 2, f.page.origin + f64(key.top) + 4)
	testing.expect(t, placed && at.block == 0)
	// A narrow page: the pills are in rows of their own, in the column.
	narrow: Fixture
	setup(&narrow, "---\ntags: [a long first tag, a long second tag, third]\n---\nText.\n", 260)
	defer teardown(&narrow)
	step(&narrow.page, 1e30)
	rows := 0
	last: f32 = -1
	for d in narrow.page.panel.decor[:3] {
		testing.expect(t, d.x + d.w <= narrow.page.column_x + narrow.page.column + 0.5)
		rows += int(d.y != last)
		last = d.y
	}
	testing.expect(t, rows >= 2)
	// Front matter with no entry, and front matter that nothing closes
	// (it is Markdown then), make no panel. Front matter with no block
	// after it has its panel.
	for source in ([]string{"---\n---\n# Title\n", "---\ntitle: x\n\n# Title\n"}) {
		g: Fixture
		setup(&g, source, 600)
		step(&g.page, 1e30)
		testing.expect_value(t, g.page.panel.height, f32(0))
		teardown(&g)
	}
	alone: Fixture
	setup(&alone, "---\ntitle: x\n---\n", 600)
	defer teardown(&alone)
	step(&alone.page, 1e30)
	testing.expect(t, alone.page.panel.height > 0)
	testing.expect(t, alone.page.content_height >= f64(alone.page.panel.height))
}

// The bar of a caret is as high as the font of the text of its line, on
// the line that the text stands on: higher in a heading than in a
// paragraph, and less than the line with a wide line spacing.
@(test)
test_the_caret_is_as_high_as_the_text_of_its_line :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "# Heading\n\nA paragraph.\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	_, heading_y, heading_line, _ := caret_y(&f.page, {block = 0, byte = 2}, false)
	_, heading_bar_y, heading_bar, _ := caret_bar_y(&f.page, {block = 0, byte = 2}, false)
	_, body_y, body_line, _ := caret_y(&f.page, {block = 1, byte = 2}, false)
	_, body_bar_y, body_bar, _ := caret_bar_y(&f.page, {block = 1, byte = 2}, false)
	ascent, descent, _ := text.font_metrics(f.style.body_font)
	testing.expect(t, abs(body_bar - (ascent + descent)) < 0.01)
	testing.expect(t, body_bar < body_line && heading_bar < heading_line)
	testing.expect(t, heading_bar > body_bar * 1.5)
	// On the line that the glyphs of its line stand on: the top of the
	// bar is the ascent of the font above the baseline of the shaped line.
	part := &f.page.parts[0]
	for line in part.lines {
		if part.paras[line.para].src != &f.page.doc.parts[0].blocks[1].text {
			continue
		}
		baseline := line_baseline(line.top, body_line, line.line.ascent, line.line.descent)
		testing.expect(t, abs(f32(body_bar_y - part.top) + ascent - baseline) < 0.01)
	}
	testing.expect(t, abs((heading_bar_y - heading_y) - f64(heading_line - heading_bar) / 2) < 0.01)
	// The quad that is drawn is the same bar, on whole pixels.
	quads: [dynamic]base.Quad
	defer delete(quads)
	caret_quad(&f.page, {block = 1, byte = 2}, false, -1e30, 1e30, 1, 0, &quads)
	if testing.expect_value(t, len(quads), 1) {
		testing.expect(t, abs(quads[0].size[1] - body_bar) < 1 && quads[0].size[1] < body_line - 2)
	}
	// An empty line after a heading is a line of body text: the same
	// bar, at the same place in its line.
	g: Fixture
	setup(&g, "# Heading\n\n\n\nText.\n", 600)
	defer teardown(&g)
	step(&g.page, 1e30)
	if empty, has := document.empty_address(g.page.doc, 0, 1); testing.expect(t, has) {
		_, empty_y, _, _ := caret_y(&g.page, empty, false)
		_, empty_bar_y, empty_bar, _ := caret_bar_y(&g.page, empty, false)
		testing.expect(t, abs(empty_bar - body_bar) < 0.01)
		testing.expect(t, abs((empty_bar_y - empty_y) - (body_bar_y - body_y)) < 0.01)
	}
	// A heading with no text has the bar of a heading with text, at the
	// same place: the first character does not move the caret.
	h: Fixture
	setup(&h, "#\n\nText.\n", 600)
	defer teardown(&h)
	step(&h.page, 1e30)
	if testing.expect_value(t, h.page.doc.parts[0].blocks[0].kind, document.Block_Kind.Heading) {
		_, bare_bar_y, bare_bar, _ := caret_bar_y(&h.page, {block = 0}, false)
		testing.expect(t, abs(bare_bar - heading_bar) < 0.01)
		testing.expect(t, abs(bare_bar_y - heading_bar_y) < 0.01)
	}
}

// The card of a code block: its background, and a border of half a point
// around it, with the round corners of the card of the web renderer.
@(test)
test_the_card_of_code_has_round_corners :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "```\ncode\n```\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	part := only(&f.page)
	box := part.boxes[0]
	if !testing.expect(t, box.decor_end - box.decor_first >= 2) {
		return
	}
	border, card := part.decor[box.decor_first], part.decor[box.decor_first + 1]
	testing.expect_value(t, card.radius, f32(16))
	testing.expect_value(t, border.radius, card.radius + 0.5)
	// The border is the card, half a point larger on each side.
	testing.expect_value(t, border.x, card.x - 0.5)
	testing.expect_value(t, border.w, card.w + 1)
	testing.expect_value(t, border.color, f.style.code_border)
	testing.expect_value(t, card.color, f.style.code_background)
}
