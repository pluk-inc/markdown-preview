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

// The quad of a rectangle of a part. `top` is the top of the part on the
// page; the edges are put on whole pixels of the page, not of the part,
// so they are the same pixels wherever the part is.
@(private)
rect_quad :: proc(x, y, w, h: f32, color: base.Color, radius, scale: f32, top, origin_y: f64) -> base.Quad {
	x0, x1 := math.round(x * scale), math.round((x + w) * scale)
	y0 := math.round((top + f64(y)) * f64(scale))
	y1 := math.round((top + f64(y + h)) * f64(scale))
	return base.Quad{pos = {x0, f32(y0 - origin_y)}, size = {max(x1 - x0, 1), f32(max(y1 - y0, 1))}, uv = {radius * scale, 0}, color = color, kind = .Rect}
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
	scale := cache.scale
	for p in first_part_below(l, y0) ..< len(l.parts) {
		part := &l.parts[p]
		if part.top >= y1 {
			break
		}
		// The range from the top of the part.
		from, to := f32(y0 - part.top), f32(y1 - part.top)
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
				append(d.above ? glyphs : rects, rect_quad(d.x, d.y, d.w, d.h, color, d.radius, scale, part.top, origin_y))
			}
			for i in box.line_first ..< box.line_end {
				line := part.lines[i]
				para := &part.paras[line.para]
				if line.top + para.line_height < from || line.top > to {
					continue
				}
				line = shaped_line(l, p, i)^
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
					// On a whole pixel of the page, as the rectangles are.
					py := f32(math.round((part.top + f64(baseline - g.y)) * f64(scale)) - origin_y)
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
}
