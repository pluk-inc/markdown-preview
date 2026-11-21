package mdcore

import "base:runtime"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import CT "core:sys/darwin/CoreText"

Color :: [4]u8

// The reader style that the host app gives the core. It mirrors
// `mdcore_style` in include/mdcore.h field by field.
Style :: struct {
	// CTFont objects at any size; the core makes the sizes it needs.
	body_font:       CT.FontRef,
	bold_font:       CT.FontRef,
	heading_font:    CT.FontRef,
	code_font:       CT.FontRef,
	body_size:       f64, // points
	line_height:     f64, // multiple of the body size
	column_width:    f64, // points; 0 = the full width of the view
	page_padding:    f64, // points, left and right
	// r, g, b, a; not premultiplied
	text:            Color,
	secondary:       Color,
	link:            Color,
	code_background: Color,
	code_border:     Color,
	rule:            Color,
	quote_bar:       Color,
	selection:       Color,
}

HEADING_LINE_HEIGHT :: 1.25
CODE_PAD :: 16.0

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

metrics_update :: proc(ctx: ^Ctx) {
	body := f32(ctx.style.body_size)
	ctx.m = Metrics {
		body         = body,
		line_height  = f32(ctx.style.line_height),
		column       = f32(ctx.style.column_width),
		page_pad     = f32(ctx.style.page_padding),
		paragraph    = body * 0.8,
		list_item    = body * 0.2,
		list_indent  = body * 2.1,
		quote_indent = body * 1.5,
		large_block  = body * 1.6,
		code_size    = body * 0.9,
	}
}

@(private = "file")
font_named :: proc(name: cstring, size: f64) -> CT.FontRef {
	cf_name := CF.StringCreateWithCString(nil, name, UTF8)
	defer CF.Release(CF.TypeRef(cf_name))
	return CT.FontCreateWithName(cf_name, size, nil)
}

// The style of a renderer whose host did not set one: the system fonts and
// the light palette of the app.
style_default :: proc() -> Style {
	return Style {
		body_font = CT.FontCreateUIFontForLanguage(.System, 15, nil),
		bold_font = CT.FontCreateUIFontForLanguage(.EmphasizedSystem, 15, nil),
		heading_font = font_named(".AppleSystemUIFontDemi", 15),
		code_font = font_named(".AppleSystemUIFontMonospaced-Regular", 15),
		body_size = 15,
		line_height = 1.6,
		column_width = 820,
		page_padding = 40,
		text = {0, 0, 0, 255},
		secondary = {0x6e, 0x6e, 0x73, 255},
		link = {0, 104, 218, 255},
		code_background = {0xf9, 0xf9, 0xf9, 255},
		code_border = {0xf0, 0xf0, 0xf0, 255},
		rule = {0xdd, 0xdd, 0xe0, 255},
		quote_bar = {0xdd, 0xdd, 0xe0, 255},
		selection = {0xb3, 0xd7, 0xff, 255},
	}
}

@(private = "file")
style_fonts_release :: proc(s: ^Style) {
	for font in ([4]CT.FontRef{s.body_font, s.bold_font, s.heading_font, s.code_font}) {
		if font != nil {
			CF.Release(CF.TypeRef(font))
		}
	}
}

style_destroy :: proc(ctx: ^Ctx) {
	style_fonts_release(&ctx.style)
	for f in ctx.style_fonts {
		CF.Release(CF.TypeRef(f.font))
	}
	delete(ctx.style_fonts)
}

// Takes a new style and parses the document again, because the fonts and the
// colors are part of the parsed blocks. The host calls mdcore_resize after it.
style_set :: proc(ctx: ^Ctx, style: Style) {
	style_fonts_release(&ctx.style)
	ctx.style = style
	s := &ctx.style
	for font in ([4]^CT.FontRef{&s.body_font, &s.bold_font, &s.heading_font, &s.code_font}) {
		if font^ != nil {
			CF.Retain(CF.TypeRef(font^))
		}
	}
	// A font the host left out falls back on another one.
	fallback := style_default()
	defer style_fonts_release(&fallback)
	if s.body_font == nil {
		s.body_font = CT.FontRef(CF.Retain(CF.TypeRef(fallback.body_font)))
	}
	if s.code_font == nil {
		s.code_font = CT.FontRef(CF.Retain(CF.TypeRef(fallback.code_font)))
	}
	if s.bold_font == nil {
		s.bold_font = CT.FontRef(CF.Retain(CF.TypeRef(s.body_font)))
	}
	if s.heading_font == nil {
		s.heading_font = CT.FontRef(CF.Retain(CF.TypeRef(s.bold_font)))
	}
	for f in ctx.style_fonts {
		CF.Release(CF.TypeRef(f.font))
	}
	clear(&ctx.style_fonts)
	metrics_update(ctx)
	reparse(ctx)
}

Font_Kind :: enum {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
	Semibold,
	Mono,
}

Style_Font :: struct {
	kind: Font_Kind,
	size: f32,
	font: CT.FontRef,
}

// The font of one kind at one size, made once.
style_font :: proc(ctx: ^Ctx, kind: Font_Kind, size: f32) -> CT.FontRef {
	for f in ctx.style_fonts {
		if f.kind == kind && f.size == size {
			return f.font
		}
	}
	base: CT.FontRef
	switch kind {
	case .Regular, .Italic:
		base = ctx.style.body_font
	case .Bold, .Bold_Italic:
		base = ctx.style.bold_font
	case .Semibold:
		base = ctx.style.heading_font
	case .Mono:
		base = ctx.style.code_font
	}
	font := CT.FontCreateCopyWithAttributes(base, f64(size), nil, nil)
	if kind == .Italic || kind == .Bold_Italic {
		// Nil for a face that has no italic; the upright face stays.
		if italic := CT.FontCreateCopyWithSymbolicTraits(font, f64(size), nil, {.Italic}, {.Italic}); italic != nil {
			CF.Release(CF.TypeRef(font))
			font = italic
		}
	}
	append(&ctx.style_fonts, Style_Font{kind, size, font})
	return font
}

// Parses the kept source again, after a style change.
reparse :: proc(ctx: ^Ctx) {
	free_lines(ctx)
	free_blocks(ctx)
	parse_document(ctx, string(ctx.source))
	ctx.laid_out_width = 0
}

@(export)
mdcore_set_style :: proc "c" (handle: rawptr, style: ^Style) {
	context = runtime.default_context()
	style_set(cast(^Ctx)handle, style^)
}

source_set :: proc(ctx: ^Ctx, text: string) {
	delete(ctx.source)
	ctx.source = transmute([]u8)strings.clone(text)
}
