// Types that every package of the core shares. Nothing here depends on a
// platform.
package base

Color :: [4]u8 // r, g, b, a; not premultiplied

// A font object of the platform's text system (a CTFont on Apple systems).
// The text package is the only one that looks inside.
Font :: distinct rawptr

Align :: enum u8 {
	Left,
	Center,
	Right,
}

Quad_Kind :: enum u32 {
	Rect       = 0, // solid color; uv.x = corner radius in px
	Gray_Glyph = 1, // coverage from the gray atlas, tinted with the color
	Color_Glyph = 2, // premultiplied BGRA from the color atlas
}

// What the renderer draws: one instance for each rectangle or glyph.
// Positions are device pixels, relative to the origin of the display list.
// The layout of this struct is the same as `Instance` in the shaders.
Quad :: struct #packed {
	pos:    [2]f32,
	size:   [2]f32,
	uv:     [2]f32, // glyphs: atlas origin in px
	uvsize: [2]f32,
	color:  Color,
	kind:   Quad_Kind,
}

// The reader style that the host gives the core. It mirrors `mdcore_style`
// in include/mdcore.h field by field.
Style :: struct {
	body_font:       Font,
	bold_font:       Font,
	heading_font:    Font,
	code_font:       Font,
	body_size:       f64, // points
	line_height:     f64, // multiple of the body size
	column_width:    f64, // points; 0 = the full width of the view
	page_padding:    f64, // points, left and right
	text:            Color,
	secondary:       Color,
	link:            Color,
	code_background: Color,
	code_border:     Color,
	rule:            Color,
	quote_bar:       Color,
	selection:       Color,
}

// Sizes that follow the body size, as in the app's reader style sheet.
Metrics :: struct {
	body:         f32,
	line_height:  f32, // multiple
	column:       f32, // 0 = full width
	page_pad:     f32,
	paragraph:    f32, // space above a paragraph
	list_item:    f32, // space above a list item
	list_indent:  f32,
	quote_indent: f32,
	large_block:  f32, // space above a table
	code_size:    f32,
}

metrics :: proc(style: Style) -> Metrics {
	body := f32(style.body_size)
	return Metrics {
		body = body,
		line_height = f32(style.line_height),
		column = f32(style.column_width),
		page_pad = f32(style.page_padding),
		paragraph = body * 0.8,
		list_item = body * 0.2,
		list_indent = body * 2.1,
		quote_indent = body * 1.5,
		large_block = body * 1.6,
		code_size = body * 0.9,
	}
}
