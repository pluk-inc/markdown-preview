package layout

import "core:bytes"
import "core:mem"

import "../base"
import "../document"
import "../text"

// The panel of front matter at the top of the page: the keys and the
// values of the front matter of the document (`document.front_matter`),
// as the web renderer shows them. A quiet table with no rules: the keys
// in a column of a quarter of the width, soft; the values beside them;
// the items of a sequence as pills; and one hairline below, before the
// first block.
//
// The panel is no part of the document and no block of it: its bytes are
// no Markdown (`Document.hidden`), so it has no text that a caret or a
// selection can be in. It is an area of its own above the first part
// (`sum_tops`), with its own records, which keep their shaped text: it
// is a few lines. A document with front matter and no block has it too.
Panel :: struct {
	height: f32, // 0 for no panel
	texts:  [dynamic]Panel_Text,
	lines:  [dynamic]Panel_Line,
	decor:  [dynamic]Decor, // y from the top of the page
	// A copy of the bytes that the document hides, which the entries are
	// read from: the source of the document is other memory after each
	// change of it.
	source: []u8,
	memory: mem.Dynamic_Arena, // of that copy and of the entries
	made:   bool, // the memory is in use
}

@(private)
Panel_Text :: struct {
	shaped:      ^text.Paragraph,
	color:       base.Color,
	line_height: f32,
}

@(private)
Panel_Line :: struct {
	of:     int, // in the texts of the panel
	line:   text.Line,
	x, top: f32, // points; the top counts from the top of the page
}

// The text of the panel is in the size of the text of the page, and a
// pill in the size of the panel: a size of its own is a font of its own
// and each of its glyphs made new, which was 11 of the 16 percent that
// the panel added to the first frame of a new process (`BENCHMARKS.md`).
PANEL_SIZE :: 1.0 // of the text, in body sizes
PANEL_LINE :: 1.5 // the height of a line, in sizes of the text
PANEL_PAD :: 0.28 // above and below the text of a row
PANEL_KEYS :: 0.26 // the column of the keys, of the width
PANEL_GAP :: 1.4 // between a key and its value
PANEL_BELOW :: 1.0 // between the last row and the hairline, in body sizes
PANEL_AFTER :: 0.4 // below the hairline, in body sizes; the room above the first block comes after it
PILL_SIZE :: 1.0 // of the text of a pill, in sizes of the text of the panel
PILL_PAD_X :: 0.7 // left and right of the text of a pill, in its sizes
PILL_PAD_Y :: 0.08
PILL_GAP_X :: 0.4
PILL_GAP_Y :: 0.2
PILL_TINT :: 0.12 // how much of the color of a link the pill has

// Makes the panel of the document, when its front matter is other bytes
// than the ones of the panel that is there, or with `force` (another
// width or style). True when it made one, or took one away: the parts
// are at other heights of the page then (`sum_tops`).
@(private)
panel_begin :: proc(l: ^Layout, force := false) -> bool {
	hidden: []u8
	if l.doc != nil && !l.doc.unclosed && l.doc.hidden > 0 {
		hidden = l.doc.source[:min(l.doc.hidden, len(l.doc.source))]
	}
	if !force && bytes.equal(hidden, l.panel.source) {
		return false
	}
	had := l.panel.height > 0
	panel_destroy(l)
	if len(hidden) == 0 {
		return had
	}
	panel := &l.panel
	mem.dynamic_arena_init(&panel.memory, block_size = 4096)
	panel.made = true
	arena := mem.dynamic_arena_allocator(&panel.memory)
	panel.source = bytes.clone(hidden, arena)
	entries := document.front_matter(panel.source, len(panel.source), arena)
	if len(entries) == 0 {
		return had
	}
	size := PANEL_SIZE * l.m.body
	line := PANEL_LINE * size
	pad := PANEL_PAD * size
	keys := PANEL_KEYS * l.column
	value_x := l.column_x + keys
	value_w := max(l.column - keys, 20)
	y := l.m.page_pad * TOP_PAD
	for entry in entries {
		row := y + pad
		bottom := panel_text(l, entry.key, size, line, l.style.secondary, l.column_x, row, max(keys - PANEL_GAP * size, 20))
		switch {
		case len(entry.items) > 0:
			bottom = max(bottom, panel_pills(l, entry.items, value_x, row, value_w))
		case entry.blank:
		case entry.value == "":
			bottom = max(bottom, panel_text(l, "—", size, line, l.style.secondary, value_x, row, value_w))
		case:
			bottom = max(bottom, panel_text(l, entry.value, size, line, l.style.text, value_x, row, value_w))
		}
		y = bottom + pad
	}
	y += PANEL_BELOW * l.m.body
	append(&panel.decor, Decor{x = l.column_x, y = y, w = l.column, h = 1, color = l.style.rule})
	panel.height = y + 1 + PANEL_AFTER * l.m.body
	return true
}

@(private)
panel_destroy :: proc(l: ^Layout) {
	panel := &l.panel
	for line in panel.lines {
		text.line_destroy(line.line)
	}
	for t in panel.texts {
		text.paragraph_destroy(t.shaped)
	}
	delete(panel.texts)
	delete(panel.lines)
	delete(panel.decor)
	if panel.made {
		mem.dynamic_arena_destroy(&panel.memory)
	}
	panel^ = {}
}

// One text of the panel at (x, y), in lines of `width`. Returns the y
// below its last line.
@(private)
panel_text :: proc(l: ^Layout, label: string, size, line_height: f32, color: base.Color, x, y, width: f32) -> f32 {
	if label == "" {
		return y + line_height
	}
	panel := &l.panel
	runs := [1]text.Run{{0, len(label), font(l, .Regular, size)}}
	shaped := text.paragraph_create(label, runs[:])
	append(&panel.texts, Panel_Text{shaped, color, line_height})
	bottom := y
	for start := 0; true; {
		broken := text.paragraph_next_line(shaped, start, max(width, 20)) or_break
		append(&panel.lines, Panel_Line{len(panel.texts) - 1, broken, x, bottom})
		start = broken.end
		bottom += line_height
	}
	return bottom
}

// The items of a sequence as pills, from (x, y) to the right and down in
// rows of `width`. Returns the y below the last row.
@(private)
panel_pills :: proc(l: ^Layout, items: []string, x, y, width: f32) -> f32 {
	panel := &l.panel
	size := PILL_SIZE * PANEL_SIZE * l.m.body
	line := PANEL_LINE * size
	height := line + 2 * PILL_PAD_Y * size
	pad := PILL_PAD_X * size
	tint := l.style.link
	tint.a = u8(f32(tint.a) * PILL_TINT)
	at_x, at_y := x, y
	for item in items {
		// The text first, at the left edge of the row: its width says if
		// the pill is in this row, and it moves there.
		first := len(panel.lines)
		bottom := panel_text(l, item, size, line, l.style.link, x + pad, at_y + PILL_PAD_Y * size, max(width - 2 * pad, 20))
		inner: f32
		for placed in panel.lines[first:] {
			inner = max(inner, placed.line.width)
		}
		wide := inner + 2 * pad
		tall := max(bottom + PILL_PAD_Y * size - at_y, height)
		// More than one line, and not a part of a point from the sums.
		if tall < height + 0.5 {
			tall = height
		}
		if at_x > x && (at_x + wide > x + width || tall > height) {
			// The next row, for a pill that is too wide for the rest of
			// this one or has more than one line.
			down := height + PILL_GAP_Y * size
			for &placed in panel.lines[first:] {
				placed.top += down
			}
			at_x = x
			at_y += down
		}
		for &placed in panel.lines[first:] {
			placed.x += at_x - x
		}
		append(&panel.decor, Decor{x = at_x, y = at_y, w = wide, h = tall, color = tint, radius = min(tall, height) / 2})
		at_x += wide + PILL_GAP_X * size
		if tall > height {
			at_x = x
			at_y += tall + PILL_GAP_Y * size
		}
	}
	return at_x > x ? at_y + height + PILL_GAP_Y * size : at_y
}

// The quads of the panel between two heights of the page, as `display`
// makes them for the parts.
@(private)
panel_display :: proc(
	l: ^Layout,
	cache: ^text.Glyph_Cache,
	y0, y1: f64,
	origin_y: f64,
	rects, glyphs: ^[dynamic]base.Quad,
	buffer: ^text.Glyph_Buffer,
) {
	panel := &l.panel
	if panel.height == 0 || l.origin + f64(panel.height) <= y0 || l.origin >= y1 {
		return
	}
	scale := cache.scale
	from, to := f32(y0 - l.origin), f32(y1 - l.origin)
	for d in panel.decor {
		if d.y + d.h >= from && d.y <= to {
			append(rects, rect_quad(d.x, d.y, d.w, d.h, d.color, d.radius, scale, l.origin, origin_y))
		}
	}
	for placed in panel.lines {
		shown := &panel.texts[placed.of]
		if placed.top + shown.line_height < from || placed.top > to {
			continue
		}
		baseline := line_baseline(placed.top, shown.line_height, placed.line.ascent, placed.line.descent)
		text.line_glyphs(placed.line, buffer)
		run_font: base.Font
		run_font_id: u16
		for g in buffer.glyphs {
			if g.font != run_font {
				run_font = g.font
				run_font_id = text.font_id(cache, g.font)
			}
			glyph_quad(cache, glyphs, run_font_id, g, placed.x, l.origin, baseline, origin_y, shown.color)
		}
	}
}
