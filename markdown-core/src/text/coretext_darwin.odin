// The text backend for Apple systems: CoreText shapes the text, breaks the
// lines, and draws the glyphs.
//
// CoreText counts in UTF-16 units and the core in UTF-8 bytes. A paragraph
// that is not plain ASCII keeps two tables to change one into the other.
package text

import "../base"
import "core:math"
import "core:unicode/utf8"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"

@(private)
UTF8 :: CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)

// ---- Fonts ------------------------------------------------------------------

@(private)
ct_font :: proc(font: base.Font) -> CT.FontRef {
	return CT.FontRef(rawptr(font))
}

font_retain :: proc(font: base.Font) -> base.Font {
	if font != nil {
		CF.Retain(CF.TypeRef(rawptr(font)))
	}
	return font
}

font_release :: proc(font: base.Font) {
	if font != nil {
		CF.Release(CF.TypeRef(rawptr(font)))
	}
}

font_equal :: proc(a, b: base.Font) -> bool {
	return bool(CF.Equal(CF.TypeRef(rawptr(a)), CF.TypeRef(rawptr(b))))
}

font_has_color :: proc(font: base.Font) -> bool {
	return .ColorGlyphs in CT.FontGetSymbolicTraits(ct_font(font))
}

// A system font. The caller owns the result.
font_system :: proc(kind: Font_Kind, size: f32) -> base.Font {
	named :: proc(name: cstring, size: f32) -> base.Font {
		cf_name := CF.StringCreateWithCString(nil, name, UTF8)
		defer CF.Release(CF.TypeRef(cf_name))
		return base.Font(rawptr(CT.FontCreateWithName(cf_name, f64(size), nil)))
	}
	switch kind {
	case .Regular:
		return base.Font(rawptr(CT.FontCreateUIFontForLanguage(.System, f64(size), nil)))
	case .Bold:
		return base.Font(rawptr(CT.FontCreateUIFontForLanguage(.EmphasizedSystem, f64(size), nil)))
	case .Semibold:
		return named(".AppleSystemUIFontDemi", size)
	case .Mono:
		return named(".AppleSystemUIFontMonospaced-Regular", size)
	}
	return nil
}

// The same face at another size, upright or italic. A face that has no
// italic stays upright. The caller owns the result.
font_sized :: proc(font: base.Font, size: f32, italic := false) -> base.Font {
	sized := CT.FontCreateCopyWithAttributes(ct_font(font), f64(size), nil, nil)
	if italic {
		if slanted := CT.FontCreateCopyWithSymbolicTraits(sized, f64(size), nil, {.Italic}, {.Italic}); slanted != nil {
			CF.Release(CF.TypeRef(sized))
			sized = slanted
		}
	}
	return base.Font(rawptr(sized))
}

// ---- Paragraphs -------------------------------------------------------------

Paragraph :: struct {
	astr:        CF.MutableAttributedStringRef,
	typesetter:  CT.TypesetterRef, // made for the first line break
	len:         int, // bytes
	len16:       int, // UTF-16 units
	// Empty for ASCII text, where a byte offset is the UTF-16 offset.
	byte_to_16:  []i32, // len + 1 entries
	u16_to_byte: []i32, // len16 + 1 entries
}

@(private)
to_16 :: proc(p: ^Paragraph, byte_index: int) -> CF.Index {
	i := clamp(byte_index, 0, p.len)
	return CF.Index(len(p.byte_to_16) == 0 ? i : int(p.byte_to_16[i]))
}

@(private)
to_byte :: proc(p: ^Paragraph, index16: CF.Index) -> int {
	i := clamp(int(index16), 0, p.len16)
	return len(p.u16_to_byte) == 0 ? i : int(p.u16_to_byte[i])
}

// Makes a paragraph from UTF-8 text and the fonts of its parts. Bytes that
// are not valid UTF-8 show as "?".
paragraph_create :: proc(s: string, runs: []Run) -> ^Paragraph {
	p := new(Paragraph)
	p.len = len(s)
	ascii := true
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			ascii = false
			break
		}
	}
	bytes := transmute([]u8)s
	cleaned: []u8
	defer delete(cleaned)
	if !ascii {
		p.byte_to_16 = make([]i32, len(s) + 1)
		units: i32
		for i := 0; i < len(s); {
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width <= 1 {
				if cleaned == nil {
					cleaned = make([]u8, len(s))
					copy(cleaned, s)
					bytes = cleaned
				}
				cleaned[i] = '?'
				width = 1
			}
			for k in 0 ..< width {
				p.byte_to_16[i + k] = units
			}
			units += r >= 0x10000 ? 2 : 1
			i += width
		}
		p.byte_to_16[len(s)] = units
	}
	str := CF.StringCreateWithBytes(nil, raw_data(bytes), CF.Index(len(bytes)), UTF8, false)
	if str == nil {
		// CoreFoundation refused text that the pass above took: show the
		// ASCII part.
		if cleaned == nil {
			cleaned = make([]u8, len(s))
			copy(cleaned, s)
		}
		for &b in cleaned {
			if b >= 0x80 {
				b = '?'
			}
		}
		delete(p.byte_to_16)
		p.byte_to_16 = nil
		str = CF.StringCreateWithBytes(nil, raw_data(cleaned), CF.Index(len(cleaned)), UTF8, false)
	}
	defer CF.Release(CF.TypeRef(str))
	p.len16 = int(CF.StringGetLength(str))
	if len(p.byte_to_16) > 0 {
		p.u16_to_byte = make([]i32, p.len16 + 1)
		// Each unit gets the byte where its character starts.
		for i := len(s); i >= 0; i -= 1 {
			if unit := int(p.byte_to_16[i]); unit <= p.len16 {
				p.u16_to_byte[unit] = i32(i)
			}
		}
		// The second unit of a pair points at the same character.
		for unit in 1 ..< p.len16 {
			if p.u16_to_byte[unit] == 0 {
				p.u16_to_byte[unit] = p.u16_to_byte[unit - 1]
			}
		}
	}
	p.astr = CF.AttributedStringCreateMutable(nil, 0)
	CF.AttributedStringReplaceString(p.astr, CF.Range{0, 0}, str)
	for run in runs {
		start, end := to_16(p, run.start), to_16(p, run.end)
		if end > start && run.font != nil {
			CF.AttributedStringSetAttribute(p.astr, CF.Range{start, end - start}, CT.kFontAttributeName, CF.TypeRef(rawptr(run.font)))
		}
	}
	return p
}

paragraph_destroy :: proc(p: ^Paragraph) {
	if p == nil {
		return
	}
	if p.typesetter != nil {
		CF.Release(CF.TypeRef(p.typesetter))
	}
	CF.Release(CF.TypeRef(p.astr))
	delete(p.byte_to_16)
	delete(p.u16_to_byte)
	free(p)
}

// Width of the paragraph on one line, without wrapping.
paragraph_natural_width :: proc(p: ^Paragraph) -> f32 {
	if p.len == 0 {
		return 0
	}
	line := CT.LineCreateWithAttributedString(CF.AttributedStringRef(p.astr))
	defer CF.Release(CF.TypeRef(line))
	return f32(CT.LineGetTypographicBounds(line, nil, nil, nil))
}

// ---- Lines ------------------------------------------------------------------

Line :: struct {
	handle:     CT.LineRef,
	para:       ^Paragraph,
	start, end: int, // bytes
	width:      f32, // without the white space at the end
	ascent:     f32,
	descent:    f32,
}

// The typesetter of a paragraph, made at its first use.
@(private)
typesetter :: proc(p: ^Paragraph) -> CT.TypesetterRef {
	if p.typesetter == nil {
		p.typesetter = CT.TypesetterCreateWithAttributedString(CF.AttributedStringRef(p.astr))
	}
	return p.typesetter
}

// The line that starts at byte `start` and fits in `width`. False at the
// end of the paragraph. The caller owns the line (`line_destroy`).
paragraph_next_line :: proc(p: ^Paragraph, start: int, width: f32) -> (line: Line, ok: bool) {
	if start >= p.len {
		return
	}
	start16 := to_16(p, start)
	count := CT.TypesetterSuggestLineBreak(typesetter(p), start16, f64(width))
	if count <= 0 {
		return
	}
	handle := CT.TypesetterCreateLine(p.typesetter, CF.Range{start16, count})
	ascent, descent: CG.Float
	line_width := CT.LineGetTypographicBounds(handle, &ascent, &descent, nil)
	line_width -= CT.LineGetTrailingWhitespaceWidth(handle)
	return Line {
			handle = handle,
			para = p,
			start = start,
			end = to_byte(p, start16 + count),
			width = f32(line_width),
			ascent = f32(ascent),
			descent = f32(descent),
		},
		true
}

line_destroy :: proc(line: Line) {
	if line.handle != nil {
		CF.Release(CF.TypeRef(line.handle))
	}
}

// Frees the shaped glyphs of a line and keeps its numbers: the range, the
// width, the ascent, and the descent. `line_restore` makes the glyphs
// again; until then the line must not go to a procedure that reads glyphs.
line_release :: proc(line: ^Line) {
	line_destroy(line^)
	line.handle = nil
	line.para = nil
}

// Shapes a released line again. `p` is a paragraph with the same text and
// fonts as the one that the line was broken from.
line_restore :: proc(line: ^Line, p: ^Paragraph) {
	start16 := to_16(p, line.start)
	line.handle = CT.TypesetterCreateLine(typesetter(p), CF.Range{start16, to_16(p, line.end) - start16})
	line.para = p
}

// True while the line has its shaped glyphs.
line_shaped :: proc(line: Line) -> bool {
	return line.handle != nil
}

// The glyphs of one line, and the buffers that the backend fills them
// from. The caller keeps one and uses it for every line.
Glyph_Buffer :: struct {
	glyphs:    [dynamic]Glyph,
	ids:       [dynamic]CG.Glyph,
	positions: [dynamic]CG.Point,
	indices:   [dynamic]CF.Index,
}

glyph_buffer_destroy :: proc(b: ^Glyph_Buffer) {
	delete(b.glyphs)
	delete(b.ids)
	delete(b.positions)
	delete(b.indices)
	b^ = {}
}

// Puts the glyphs of the line in `out.glyphs`.
line_glyphs :: proc(line: Line, out: ^Glyph_Buffer) {
	clear(&out.glyphs)
	runs := CT.LineGetGlyphRuns(line.handle)
	for r in 0 ..< CF.ArrayGetCount(runs) {
		run := CT.RunRef(CF.ArrayGetValueAtIndex(runs, r))
		n := int(CT.RunGetGlyphCount(run))
		if n == 0 {
			continue
		}
		font := base.Font(CF.DictionaryGetValue(CT.RunGetAttributes(run), rawptr(CT.kFontAttributeName)))
		resize(&out.ids, n)
		resize(&out.positions, n)
		resize(&out.indices, n)
		CT.RunGetGlyphs(run, CF.Range{0, 0}, raw_data(out.ids))
		CT.RunGetPositions(run, CF.Range{0, 0}, raw_data(out.positions))
		CT.RunGetStringIndices(run, CF.Range{0, 0}, raw_data(out.indices))
		for k in 0 ..< n {
			append(
				&out.glyphs,
				Glyph {
					font = font,
					id = u16(out.ids[k]),
					x = f32(out.positions[k].x),
					y = f32(out.positions[k].y),
					index = to_byte(line.para, out.indices[k]),
				},
			)
		}
	}
}

// The x of the caret before the character at byte `index`.
line_x_for_index :: proc(line: Line, index: int) -> f32 {
	return f32(CT.LineGetOffsetForStringIndex(line.handle, to_16(line.para, index), nil))
}

// The byte offset of the caret position nearest to `x`.
line_index_for_x :: proc(line: Line, x: f32) -> int {
	index := CT.LineGetStringIndexForPosition(line.handle, CG.Point{f64(x), 0})
	if index < 0 {
		return line.start
	}
	return clamp(to_byte(line.para, index), line.start, line.end)
}

// ---- Glyph bitmaps ----------------------------------------------------------

@(private)
SCRATCH :: 256 // px; a larger glyph is cut

Rasterizer :: struct {
	gray:  CG.ContextRef,
	color: CG.ContextRef,
	scale: f32,
}

rasterizer_destroy :: proc(r: ^Rasterizer) {
	if r.gray != nil {
		CG.ContextRelease(r.gray)
		CG.ContextRelease(r.color)
	}
	r^ = {}
}

rasterizer_set_scale :: proc(r: ^Rasterizer, scale: f32) {
	rasterizer_destroy(r)
	r.scale = scale
	gray_space := CG.ColorSpaceCreateDeviceGray()
	rgb_space := CG.ColorSpaceCreateDeviceRGB()
	r.gray = CG.BitmapContextCreate(nil, SCRATCH, SCRATCH, 8, SCRATCH, gray_space, CG.BitmapInfo(u32(CG.ImageAlphaInfo.None)))
	// BGRA, premultiplied: kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
	r.color = CG.BitmapContextCreate(nil, SCRATCH, SCRATCH, 8, SCRATCH * 4, rgb_space, CG.BitmapInfo(u32(CG.ImageAlphaInfo.PremultipliedFirst) | 2 << 12))
	CG.ColorSpaceRelease(gray_space)
	CG.ColorSpaceRelease(rgb_space)
	for cg in ([2]CG.ContextRef{r.gray, r.color}) {
		CG.ContextScaleCTM(cg, f64(scale), f64(scale))
		CG.ContextSetShouldSmoothFonts(cg, false)
		CG.ContextSetAllowsFontSubpixelPositioning(cg, true)
		CG.ContextSetShouldSubpixelPositionFonts(cg, true)
		CG.ContextSetAllowsFontSubpixelQuantization(cg, false)
		CG.ContextSetShouldSubpixelQuantizeFonts(cg, false)
	}
	CG.ContextSetGrayFillColor(r.gray, 1, 1)
}

// Draws one glyph. False when the glyph has no pixels (a space).
rasterize :: proc(r: ^Rasterizer, font: base.Font, glyph: u16, bin: u8, is_color: bool) -> (bitmap: Bitmap, ok: bool) {
	g := CG.Glyph(glyph)
	rect := CT.FontGetBoundingRectsForGlyphs(ct_font(font), .Default, &g, nil, 1)
	if rect.size.width <= 0 || rect.size.height <= 0 {
		return
	}
	s := f64(r.scale)
	sub := f64(bin) / SUBPIXEL_BINS
	x0 := math.floor(rect.origin.x * s + sub) - 1
	y0 := math.floor(rect.origin.y * s) - 1
	x1 := math.ceil((rect.origin.x + rect.size.width) * s + sub) + 1
	y1 := math.ceil((rect.origin.y + rect.size.height) * s) + 1
	w := min(int(x1 - x0), SCRATCH)
	h := min(int(y1 - y0), SCRATCH)

	cg := is_color ? r.color : r.gray
	bpp := is_color ? 4 : 1
	CG.ContextClearRect(cg, CG.Rect{{0, 0}, {f64(w) / s + 1, f64(h) / s + 1}})
	pos := CG.Point{(sub - x0) / s, -y0 / s}
	CT.FontDrawGlyphs(ct_font(font), &g, &pos, 1, cg)
	// The bitmap's first row is the top; the glyph box sits in the
	// bottom-left corner.
	data := cast([^]u8)CG.BitmapContextGetData(cg)
	return Bitmap {
			pixels = data[(SCRATCH - h) * SCRATCH * bpp:],
			stride = SCRATCH * bpp,
			w = w,
			h = h,
			left = int(x0),
			top = int(y1),
		},
		true
}
