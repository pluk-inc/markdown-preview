package mdcore

import "core:math"
import "core:mem"
import "core:time"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"

push_rect :: proc(ctx: ^Ctx, x, y, w, h: f32, color: Color, radius: f32 = 0) {
	s := ctx.scale
	x0, y0 := math.round(x * s), math.round(y * s)
	x1, y1 := math.round((x + w) * s), math.round((y + h) * s)
	append(&ctx.rects, Instance{pos = {x0, y0}, size = {max(x1 - x0, 1), max(y1 - y0, 1)}, uv = {radius * s, 0}, color = color, kind = 0})
}

span_at :: proc(t: ^Text, index: int) -> ^Span {
	lo, hi := 0, len(t.spans) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if t.spans[mid].end <= index {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return &t.spans[lo]
}

// Width of the text on one line, without wrapping.
natural_width :: proc(t: ^Text) -> f32 {
	if t.len == 0 {
		return 0
	}
	line := CT.LineCreateWithAttributedString(CF.AttributedStringRef(t.astr))
	defer CF.Release(CF.TypeRef(line))
	return f32(CT.LineGetTypographicBounds(line, nil, nil, nil))
}

emit_line :: proc(ctx: ^Ctx, t: ^Text, line: CT.LineRef, lx, top, baseline: f32) {
	s := ctx.scale
	runs := CT.LineGetGlyphRuns(line)
	for r in 0 ..< CF.ArrayGetCount(runs) {
		run := CT.RunRef(CF.ArrayGetValueAtIndex(runs, r))
		n := int(CT.RunGetGlyphCount(run))
		if n == 0 {
			continue
		}
		font := CT.FontRef(CF.DictionaryGetValue(CT.RunGetAttributes(run), rawptr(CT.kFontAttributeName)))
		fid := run_font_id(ctx, font)
		resize(&ctx.tmp_glyphs, n)
		resize(&ctx.tmp_pos, n)
		resize(&ctx.tmp_idx, n)
		CT.RunGetGlyphs(run, CF.Range{0, 0}, raw_data(ctx.tmp_glyphs))
		CT.RunGetPositions(run, CF.Range{0, 0}, raw_data(ctx.tmp_pos))
		CT.RunGetStringIndices(run, CF.Range{0, 0}, raw_data(ctx.tmp_idx))
		for k in 0 ..< n {
			px := (lx + f32(ctx.tmp_pos[k].x)) * s
			py := math.round((baseline - f32(ctx.tmp_pos[k].y)) * s)
			fx := math.floor(px)
			bin := u8(clamp((px - fx) * SUBPIXEL_BINS, 0, SUBPIXEL_BINS - 1))
			e := atlas_get(ctx, fid, ctx.tmp_glyphs[k], bin)
			if e.w == 0 {
				continue
			}
			atlas := e.is_color ? &ctx.colr : &ctx.gray
			append(
				&ctx.glyphs,
				Instance {
					pos = {fx + f32(e.bx), py - f32(e.top)},
					size = {f32(e.w), f32(e.h)},
					uv = {f32(e.x), f32(e.y)},
					uvsize = {f32(e.w), f32(e.h)},
					color = span_at(t, int(ctx.tmp_idx[k])).color,
					kind = e.is_color ? 2 : 1,
				},
			)
		}
	}
	// Backgrounds of inline code.
	range := CT.LineGetStringRange(line)
	line_start, line_end := int(range.location), int(range.location + range.length)
	// Spans are in text order: start at the first one that reaches the line.
	first := len(t.spans) > 0 ? mem.ptr_sub(span_at(t, line_start), &t.spans[0]) : 0
	for sp in t.spans[first:] {
		if sp.start >= line_end {
			break
		}
		if .Code_Bg not_in sp.flags || sp.end <= line_start {
			continue
		}
		x1 := f32(CT.LineGetOffsetForStringIndex(line, CF.Index(max(sp.start, line_start)), nil))
		x2 := f32(CT.LineGetOffsetForStringIndex(line, CF.Index(min(sp.end, line_end)), nil))
		h := t.size * 1.3
		y := top + (t.line_height - h) / 2
		push_rect(ctx, lx + x1 - 3.5, y - 0.5, x2 - x1 + 7, h + 1, CODE_BORDER, 5)
		push_rect(ctx, lx + x1 - 3, y, x2 - x1 + 6, h, CODE_BG, 4.5)
	}
}

// Breaks the text into lines of `width` and emits the glyphs. Returns the y
// below the last line.
layout_text :: proc(ctx: ^Ctx, t: ^Text, x, y, width: f32, align := Align.Left) -> f32 {
	if t.len == 0 {
		return y + t.line_height
	}
	y := y
	ctx.text_order += 1
	ts := CT.TypesetterCreateWithAttributedString(CF.AttributedStringRef(t.astr))
	defer CF.Release(CF.TypeRef(ts))
	start := 0
	for start < t.len {
		n := int(CT.TypesetterSuggestLineBreak(ts, CF.Index(start), f64(max(width, 20))))
		if n <= 0 {
			break
		}
		line := CT.TypesetterCreateLine(ts, CF.Range{CF.Index(start), CF.Index(n)})
		ascent, descent: CG.Float
		line_width := f32(CT.LineGetTypographicBounds(line, &ascent, &descent, nil))
		line_width -= f32(CT.LineGetTrailingWhitespaceWidth(line))
		lx := x
		switch align {
		case .Left:
		case .Center:
			lx += (width - line_width) / 2
		case .Right:
			lx += width - line_width
		}
		baseline := y + (t.line_height - f32(ascent + descent)) / 2 + f32(ascent)
		emit_line(ctx, t, line, lx, y, baseline)
		// The line is kept for hit testing and the selection.
		append(&ctx.lines, Line_Rec{text = t, order = ctx.text_order, line = line, x = lx, top = y, width = line_width, start = start, end = start + n})
		y += t.line_height
		start += n
	}
	return y
}

layout_table :: proc(ctx: ^Ctx, b: ^Block, x, y, width: f32) -> f32 {
	PAD_X :: 12.0
	PAD_Y :: 6.0
	nrows := len(b.cells) / max(b.ncols, 1)
	if b.ncols == 0 || nrows == 0 {
		return y
	}
	// Column width = widest cell; shrink all columns evenly when too wide.
	widths := make([]f32, b.ncols)
	defer delete(widths)
	total: f32
	for col in 0 ..< b.ncols {
		for row in 0 ..< nrows {
			widths[col] = max(widths[col], natural_width(&b.cells[row * b.ncols + col]) + 1)
		}
		widths[col] = max(widths[col], 24)
		total += widths[col] + 2 * PAD_X
	}
	if total > width {
		text_room := width - f32(b.ncols) * 2 * PAD_X
		for &w in widths {
			w = w / (total - f32(b.ncols) * 2 * PAD_X) * text_room
		}
		total = width
	}
	y := y
	top := y
	for row in 0 ..< nrows {
		row_bottom := y
		cx := x
		for col in 0 ..< b.ncols {
			cell_bottom := layout_text(ctx, &b.cells[row * b.ncols + col], cx + PAD_X, y + PAD_Y, widths[col], b.aligns[col])
			row_bottom = max(row_bottom, cell_bottom + PAD_Y)
			cx += widths[col] + 2 * PAD_X
		}
		if row == 0 {
			push_rect(ctx, x, y, total, row_bottom - y, CODE_BG)
		}
		y = row_bottom
		push_rect(ctx, x, y - 1, total, 1, RULE_COLOR)
	}
	push_rect(ctx, x, top, total, 1, RULE_COLOR)
	cx := x
	for col in 0 ..= b.ncols {
		push_rect(ctx, min(cx, x + total - 1), top, 1, y - top, RULE_COLOR)
		if col < b.ncols {
			cx += widths[col] + 2 * PAD_X
		}
	}
	return y
}

// Layout runs in steps, so the first frame does not wait for a long document:
// layout_begin resets, layout_some adds blocks until `until_y` (points) is
// covered or the time budget ends.
layout_begin :: proc(ctx: ^Ctx) {
	clear(&ctx.rects)
	clear(&ctx.glyphs)
	gpu_reset_quads(ctx)
	free_lines(ctx)
	ctx.text_order = 0
	atlas_prepare(ctx)
	ctx.lay_next = 0
	ctx.lay_y = PAGE_PAD * 0.6
	ctx.content_height = ctx.lay_y
}

layout_done :: proc(ctx: ^Ctx) -> bool {
	return ctx.lay_next >= len(ctx.blocks)
}

layout_some :: proc(ctx: ^Ctx, until_y: f32, budget_ms: f64 = 0) {
	started := time.tick_now()
	column := min(COLUMN_WIDTH, ctx.width - 2 * PAGE_PAD)
	x0 := math.floor((ctx.width - column) / 2)
	y := ctx.lay_y
	for ctx.lay_next < len(ctx.blocks) && y < until_y {
		if budget_ms > 0 && ctx.lay_next % 8 == 0 && time.duration_milliseconds(time.tick_since(started)) > budget_ms {
			break
		}
		i := ctx.lay_next
		b := &ctx.blocks[i]
		ctx.lay_next += 1
		if i > 0 {
			y += b.space_before
		}
		x := x0 + b.indent + f32(b.quote_depth) * QUOTE_INDENT
		width := column - (x - x0)
		top := y
		switch b.kind {
		case .Text:
			if b.marker.len > 0 {
				layout_text(ctx, &b.marker, x - LIST_INDENT, y, LIST_INDENT - 8, .Right)
			}
			y = layout_text(ctx, &b.text, x, y, width)
		case .Code:
			// Backgrounds are drawn before all glyphs, so the card can be
			// added after the text gave its height.
			bottom := layout_text(ctx, &b.text, x + CODE_PAD, y + CODE_PAD, width - 2 * CODE_PAD) + CODE_PAD
			push_rect(ctx, x - 0.5, y - 0.5, width + 1, bottom - y + 1, CODE_BORDER, 8.5)
			push_rect(ctx, x, y, width, bottom - y, CODE_BG, 8)
			y = bottom
		case .Rule:
			push_rect(ctx, x, y, width, 1, RULE_COLOR)
			y += 1
		case .Table:
			y = layout_table(ctx, b, x, y, width)
		}
		for depth in 0 ..< b.quote_depth {
			push_rect(ctx, x0 + b.indent + f32(depth) * QUOTE_INDENT, top, 3, y - top, RULE_COLOR, 1.5)
		}
	}
	ctx.lay_y = y
	ctx.content_height = y + PAGE_PAD
}
