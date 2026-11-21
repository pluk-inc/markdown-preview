package mdcore

import "core:math"
import "core:mem"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"

SUBPIXEL_BINS :: 4
SCRATCH :: 256 // px; larger glyphs are cut
GRAY_W :: 1024
GRAY_H :: 2048
COLR_W :: 512
COLR_H :: 512

Glyph_Key :: struct {
	font:  u16,
	glyph: u16,
	bin:   u8,
}

Glyph_Entry :: struct {
	x, y, w, h: u16, // atlas px
	bx, top:    i16, // px from the pen position to the left edge / from the baseline up to the top edge
	is_color:   bool,
}

Atlas :: struct {
	w, h:         int,
	bpp:          int,
	pixels:       []u8,
	pen_x, pen_y: int,
	row_h:        int,
	// Rows written since the last upload; empty when y1 <= y0.
	dirty_y0:     int,
	dirty_y1:     int,
}

atlas_alloc :: proc(a: ^Atlas, w, h: int) -> (x, y: int, ok: bool) {
	if a.pen_x + w > a.w {
		a.pen_x = 0
		a.pen_y += a.row_h
		a.row_h = 0
	}
	if a.pen_y + h > a.h || w > a.w {
		return 0, 0, false
	}
	x, y = a.pen_x, a.pen_y
	a.pen_x += w
	a.row_h = max(a.row_h, h)
	a.dirty_y0 = min(a.dirty_y0, y)
	a.dirty_y1 = max(a.dirty_y1, y + h)
	return x, y, true
}

// Empties the glyph cache when the backing scale changed.
atlas_prepare :: proc(ctx: ^Ctx) {
	if ctx.scratch_scale == ctx.scale {
		return
	}
	if ctx.scratch_gray != nil {
		CG.ContextRelease(ctx.scratch_gray)
		CG.ContextRelease(ctx.scratch_colr)
	}
	gray_space := CG.ColorSpaceCreateDeviceGray()
	rgb_space := CG.ColorSpaceCreateDeviceRGB()
	ctx.scratch_gray = CG.BitmapContextCreate(nil, SCRATCH, SCRATCH, 8, SCRATCH, gray_space, CG.BitmapInfo(u32(CG.ImageAlphaInfo.None)))
	// BGRA, premultiplied: kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
	ctx.scratch_colr = CG.BitmapContextCreate(nil, SCRATCH, SCRATCH, 8, SCRATCH * 4, rgb_space, CG.BitmapInfo(u32(CG.ImageAlphaInfo.PremultipliedFirst) | 2 << 12))
	CG.ColorSpaceRelease(gray_space)
	CG.ColorSpaceRelease(rgb_space)
	for cg in ([2]CG.ContextRef{ctx.scratch_gray, ctx.scratch_colr}) {
		CG.ContextScaleCTM(cg, f64(ctx.scale), f64(ctx.scale))
		CG.ContextSetShouldSmoothFonts(cg, false)
		CG.ContextSetAllowsFontSubpixelPositioning(cg, true)
		CG.ContextSetShouldSubpixelPositionFonts(cg, true)
		CG.ContextSetAllowsFontSubpixelQuantization(cg, false)
		CG.ContextSetShouldSubpixelQuantizeFonts(cg, false)
	}
	CG.ContextSetGrayFillColor(ctx.scratch_gray, 1, 1)
	ctx.scratch_scale = ctx.scale

	// Empty atlases; `rasterize` allocates the pixels of one on first use.
	clear(&ctx.cache)
	ctx.gray = Atlas{w = GRAY_W, h = GRAY_H, bpp = 1, pixels = ctx.gray.pixels, dirty_y0 = GRAY_H}
	ctx.colr = Atlas{w = COLR_W, h = COLR_H, bpp = 4, pixels = ctx.colr.pixels, dirty_y0 = COLR_H}
}

atlas_destroy :: proc(ctx: ^Ctx) {
	if ctx.scratch_gray != nil {
		CG.ContextRelease(ctx.scratch_gray)
		CG.ContextRelease(ctx.scratch_colr)
	}
	for f in ctx.run_fonts {
		CF.Release(CF.TypeRef(f.font))
	}
	delete(ctx.run_fonts)
	delete(ctx.cache)
	delete(ctx.gray.pixels)
	delete(ctx.colr.pixels)
}

run_font_id :: proc(ctx: ^Ctx, font: CT.FontRef) -> u16 {
	for f, i in ctx.run_fonts {
		if f.font == font || CF.Equal(CF.TypeRef(f.font), CF.TypeRef(font)) {
			return u16(i)
		}
	}
	CF.Retain(CF.TypeRef(font))
	append(&ctx.run_fonts, Run_Font{font, .ColorGlyphs in CT.FontGetSymbolicTraits(font)})
	return u16(len(ctx.run_fonts) - 1)
}

atlas_get :: proc(ctx: ^Ctx, fid: u16, glyph: CG.Glyph, bin: u8) -> Glyph_Entry {
	key := Glyph_Key{fid, u16(glyph), bin}
	if e, ok := ctx.cache[key]; ok {
		return e
	}
	e := rasterize(ctx, fid, glyph, bin)
	ctx.cache[key] = e
	return e
}

rasterize :: proc(ctx: ^Ctx, fid: u16, glyph: CG.Glyph, bin: u8) -> Glyph_Entry {
	rf := ctx.run_fonts[fid]
	g := glyph
	rect := CT.FontGetBoundingRectsForGlyphs(rf.font, .Default, &g, nil, 1)
	if rect.size.width <= 0 || rect.size.height <= 0 {
		return {}
	}
	s := f64(ctx.scale)
	sub := f64(bin) / SUBPIXEL_BINS
	x0 := math.floor(rect.origin.x * s + sub) - 1
	y0 := math.floor(rect.origin.y * s) - 1
	x1 := math.ceil((rect.origin.x + rect.size.width) * s + sub) + 1
	y1 := math.ceil((rect.origin.y + rect.size.height) * s) + 1
	w := min(int(x1 - x0), SCRATCH)
	h := min(int(y1 - y0), SCRATCH)

	atlas := rf.is_color ? &ctx.colr : &ctx.gray
	if atlas.pixels == nil {
		atlas.pixels = make([]u8, atlas.w * atlas.h * atlas.bpp)
	}
	ax, ay, ok := atlas_alloc(atlas, w, h)
	if !ok {
		return {}
	}
	cg := rf.is_color ? ctx.scratch_colr : ctx.scratch_gray
	CG.ContextClearRect(cg, CG.Rect{{0, 0}, {f64(w) / s + 1, f64(h) / s + 1}})
	pos := CG.Point{(sub - x0) / s, -y0 / s}
	CT.FontDrawGlyphs(rf.font, &g, &pos, 1, cg)
	// The bitmap's first row is the top; the glyph box sits in the bottom-left corner.
	data := cast([^]u8)CG.BitmapContextGetData(cg)
	bpp := atlas.bpp
	for row in 0 ..< h {
		src := data[((SCRATCH - h + row) * SCRATCH) * bpp:]
		dst := atlas.pixels[((ay + row) * atlas.w + ax) * bpp:]
		mem.copy_non_overlapping(raw_data(dst), src, w * bpp)
	}
	return Glyph_Entry{x = u16(ax), y = u16(ay), w = u16(w), h = u16(h), bx = i16(x0), top = i16(y1), is_color = rf.is_color}
}
