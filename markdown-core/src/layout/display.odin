package layout

import "../base"
import "../document"
import "../text"
import "core:math"

// The first box that ends below y, or len(boxes).
@(private)
first_box_below :: proc(l: ^Layout, y: f32) -> int {
	lo, hi := 0, len(l.boxes)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.boxes[mid].bottom <= y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
rect_quad :: proc(x, y, w, h: f32, color: base.Color, radius, scale, origin_y: f32) -> base.Quad {
	x0, y0 := math.round(x * scale), math.round(y * scale)
	x1, y1 := math.round((x + w) * scale), math.round((y + h) * scale)
	return base.Quad{pos = {x0, y0 - origin_y}, size = {max(x1 - x0, 1), max(y1 - y0, 1)}, uv = {radius * scale, 0}, color = color, kind = .Rect}
}

// Makes the quads of the part of the page between y0 and y1 (points).
// `origin_y` (device pixels) is taken from every y, so the numbers stay
// small on a long page. `buffer` is working memory that the caller keeps.
display :: proc(
	l: ^Layout,
	cache: ^text.Glyph_Cache,
	y0, y1: f32,
	origin_y: f32,
	rects, glyphs: ^[dynamic]base.Quad,
	buffer: ^text.Glyph_Buffer,
) {
	scale := cache.scale
	first := first_box_below(l, y0)
	for box, i in l.boxes[first:] {
		if box.top >= y1 {
			break
		}
		// A box is the place of the block with the same number.
		done := l.doc.blocks[first + i].done
		for d in l.decor[box.decor_first:box.decor_end] {
			if d.y + d.h < y0 || d.y > y1 {
				continue
			}
			color := d.soft_done && done ? done_color(l) : d.color
			append(d.above ? glyphs : rects, rect_quad(d.x, d.y, d.w, d.h, color, d.radius, scale, origin_y))
		}
		for i in box.line_first ..< box.line_end {
			line := l.lines[i]
			para := &l.paras[line.para]
			if line.top + para.line_height < y0 || line.top > y1 {
				continue
			}
			line = shaped_line(l, i)^
			baseline := line.top + (para.line_height - (line.line.ascent + line.line.descent)) / 2 + line.line.ascent
			text.line_glyphs(line.line, buffer)
			// Glyphs come in runs of one span, so the color is looked up
			// only when the span changes.
			span: ^document.Span
			color := l.style.secondary
			// The same for the font: a line has a few runs of one font each.
			run_font: base.Font
			run_font_id: u16
			for g in buffer.glyphs {
				if g.font != run_font {
					run_font = g.font
					run_font_id = text.font_id(cache, g.font)
				}
				if para.src != nil {
					index := para.base + g.index
					if span == nil || index < span.start || index >= span.end {
						span = document.span_at(para.src, index)
						color = span_color(l, para, span.style, done)
					}
				}
				px := (line.x + g.x) * scale
				py := math.round((baseline - g.y) * scale)
				fx := math.floor(px)
				bin := u8(clamp((px - fx) * text.SUBPIXEL_BINS, 0, text.SUBPIXEL_BINS - 1))
				e := text.cache_get(cache, run_font_id, g.id, bin)
				if e.w == 0 {
					continue
				}
				append(
					glyphs,
					base.Quad {
						pos = {fx + f32(e.left), py - f32(e.top) - origin_y},
						size = {f32(e.w), f32(e.h)},
						uv = {f32(e.x), f32(e.y)},
						uvsize = {f32(e.w), f32(e.h)},
						color = color,
						kind = e.is_color ? .Color_Glyph : .Gray_Glyph,
					},
				)
			}
		}
	}
}
