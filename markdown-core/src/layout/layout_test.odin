package layout

import "../base"
import "../document"
import "../text"
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

@(test)
test_boxes_go_down_the_page :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	testing.expect(t, done(&f.page))
	testing.expect_value(t, len(f.page.boxes), len(f.doc.blocks))
	bottom: f32
	for box in f.page.boxes {
		testing.expect(t, box.top >= bottom)
		testing.expect(t, box.bottom > box.top)
		bottom = box.bottom
	}
	testing.expect(t, f.page.content_height > bottom)
}

@(test)
test_steps_give_the_same_layout :: proc(t: ^testing.T) {
	whole, parts: Fixture
	setup(&whole, SOURCE, 600)
	defer teardown(&whole)
	setup(&parts, SOURCE, 600)
	defer teardown(&parts)
	step(&whole.page, 1e30)
	for until: f32 = 40; !done(&parts.page); until += 40 {
		step(&parts.page, until)
	}
	testing.expect_value(t, len(parts.page.lines), len(whole.page.lines))
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
	testing.expect(t, len(narrow.page.lines) > len(wide.page.lines))
}

@(test)
test_select_all_copies_the_text :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, SOURCE, 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	out: [dynamic]u8
	defer delete(out)
	selection_text(&f.page, select_all(&f.page), &out)
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
	last := f.page.lines[len(f.page.lines) - 1]
	para := &f.page.paras[last.para]
	pos, ok := hit_test(&f.page, last.x + last.line.width - 1, last.top + 2)
	testing.expect(t, ok)
	testing.expect_value(t, pos.order, para.order)
	testing.expect(t, pos.index > 0 && pos.index <= len(para.src.bytes))
	// A point far below the page still gives the last line.
	below, _ := hit_test(&f.page, 0, f.page.content_height + 5000)
	testing.expect_value(t, below.order, para.order)
}

@(test)
test_hit_test_looks_past_blocks_without_text :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "***\n\n***\n\ntext\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	_, ok := hit_test(&f.page, 100, f.page.boxes[0].top)
	testing.expect(t, ok)
}

@(test)
test_marker_of_an_item_that_starts_with_code :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "1. ```\n   code\n   ```\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	markers := 0
	for para in f.page.paras {
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
	display(&f.page, &cache, 0, f.page.boxes[0].bottom, 0, &rects, &glyphs, &scratch)
	testing.expect(t, len(glyphs) > 0 && len(glyphs) < all)
	clear(&glyphs)
	display(&f.page, &cache, f.page.content_height + 10, f.page.content_height + 500, 0, &rects, &glyphs, &scratch)
	testing.expect_value(t, len(glyphs), 0)
}

@(private = "file")
shaped_lines :: proc(l: ^Layout) -> (count: int) {
	for line in l.lines {
		count += text.line_shaped(line.line) ? 1 : 0
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
	for until: f32 = 40; !done(&f.page); until += 40 {
		step(&f.page, until)
	}
	first := f.page.boxes[0]
	testing.expect_value(t, shaped_lines(&f.page), first.line_end - first.line_first)
	for para in f.page.paras {
		inside := para.src == &f.doc.blocks[0].text
		testing.expect_value(t, para.handle != nil, inside)
	}
	// The copied text needs no shaped text.
	out: [dynamic]u8
	defer delete(out)
	selection_text(&f.page, select_all(&f.page), &out)
	testing.expect(t, len(out) > 100)
	// A point in a released line shapes that line.
	last := f.page.lines[len(f.page.lines) - 1]
	pos, ok := hit_test(&f.page, last.x + 20, last.top + 2)
	testing.expect(t, ok)
	testing.expect(t, pos.index > 0)
	testing.expect(t, text.line_shaped(f.page.lines[len(f.page.lines) - 1].line))
	// The window moves away: all of it is released.
	keep(&f.page, -20, -10)
	testing.expect_value(t, shaped_lines(&f.page), 0)
	for para in f.page.paras {
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
	third := f.page.lines[2]
	keep(&f.page, third.top + 1, third.top + 2)
	testing.expect_value(t, shaped_lines(&f.page), 1)
	testing.expect(t, text.line_shaped(f.page.lines[2].line))
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
	testing.expect_value(t, len(f.page.tasks), 3)
	one, two := f.page.tasks[0], f.page.tasks[1]
	// A task knows its block, which has its line and its state.
	testing.expect_value(t, one.block, 0)
	testing.expect_value(t, two.block, 1)
	testing.expect_value(t, f.page.tasks[2].block, 3)
	testing.expect(t, two.y > one.y)
	// The box stands left of the text of its item, and the layout draws
	// nothing in its place.
	first := f.page.lines[f.page.boxes[0].line_first]
	size := task_box_size(f.page.m)
	testing.expect(t, one.x + size < first.x)
	testing.expect_value(t, len(f.page.decor), 0)
	// Only the box that a range touches.
	part := tasks_between(&f.page, two.y + 1, two.y + size - 1)
	testing.expect_value(t, len(part), 1)
	testing.expect_value(t, part[0].block, 1)
	testing.expect_value(t, len(tasks_between(&f.page, 0, 1e30)), 3)
	testing.expect_value(t, len(tasks_between(&f.page, f.page.tasks[2].y + size, 1e30)), 0)
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
	testing.expect(t, len(narrow.page.lines) > len(wide.page.lines))
	for line in narrow.page.lines {
		testing.expect(t, line.x + line.line.width <= 300)
	}
}

@(test)
test_only_a_line_of_text_is_text_for_the_pointer :: proc(t: ^testing.T) {
	f: Fixture
	setup(&f, "First paragraph.\n\n- [ ] a task\n\nLast paragraph.\n", 600)
	defer teardown(&f)
	step(&f.page, 1e30)
	first := f.page.lines[f.page.boxes[0].line_first]
	item := f.page.lines[f.page.boxes[1].line_first]
	mid :: proc(l: ^Layout, line: Line) -> f32 {
		return line.top + l.paras[line.para].line_height / 2
	}
	// On the text, and right of its end on the same line.
	testing.expect(t, text_at(&f.page, first.x + 5, mid(&f.page, first)))
	testing.expect(t, text_at(&f.page, first.x + first.line.width + 50, mid(&f.page, first)))
	// Not in the margin right of the column.
	testing.expect(t, text_at(&f.page, f.page.column_x + f.page.column - 1, mid(&f.page, first)))
	testing.expect(t, !text_at(&f.page, f.page.column_x + f.page.column + 5, mid(&f.page, first)))
	// Not in the margin left of it, and not between two blocks.
	testing.expect(t, !text_at(&f.page, first.x - 5, mid(&f.page, first)))
	gap := (f.page.boxes[0].bottom + f.page.boxes[1].top) / 2
	testing.expect(t, f.page.boxes[1].top > f.page.boxes[0].bottom)
	testing.expect(t, !text_at(&f.page, first.x + 5, gap))
	// Not at the check box of the task, which is left of its text.
	box := f.page.tasks[0]
	testing.expect(t, !text_at(&f.page, box.x + 2, mid(&f.page, item)))
	testing.expect(t, text_at(&f.page, item.x + 2, mid(&f.page, item)))
	// In a code block of many lines, and in a table: the same answers as
	// a look at each line.
	{
		g: Fixture
		setup(&g, "```\none\ntwo\nthree\nfour\nfive\n```\n\n| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\n- item\n", 600)
		defer teardown(&g)
		step(&g.page, 1e30)
		for box in g.page.boxes {
			for line in g.page.lines[box.line_first:box.line_end] {
				para := &g.page.paras[line.para]
				at := line.top + para.line_height / 2
				testing.expect_value(t, text_at(&g.page, line.x + 1, at), para.src != nil)
				testing.expect(t, !text_at(&g.page, 2, at))
			}
		}
	}
	// A number so long that it wraps: its lines come before the text of
	// the item and start at the same height again.
	{
		g: Fixture
		setup(&g, "123456789. first line of the item\n   second paragraph of it\n", 600)
		defer teardown(&g)
		step(&g.page, 1e30)
		texts, marker_lines := 0, 0
		for box in g.page.boxes {
			for line in g.page.lines[box.line_first:box.line_end] {
				para := &g.page.paras[line.para]
				if para.src == nil {
					marker_lines += 1
					continue
				}
				texts += 1
				testing.expect(t, text_at(&g.page, line.x + 1, line.top + para.line_height / 2))
			}
		}
		testing.expect(t, texts >= 1)
		testing.expect(t, marker_lines >= 2)
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
	_, early := place_y(&narrow.page, Place{block = len(wide.page.boxes) - 1})
	testing.expect(t, !early)
	for line in wide.page.lines {
		para := &wide.page.paras[line.para]
		if para.src == nil {
			continue
		}
		// A height in the line: the place is that line.
		y := line.top + para.line_height * 0.25
		place, ok := place_at(&wide.page, y)
		testing.expect(t, ok)
		if wide.page.doc.blocks[place.block].kind != .Table {
			testing.expect_value(t, place.byte, para.base + line.line.start)
			testing.expect(t, place_text(&wide.page, place.block, place.cell) == para.src)
		} else {
			// The first cell of the row at that height.
			testing.expect(t, place_text(&wide.page, place.block, place.cell) != nil)
		}
		// The same layout gives the height back.
		back, back_ok := place_y(&wide.page, place)
		testing.expect(t, back_ok)
		testing.expect(t, abs(back - y) < 0.01)
		// In another width: the line that has the same byte.
		step_to_block(&narrow.page, place.block)
		there, there_ok := place_y(&narrow.page, place)
		testing.expect(t, there_ok)
		again, again_ok := place_at(&narrow.page, there)
		testing.expect(t, again_ok)
		testing.expect_value(t, again.block, place.block)
		testing.expect_value(t, again.cell, place.cell)
		testing.expect(t, again.byte <= place.byte)
	}
	// Between two blocks: the next line, from above it. Below the page: none.
	gap := (wide.page.boxes[0].bottom + wide.page.boxes[1].top) / 2
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
	box := f.page.boxes[0]
	testing.expect_value(t, box.line_end - box.line_first, 2)
	a, b := f.page.lines[box.line_first], f.page.lines[box.line_first + 1]
	height := f.page.paras[a.para].line_height
	testing.expect(t, b.top - a.top > 10 * height)
	// Near the start of the blank run, far above B.
	y := a.top + 2.5 * height
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
	last := before.page.lines[len(before.page.lines) - 1]
	height := before.page.paras[last.para].line_height
	place, ok := place_at(&before.page, last.top + height / 2)
	testing.expect(t, ok)
	testing.expect_value(t, place.block, 1)
	there, there_ok := place_y(&after.page, place)
	testing.expect(t, there_ok)
	same := after.page.lines[len(after.page.lines) - 1]
	testing.expect(t, abs(there - (same.top + height / 2)) < 0.01)
}
