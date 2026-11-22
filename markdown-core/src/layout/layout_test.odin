package layout

import "../base"
import "../document"
import "../text"
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
