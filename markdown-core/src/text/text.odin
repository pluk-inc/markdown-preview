// Text: fonts, paragraphs, lines, and glyph bitmaps. This file has the
// types that every backend shares. A backend file (`coretext_darwin.odin`)
// defines `Paragraph`, `Line`, and `Rasterizer` and the procedures on them;
// the rest of the core sees text only through this package.
//
// All text offsets are byte offsets in the UTF-8 string of the paragraph.
package text

import "../base"

// A part of a paragraph that has one font.
Run :: struct {
	start, end: int,
	font:       base.Font,
}

// One glyph of a laid-out line.
Glyph :: struct {
	font:  base.Font, // owned by the line
	id:    u16,
	x, y:  f32, // points from the line's origin on the baseline; y goes up
	index: int, // byte offset of its character
}

Font_Kind :: enum {
	Regular,
	Bold,
	Semibold,
	Mono,
}

SUBPIXEL_BINS :: 4

// A glyph drawn by the rasterizer. The pixels are valid until the next
// call. Rows go from the top down.
Bitmap :: struct {
	pixels: [^]u8,
	stride: int, // bytes from one row to the next
	w, h:   int, // px
	left:   int, // px from the pen position to the left edge
	top:    int, // px from the baseline up to the top edge
}
