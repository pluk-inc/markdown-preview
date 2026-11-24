// The Markdown core: it parses a document, lays it out, and draws it. This
// file is the C API in include/mdcore.h and nothing else: it holds the state
// of one view and passes the work to the packages.
//
//   document/   the parser and the document model
//   text/       fonts, line breaking, and glyph bitmaps (CoreText)
//   layout/     the place of every block, line, and decoration; the display
//               list and the selection for the visible part
//   renderer/   draws the display list on the GPU (Metal)
//   base/       the types they share
//
// The host app owns the view, the scroll position, and the input events.
package mdcore

import "base"
import "base:runtime"
import "core:c"
import "core:sync"
import "document"
import "layout"
import "renderer"
import "text"

// How much of the page has quads on the GPU, in view heights around the
// scroll position.
SHOWN_ABOVE :: 2
SHOWN_BELOW :: 3
// Shaped text is kept for this many view heights around the scroll
// position: the shown part, and how far the view moves in it before the
// quads are made again.
KEPT_ABOVE :: SHOWN_ABOVE + 2
KEPT_BELOW :: SHOWN_BELOW + 2
// How near to the edge of the shown part the view may come, in view
// heights, before the quads are made again.
SHOWN_MARGIN :: 0.5

Ctx :: struct {
	// One call at a time works on the state. The host can call from its
	// main thread and from a thread that draws.
	lock:            sync.Mutex,
	// Held for all of a draw, which gives `lock` free before it waits for
	// the display. A call that the frame in progress cannot live with (a
	// new size, the end of the view) takes it first.
	draw_lock:       sync.Mutex,
	// Working memory of one call. The context's own is one for each
	// thread, and the threads of a host's queue come and go.
	scratch:         runtime.Default_Temp_Allocator,
	temp:            runtime.Allocator,
	doc:             document.Document,
	style:           base.Style,
	page:            layout.Layout,
	cache:           text.Glyph_Cache,
	gpu:             renderer.Renderer,
	selection:       layout.Selection,
	// The view.
	width, height:   f32, // points
	scale:           f32,
	scroll:          f32, // points
	layout_valid:    bool,
	// The display list: the quads of the page between shown_y0 and shown_y1.
	display_valid:   bool,
	shown_y0:        f32, // points
	shown_y1:        f32,
	origin_px:       f32, // device pixels; the y that the quads count from
	rects:           [dynamic]base.Quad,
	glyphs:          [dynamic]base.Quad,
	selection_quads: [dynamic]base.Quad,
	glyph_buffer:    text.Glyph_Buffer,
	clipboard:       [dynamic]u8,
}

@(private)
runtime_started: bool

// The style of a view whose host did not set one: the system fonts and the
// light palette of the app.
@(private)
default_style :: proc() -> base.Style {
	return base.Style {
		body_font = text.font_system(.Regular, 15),
		bold_font = text.font_system(.Bold, 15),
		heading_font = text.font_system(.Semibold, 15),
		code_font = text.font_system(.Mono, 15),
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

@(private)
style_release :: proc(style: ^base.Style) {
	for font in ([4]base.Font{style.body_font, style.bold_font, style.heading_font, style.code_font}) {
		text.font_release(font)
	}
}

// Makes the quads of the part of the page around the scroll position and
// gives them to the renderer.
@(private)
show :: proc(ctx: ^Ctx) {
	ctx.shown_y0 = max(ctx.scroll - SHOWN_ABOVE * ctx.height, 0)
	ctx.shown_y1 = ctx.scroll + SHOWN_BELOW * ctx.height
	ctx.origin_px = f32(int(ctx.shown_y0 * ctx.scale))
	clear(&ctx.rects)
	clear(&ctx.glyphs)
	layout.display(&ctx.page, &ctx.cache, ctx.shown_y0, ctx.shown_y1, ctx.origin_px, &ctx.rects, &ctx.glyphs, &ctx.glyph_buffer)
	renderer.set_display(&ctx.gpu, ctx.rects[:], ctx.glyphs[:])
	show_selection(ctx)
	ctx.display_valid = true
}

// The lines around the scroll position keep their shaped text. The window
// covers the part that has quads wherever the view is in it, so a drag of
// the selection there shapes nothing again.
@(private)
keep_window :: proc(ctx: ^Ctx) {
	layout.keep(&ctx.page, ctx.scroll - KEPT_ABOVE * ctx.height, ctx.scroll + KEPT_BELOW * ctx.height)
}

@(private)
show_selection :: proc(ctx: ^Ctx) {
	clear(&ctx.selection_quads)
	layout.selection_quads(&ctx.page, ctx.selection, ctx.shown_y0, ctx.shown_y1, ctx.scale, ctx.origin_px, &ctx.selection_quads)
	renderer.set_selection(&ctx.gpu, ctx.selection_quads[:])
}

// True when the view came near the edge of the part that has quads.
@(private)
left_shown_part :: proc(ctx: ^Ctx) -> bool {
	margin := SHOWN_MARGIN * ctx.height
	return (ctx.shown_y0 > 0 && ctx.scroll - margin < ctx.shown_y0) || ctx.scroll + ctx.height + margin > ctx.shown_y1
}

@(export)
mdcore_create :: proc "c" (surface: rawptr) -> rawptr {
	context = runtime.default_context()
	if !runtime_started {
		runtime._startup_runtime()
		runtime_started = true
	}
	ctx := new(Ctx)
	runtime.default_temp_allocator_init(&ctx.scratch, 64 * 1024, context.allocator)
	ctx.temp = runtime.default_temp_allocator(&ctx.scratch)
	ctx.scale = 2
	ctx.style = default_style()
	renderer.init(&ctx.gpu, surface)
	return ctx
}

// Takes the view's state for one call and gives it back at the end of the
// caller's scope, with the working memory of the call freed.
@(private, deferred_in = release)
hold :: proc(ctx: ^Ctx) {
	sync.lock(&ctx.lock)
}

@(private)
release :: proc(ctx: ^Ctx) {
	free_all(ctx.temp)
	sync.unlock(&ctx.lock)
}

// Frees the view's state. The surface stays with the host.
@(export)
mdcore_destroy :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	if ctx == nil {
		return
	}
	// After the frame and the call in progress. The locks go with the state.
	sync.lock(&ctx.draw_lock)
	sync.lock(&ctx.lock)
	layout.destroy(&ctx.page)
	document.destroy(&ctx.doc)
	text.cache_destroy(&ctx.cache)
	renderer.destroy(&ctx.gpu)
	style_release(&ctx.style)
	delete(ctx.rects)
	delete(ctx.glyphs)
	delete(ctx.selection_quads)
	text.glyph_buffer_destroy(&ctx.glyph_buffer)
	delete(ctx.clipboard)
	runtime.default_temp_allocator_destroy(&ctx.scratch)
	free(ctx)
}

// Takes a new style. The host calls mdcore_resize after it.
@(export)
mdcore_set_style :: proc "c" (handle: rawptr, style: ^base.Style) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	fresh := style^
	// A font the host left out falls back on another one.
	if fresh.body_font == nil {
		fresh.body_font = text.font_system(.Regular, 15)
	} else {
		text.font_retain(fresh.body_font)
	}
	if fresh.code_font == nil {
		fresh.code_font = text.font_system(.Mono, 15)
	} else {
		text.font_retain(fresh.code_font)
	}
	fresh.bold_font = text.font_retain(fresh.bold_font != nil ? fresh.bold_font : fresh.body_font)
	fresh.heading_font = text.font_retain(fresh.heading_font != nil ? fresh.heading_font : fresh.bold_font)
	// The layout holds fonts of the old style.
	layout.begin(&ctx.page, nil, fresh, 0)
	style_release(&ctx.style)
	ctx.style = fresh
	ctx.layout_valid = false
}

// Replaces the document. The host calls mdcore_resize after it.
@(export)
mdcore_set_markdown :: proc "c" (handle: rawptr, utf8: [^]u8, length: c.long) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	// The layout points into the old document.
	layout.begin(&ctx.page, nil, ctx.style, 0)
	document.destroy(&ctx.doc)
	ctx.doc = document.parse(length > 0 ? string(utf8[:length]) : "")
	ctx.selection = {}
	// A new document starts at its top, so the first layout does not go
	// down to the place the old one was scrolled to. A host that keeps the
	// reader's place (the same file with a change) pays for the layout down
	// to that place in its first draw.
	ctx.scroll = 0
	ctx.layout_valid = false
}

// Sets the view size in points and the backing scale. Lays out what the
// view shows now when the document, the style, or the width changed.
@(export)
mdcore_resize :: proc "c" (handle: rawptr, width, height, scale: f64) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// Not in the middle of a frame, which has the old size.
	sync.lock(&ctx.draw_lock)
	defer sync.unlock(&ctx.draw_lock)
	hold(ctx)
	if f32(scale) != ctx.cache.scale {
		// Every glyph bitmap has the old size.
		text.cache_set_scale(&ctx.cache, f32(scale))
		ctx.display_valid = false
	}
	if !ctx.layout_valid || f32(width) != ctx.width {
		ctx.width = f32(width)
		layout.begin(&ctx.page, &ctx.doc, ctx.style, ctx.width)
		ctx.layout_valid = true
		ctx.display_valid = false
	}
	ctx.height, ctx.scale = f32(height), f32(scale)
	keep_window(ctx)
	renderer.resize(&ctx.gpu, ctx.width, ctx.height, ctx.scale)
	// Only what the view shows now; mdcore_layout_more does the rest.
	if layout.step(&ctx.page, ctx.scroll + 2 * ctx.height) {
		ctx.display_valid = false
	}
}

// Continues the layout for about `budget_ms`. Returns true while blocks are
// left; the host calls it again from the run loop.
@(export)
mdcore_layout_more :: proc "c" (handle: rawptr, budget_ms: f64) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if !ctx.layout_valid || layout.done(&ctx.page) {
		return false
	}
	reached := ctx.page.y
	layout.step(&ctx.page, 1e30, budget_ms)
	if reached < ctx.shown_y1 {
		ctx.display_valid = false // the new blocks are in the shown part
	}
	return !layout.done(&ctx.page)
}

@(export)
mdcore_content_height :: proc "c" (handle: rawptr) -> f64 {
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.lock)
	defer sync.unlock(&ctx.lock)
	return f64(ctx.page.content_height)
}

@(export)
mdcore_draw :: proc "c" (handle: rawptr, scroll_y: f64) {
	context = runtime.default_context()
	draw(handle, scroll_y, false)
}

@(export)
mdcore_draw_with_window :: proc "c" (handle: rawptr, scroll_y: f64) {
	context = runtime.default_context()
	draw(handle, scroll_y, true)
}

@(private)
draw :: proc(handle: rawptr, scroll_y: f64, with_window: bool) {
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	sync.lock(&ctx.draw_lock)
	defer sync.unlock(&ctx.draw_lock)
	frame: renderer.Frame
	{
		hold(ctx)
		if !ctx.layout_valid {
			return
		}
		ctx.scroll = f32(scroll_y)
		keep_window(ctx)
		// The view can scroll past what the steps laid out so far.
		if layout.step(&ctx.page, ctx.scroll + 2 * ctx.height) {
			ctx.display_valid = false
		}
		if !ctx.display_valid || left_shown_part(ctx) {
			show(ctx)
		}
		renderer.sync_atlases(&ctx.gpu, &ctx.cache)
		frame = renderer.frame_begin(&ctx.gpu, f32(int(ctx.scroll * ctx.scale)) - ctx.origin_px)
	}
	// The frame can wait for the display. Other calls go on meanwhile, but
	// no other frame: the draw lock is held to its end.
	renderer.frame_draw(&frame, with_window)
}

Host_Task :: struct {
	x, y, size: f64,
	line:       c.long,
	checked:    bool,
}

@(export)
mdcore_tasks :: proc "c" (handle: rawptr, top, bottom: f64, out: [^]Host_Task, capacity: c.long) -> c.long {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	tasks := layout.tasks_between(&ctx.page, f32(top), f32(bottom))
	size := f64(layout.task_box_size(ctx.page.m))
	for t, i in tasks[:min(len(tasks), int(capacity))] {
		b := ctx.doc.blocks[t.block]
		out[i] = {f64(t.x), f64(t.y), size, c.long(b.task_line), b.marker == .Task_Done}
	}
	return c.long(len(tasks))
}

@(export)
mdcore_set_task_checked :: proc "c" (handle: rawptr, line: c.long, checked: bool) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if !document.set_task_done(&ctx.doc, int(line), checked) {
		return false
	}
	// The places are the same; only the color of the item's text changes.
	ctx.display_valid = false
	return true
}

// phase 0 = mouse down, 1 = drag. x and y are points in document space.
@(export)
mdcore_mouse :: proc "c" (handle: rawptr, x, y: f64, phase: c.int) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	pos, ok := layout.hit_test(&ctx.page, f32(x), f32(y))
	if !ok {
		return
	}
	if phase == 0 {
		ctx.selection.anchor = pos
	}
	ctx.selection.focus = pos
	ctx.selection.active = true
	show_selection(ctx)
}

@(export)
mdcore_select_all :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	// All of the document, not only the part that is laid out so far.
	layout.step(&ctx.page, 1e30)
	ctx.selection = layout.select_all(&ctx.page)
	ctx.display_valid = false
}

// The selected text as UTF-8. The pointer is valid until the next call.
@(export)
mdcore_selection_text :: proc "c" (handle: rawptr, length: ^c.long) -> [^]u8 {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	clear(&ctx.clipboard)
	layout.selection_text(&ctx.page, ctx.selection, &ctx.clipboard)
	length^ = c.long(len(ctx.clipboard))
	return raw_data(ctx.clipboard)
}
