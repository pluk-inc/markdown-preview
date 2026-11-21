// The Markdown core: it parses a document, lays it out, and draws it.
// cmark-gfm parses, CoreText shapes the text and breaks the lines, glyphs go
// into a texture atlas, and Metal draws one quad per glyph. The host app
// owns the view and its CAMetalLayer and calls the C API in include/mdcore.h.
package mdcore

import "base:runtime"
import "core:c"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"
import MTL "vendor:darwin/Metal"
import CA "vendor:darwin/QuartzCore"

Instance :: struct #packed {
	pos:    [2]f32,
	size:   [2]f32,
	uv:     [2]f32,
	uvsize: [2]f32,
	color:  Color,
	kind:   u32,
}

Span_Flag :: enum {
	Code_Bg,
}

Span :: struct {
	start, end: int, // UTF-16 offsets in the attributed string
	color:      Color,
	flags:      bit_set[Span_Flag],
}

Text :: struct {
	astr:        CF.MutableAttributedStringRef,
	len:         int,
	spans:       [dynamic]Span,
	size:        f32,
	line_height: f32,
}

Block_Kind :: enum {
	Text,
	Code,
	Rule,
	Table,
}

Align :: enum {
	Left,
	Center,
	Right,
}

Block :: struct {
	kind:         Block_Kind,
	text:         Text,
	marker:       Text, // list bullet or number; empty for other blocks
	indent:       f32,
	quote_depth:  int,
	space_before: f32,
	cells:        [dynamic]Text, // table: row-major
	ncols:        int,
	aligns:       [dynamic]Align,
}

Run_Font :: struct {
	font:     CT.FontRef,
	is_color: bool,
}

Ctx :: struct {
	// document
	source:         []u8, // kept to parse again after a style change
	blocks:         [dynamic]Block,
	// style
	style:          Style,
	m:              Metrics,
	style_fonts:    [dynamic]Style_Font,
	// layout output
	rects:          [dynamic]Instance,
	glyphs:         [dynamic]Instance,
	content_height: f32,
	width, height:  f32, // points
	scale:          f32,
	laid_out_width: f32,
	laid_out_scale: f32,
	// glyph cache
	run_fonts:      [dynamic]Run_Font,
	cache:          map[Glyph_Key]Glyph_Entry,
	gray:           Atlas,
	colr:           Atlas,
	scratch_gray:   CG.ContextRef,
	scratch_colr:   CG.ContextRef,
	scratch_scale:  f32,
	// gpu
	layer:          ^CA.MetalLayer,
	gray_tex:       ^MTL.Texture,
	colr_tex:       ^MTL.Texture,
	rect_quads:     Gpu_Quads,
	glyph_quads:    Gpu_Quads,
	selection_quads: Gpu_Quads,
	// layout progress
	lay_next:       int,
	lay_y:          f32,
	scroll:         f32,
	// selection
	lines:          [dynamic]Line_Rec,
	text_order:     int,
	has_sel:        bool,
	sel_anchor:     Sel_Pos,
	sel_focus:      Sel_Pos,
	sel_rects:      [dynamic]Instance,
	clip:           [dynamic]u8,
	// scratch arrays for runs
	tmp_glyphs:     [dynamic]CG.Glyph,
	tmp_pos:        [dynamic]CG.Point,
	tmp_idx:        [dynamic]CF.Index,
}

@(private)
runtime_started: bool

@(export)
mdcore_create :: proc "c" (metal_layer: rawptr) -> rawptr {
	context = runtime.default_context()
	if !runtime_started {
		runtime._startup_runtime()
		runtime_started = true
	}
	ctx := new(Ctx)
	ctx.scale = 2
	ctx.style = style_default()
	metrics_update(ctx)
	gpu_init(ctx, cast(^CA.MetalLayer)metal_layer)
	return ctx
}

@(export)
mdcore_set_markdown :: proc "c" (handle: rawptr, utf8: [^]u8, length: c.long) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	ctx.has_sel = false
	source_set(ctx, string(utf8[:length]))
	reparse(ctx)
}

// Sets the view size in points and the backing scale. Lays the document out
// again when the width or the scale changed.
@(export)
mdcore_resize :: proc "c" (handle: rawptr, width, height, scale: f64) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	ctx.width, ctx.height, ctx.scale = f32(width), f32(height), f32(scale)
	gpu_resize(ctx)
	if ctx.laid_out_width != ctx.width || ctx.laid_out_scale != ctx.scale {
		// Only what the view shows now; mdcore_layout_more does the rest.
		layout_begin(ctx)
		layout_some(ctx, ctx.scroll + ctx.height * 2)
		gpu_upload(ctx)
		update_selection(ctx)
		ctx.laid_out_width, ctx.laid_out_scale = ctx.width, ctx.scale
	}
}

// Continues the layout for about `budget_ms`. Returns true while blocks are
// left; the host calls it again from the run loop.
@(export)
mdcore_layout_more :: proc "c" (handle: rawptr, budget_ms: f64) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	if layout_done(ctx) {
		return false
	}
	layout_some(ctx, 1e30, budget_ms)
	gpu_upload(ctx)
	update_selection(ctx)
	return !layout_done(ctx)
}

@(export)
mdcore_content_height :: proc "c" (handle: rawptr) -> f64 {
	return f64((cast(^Ctx)handle).content_height)
}

@(export)
mdcore_draw :: proc "c" (handle: rawptr, scroll_y: f64) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	ctx.scroll = f32(scroll_y)
	gpu_draw(ctx)
}

// Frees the renderer and all it owns. The layer stays with the host.
@(export)
mdcore_destroy :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	free_lines(ctx)
	free_blocks(ctx)
	atlas_destroy(ctx)
	gpu_destroy(ctx)
	style_destroy(ctx)
	delete(ctx.source)
	delete(ctx.blocks)
	delete(ctx.rects)
	delete(ctx.glyphs)
	delete(ctx.lines)
	delete(ctx.sel_rects)
	delete(ctx.clip)
	delete(ctx.tmp_glyphs)
	delete(ctx.tmp_pos)
	delete(ctx.tmp_idx)
	free(ctx)
}

free_text :: proc(t: ^Text) {
	if t.astr != nil {
		CF.Release(CF.TypeRef(t.astr))
	}
	delete(t.spans)
	t^ = {}
}

free_blocks :: proc(ctx: ^Ctx) {
	for &b in ctx.blocks {
		free_text(&b.text)
		free_text(&b.marker)
		for &cell in b.cells {
			free_text(&cell)
		}
		delete(b.cells)
		delete(b.aligns)
	}
	clear(&ctx.blocks)
}
