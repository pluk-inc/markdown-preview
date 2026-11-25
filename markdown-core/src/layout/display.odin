package layout

import "../base"
import "../document"
import "../text"
import "core:math"

// The first part that ends below the height y of the page, or len(parts).
@(private)
first_part_below :: proc(l: ^Layout, y: f64) -> int {
	lo, hi := 0, len(l.parts)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.parts[mid].top + f64(l.parts[mid].height) <= y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The first box of a part that ends below y, or len(boxes). y counts from
// the top of the part.
@(private)
first_box_below :: proc(part: ^Part, y: f32) -> int {
	lo, hi := 0, len(part.boxes)
	for lo < hi {
		mid := (lo + hi) / 2
		if part.boxes[mid].bottom <= y {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The whole pixel of the page for a height of a part. `top` is the top of
// the part on the page. Each edge that must be sharp goes through this:
// on a whole pixel of the page, not of the part, so it is the same pixel
// wherever the part is.
@(private)
page_pixel :: proc(top: f64, y, scale: f32) -> f64 {
	return math.round((top + f64(y)) * f64(scale))
}

// The quad of a rectangle of a part. `top` is the top of the part on the
// page.
@(private)
rect_quad :: proc(x, y, w, h: f32, color: base.Color, radius, scale: f32, top, origin_y: f64) -> base.Quad {
	x0, x1 := math.round(x * scale), math.round((x + w) * scale)
	y0, y1 := page_pixel(top, y, scale), page_pixel(top, y + h, scale)
	return base.Quad{pos = {x0, f32(y0 - origin_y)}, size = {max(x1 - x0, 1), f32(max(y1 - y0, 1))}, uv = {radius * scale, 0}, color = color, kind = .Rect}
}

// The quad of a mark that stands beside text (`Decor.to_baseline`): from
// the whole pixel of the line that the text stands on, as the text is
// drawn, with a size in whole pixels. Each edge of `rect_quad` goes to
// its own whole pixel, so a mark of 3.75 points is 7 or 8 or 9 pixels
// high there, a pixel higher or lower beside its text from line to line.
@(private)
mark_quad :: proc(d: Decor, color: base.Color, scale: f32, top, origin_y: f64) -> base.Quad {
	w, h := max(math.round(d.w * scale), 1), max(math.round(d.h * scale), 1)
	y := page_pixel(top, d.y + d.to_baseline, scale) - f64(math.round(d.to_baseline * scale))
	// A circle stays a circle in its whole pixels.
	radius := d.radius * 2 >= min(d.w, d.h) ? min(w, h) / 2 : d.radius * scale
	return base.Quad{pos = {math.round(d.x * scale), f32(y - origin_y)}, size = {w, h}, uv = {radius, 0}, color = color, kind = .Rect}
}

// Makes the quads of the range of the page between y0 and y1 (points).
// `origin_y` (device pixels) is taken from every y, so the numbers stay
// small on a long page. `buffer` is working memory that the caller keeps.
display :: proc(
	l: ^Layout,
	cache: ^text.Glyph_Cache,
	y0, y1: f64,
	origin_y: f64,
	rects, glyphs: ^[dynamic]base.Quad,
	buffer: ^text.Glyph_Buffer,
) {
	for p in first_part_below(l, y0) ..< len(l.parts) {
		part := &l.parts[p]
		if part.top >= y1 {
			break
		}
		display_part(l, cache, p, f32(y0 - part.top), f32(y1 - part.top), origin_y, rects, glyphs, buffer)
	}
}

// The quads of one part. `from` and `to` are the range from the top of
// the part.
@(private)
display_part :: proc(
	l: ^Layout,
	cache: ^text.Glyph_Cache,
	p: int,
	from, to: f32,
	origin_y: f64,
	rects, glyphs: ^[dynamic]base.Quad,
	buffer: ^text.Glyph_Buffer,
) {
	scale := cache.scale
	part := &l.parts[p]
	first := first_box_below(part, from)
	for box, i in part.boxes[first:] {
		if box.top >= to {
			break
		}
		done := l.doc.parts[p].blocks[first + i].done
		for d in part.decor[box.decor_first:box.decor_end] {
			if d.y + d.h < from || d.y > to {
				continue
			}
			color := d.soft_done && done ? done_color(l) : d.color
			if d.to_baseline != 0 {
				append(d.above ? glyphs : rects, mark_quad(d, color, scale, part.top, origin_y))
				continue
			}
			append(d.above ? glyphs : rects, rect_quad(d.x, d.y, d.w, d.h, color, d.radius, scale, part.top, origin_y))
		}
		for i in box.line_first ..< box.line_end {
			line := part.lines[i]
			para := &part.paras[line.para]
			if line.top + para.line_height < from || line.top > to {
				continue
			}
			line = shaped_line(l, p, i)^
			baseline := line_baseline(line.top, para.line_height, line.line.ascent, line.line.descent)
			text.line_glyphs(line.line, buffer)
			// Glyphs come in runs of one span, so the color is looked up
			// only when the span changes.
			span: ^document.Span
			// The number of a list item has the color of the text of
			// the item, as the circle of a bullet has (softer in a
			// quote); text with no span is soft.
			color := para.src == nil && !para.quote ? l.style.text : l.style.secondary
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
				py := f32(page_pixel(part.top, baseline - g.y, scale) - origin_y)
				fx := math.floor(px)
				bin := u8(clamp((px - fx) * text.SUBPIXEL_BINS, 0, text.SUBPIXEL_BINS - 1))
				e := text.cache_get(cache, run_font_id, g.id, bin)
				if e.w == 0 {
					continue
				}
				append(
					glyphs,
					base.Quad {
						pos = {fx + f32(e.left), py - f32(e.top)},
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
