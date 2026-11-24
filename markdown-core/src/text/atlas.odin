package text

import "../base"

GRAY_W :: 1024
GRAY_H :: 2048
COLOR_W :: 512
COLOR_H :: 512
ATLAS_MAX_H :: 16384 // the largest texture of the renderers

// A texture's pixels on the CPU side, filled from the top in rows. The
// renderer uploads the rows between dirty_y0 and dirty_y1 and then empties
// that range.
Atlas :: struct {
	w, h:         int,
	bpp:          int,
	pixels:       []u8,
	pen_x, pen_y: int,
	row_h:        int,
	dirty_y0:     int, // empty when dirty_y1 <= dirty_y0
	dirty_y1:     int,
	// Changes when the atlas is emptied or its height grows. A texture made
	// for another generation must be made again.
	generation:   int,
}

Glyph_Key :: struct {
	font:  u16,
	glyph: u16,
	bin:   u8,
}

Glyph_Entry :: struct {
	x, y, w, h: u16, // atlas px; w == 0: the glyph has no pixels
	left, top:  i16,
	is_color:   bool,
	no_room:    bool, // the atlas was full; stays so until the cache is emptied
}

@(private)
Cached_Font :: struct {
	font:     base.Font,
	is_color: bool,
}

// Every glyph that was drawn, at one backing scale.
Glyph_Cache :: struct {
	scale:      f32,
	fonts:      [dynamic]Cached_Font,
	entries:    map[Glyph_Key]Glyph_Entry,
	gray:       Atlas,
	color:      Atlas,
	rasterizer: Rasterizer,
}

@(private)
atlas_reset :: proc(a: ^Atlas, w, h, bpp: int) {
	a^ = Atlas {
		w          = w,
		h          = h,
		bpp        = bpp,
		pixels     = a.pixels,
		dirty_y0   = h,
		generation = a.generation + 1,
	}
}

@(private)
atlas_alloc :: proc(a: ^Atlas, w, h: int) -> (x, y: int, ok: bool) {
	if w > a.w {
		return
	}
	if a.pen_x + w > a.w {
		a.pen_x = 0
		a.pen_y += a.row_h
		a.row_h = 0
	}
	// Full: double the height. Quads keep their place, because they hold
	// atlas pixels, not fractions of the atlas.
	for a.pen_y + h > a.h {
		if a.h * 2 > ATLAS_MAX_H {
			return
		}
		a.h *= 2
		a.generation += 1
		a.dirty_y0, a.dirty_y1 = 0, a.pen_y + a.row_h
	}
	if needed := a.w * a.h * a.bpp; len(a.pixels) < needed {
		grown := make([]u8, needed)
		copy(grown, a.pixels)
		delete(a.pixels)
		a.pixels = grown
	}
	x, y = a.pen_x, a.pen_y
	a.pen_x += w
	a.row_h = max(a.row_h, h)
	a.dirty_y0 = min(a.dirty_y0, y)
	a.dirty_y1 = max(a.dirty_y1, y + h)
	return x, y, true
}

// Sets the backing scale. A new scale empties the cache, because every
// bitmap in it has the old size.
cache_set_scale :: proc(c: ^Glyph_Cache, scale: f32) {
	if c.scale == scale {
		return
	}
	c.scale = scale
	rasterizer_set_scale(&c.rasterizer, scale)
	clear(&c.entries)
	atlas_reset(&c.gray, GRAY_W, GRAY_H, 1)
	atlas_reset(&c.color, COLOR_W, COLOR_H, 4)
}

cache_destroy :: proc(c: ^Glyph_Cache) {
	rasterizer_destroy(&c.rasterizer)
	for f in c.fonts {
		font_release(f.font)
	}
	delete(c.fonts)
	delete(c.entries)
	delete(c.gray.pixels)
	delete(c.color.pixels)
	c^ = {}
}

// The number of a font in the cache. A caller that draws a run of glyphs of
// one font asks one time and uses `cache_get` with the number.
font_id :: proc(c: ^Glyph_Cache, font: base.Font) -> u16 {
	for f, i in c.fonts {
		if f.font == font || font_equal(f.font, font) {
			return u16(i)
		}
	}
	append(&c.fonts, Cached_Font{font_retain(font), font_has_color(font)})
	return u16(len(c.fonts) - 1)
}

// The place of a glyph in its atlas. The glyph is drawn the first time.
// `bin` is the part of a pixel that the pen stands right of a pixel edge,
// in 1/SUBPIXEL_BINS.
cache_get :: proc(c: ^Glyph_Cache, fid: u16, glyph: u16, bin: u8) -> Glyph_Entry {
	key := Glyph_Key{fid, glyph, bin}
	if entry, ok := c.entries[key]; ok {
		return entry
	}
	cached := c.fonts[fid]
	entry: Glyph_Entry
	if bitmap, ok := rasterize(&c.rasterizer, cached.font, glyph, bin, cached.is_color); ok {
		atlas := cached.is_color ? &c.color : &c.gray
		if x, y, fits := atlas_alloc(atlas, bitmap.w, bitmap.h); fits {
			bpp := atlas.bpp
			for row in 0 ..< bitmap.h {
				dst := atlas.pixels[((y + row) * atlas.w + x) * bpp:]
				copy(dst[:bitmap.w * bpp], bitmap.pixels[row * bitmap.stride:][:bitmap.w * bpp])
			}
			entry = Glyph_Entry {
				x        = u16(x),
				y        = u16(y),
				w        = u16(bitmap.w),
				h        = u16(bitmap.h),
				left     = i16(bitmap.left),
				top      = i16(bitmap.top),
				is_color = cached.is_color,
			}
		} else {
			// The atlas is at its largest size. The entry says so, and the
			// glyph is tried again only after the cache is emptied.
			entry.no_room = true
		}
	}
	c.entries[key] = entry
	return entry
}
