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
import "core:math"
import "core:sync"
import "document"
import "layout"
import "renderer"
import "text"

// How much of the page has quads on the GPU, in view heights around the
// scroll position.
SHOWN_ABOVE :: 2
SHOWN_BELOW :: 3
// A frame needs the records of what the view shows and half a view more
// on each side, so a part does not get its real height in the view. When
// some of that has none, it lays out more than it needs: the next frames
// of a scroll then find theirs, and a scroll lays out a few times for
// each view height, not for each frame.
LAID_ABOVE :: 1
LAID_BELOW :: 2.5
// The same margin as for the quads: the view, and that much more.
NEEDED_ABOVE :: LAID_ABOVE - SHOWN_MARGIN
NEEDED_BELOW :: LAID_BELOW - 1 - SHOWN_MARGIN
// How much of the end of the document `mdcore_layout_end` lays out, in
// view heights: the last view, and what a frame lays out above it.
LAID_AT_END :: 1 + LAID_ABOVE
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
	page_width:      f32, // the part of the width that the page is laid out in; 0 for all of it
	layout_width:    f32, // the width of the layout that is there now
	scale:           f32,
	scroll:          f64, // points
	layout_valid:    bool,
	revision:        int, // goes up when the layout gave a place or a height to something
	// The display list: the quads of the page between shown_y0 and shown_y1.
	display_valid:   bool,
	shown_y0:        f64, // points
	shown_y1:        f64,
	origin_px:       f64, // device pixels; the y that the quads count from
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
	height := f64(ctx.height)
	ctx.shown_y0 = max(ctx.scroll - SHOWN_ABOVE * height, ctx.page.origin)
	ctx.shown_y1 = ctx.scroll + SHOWN_BELOW * height
	ctx.origin_px = math.floor(ctx.shown_y0 * f64(ctx.scale))
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
	height := f64(ctx.height)
	layout.keep(&ctx.page, ctx.scroll - KEPT_ABOVE * height, ctx.scroll + KEPT_BELOW * height)
}

@(private)
show_selection :: proc(ctx: ^Ctx) {
	clear(&ctx.selection_quads)
	layout.selection_quads(&ctx.page, ctx.selection, ctx.shown_y0, ctx.shown_y1, ctx.scale, ctx.origin_px, &ctx.selection_quads)
	renderer.set_selection(&ctx.gpu, ctx.selection_quads[:])
}

// After the layout gave something a place or a height: the quads are of
// the layout before it, and so is what the host has from it.
@(private)
layout_changed :: proc(ctx: ^Ctx) {
	ctx.display_valid = false
	ctx.revision += 1
}

// True when the view came near the edge of the part that has quads.
@(private)
left_shown_part :: proc(ctx: ^Ctx) -> bool {
	height := f64(ctx.height)
	margin := SHOWN_MARGIN * height
	return (ctx.shown_y0 > ctx.page.origin && ctx.scroll - margin < ctx.shown_y0) || ctx.scroll + height + margin > ctx.shown_y1
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
	// A new document starts at its top. A host that keeps the reader's
	// offset (the same file with a change) draws at that offset again. A
	// place of the old document is no address in the new one.
	ctx.scroll = 0
	ctx.layout_valid = false
}

// See the header.
@(export)
mdcore_set_page_width :: proc "c" (handle: rawptr, width: f64) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	ctx.page_width = f32(max(width, 0))
}

// Sets the view size in points and the backing scale. Starts a new
// layout when the document, the style, or the width changed.
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
	ctx.width = f32(width)
	page_width := layout.page_width(ctx.width, ctx.page_width)
	if !ctx.layout_valid || page_width != ctx.layout_width {
		ctx.layout_width = page_width
		layout.begin(&ctx.page, &ctx.doc, ctx.style, page_width)
		ctx.layout_valid = true
		layout_changed(ctx)
	}
	ctx.height, ctx.scale = f32(height), f32(scale)
	keep_window(ctx)
	renderer.resize(&ctx.gpu, ctx.width, ctx.height, ctx.scale, page_width)
	// No layout here: the next frame lays out what it shows, where the
	// host draws it (a place can be at another height in a new layout).
}

@(export)
mdcore_layout_revision :: proc "c" (handle: rawptr) -> c.long {
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.lock)
	defer sync.unlock(&ctx.lock)
	return c.long(ctx.revision)
}

// See the header.
@(export)
mdcore_layout_end :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if !ctx.layout_valid {
		return
	}
	if layout.lay_out_end(&ctx.page, LAID_AT_END * f64(ctx.height), ctx.scroll) {
		layout_changed(ctx)
	}
}

// See the header.
@(export)
mdcore_page_area :: proc "c" (handle: rawptr, top, height: ^f64) -> c.long {
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.lock)
	defer sync.unlock(&ctx.lock)
	top^, height^ = ctx.page.origin, ctx.page.content_height
	return c.long(ctx.revision)
}

@(export)
mdcore_draw :: proc "c" (handle: rawptr, scroll_y: f64) {
	context = runtime.default_context()
	draw(handle, scroll_y, scroll_y, false)
}

@(export)
mdcore_draw_toward :: proc "c" (handle: rawptr, scroll_y, target_y: f64) {
	context = runtime.default_context()
	draw(handle, scroll_y, target_y, false)
}

@(export)
mdcore_draw_with_window :: proc "c" (handle: rawptr, scroll_y: f64) {
	context = runtime.default_context()
	draw(handle, scroll_y, scroll_y, true)
}

// `anchor_y`: the height of the page whose text stays where it is when
// this frame lays out a part.
@(private)
draw :: proc(handle: rawptr, scroll_y, anchor_y: f64, with_window: bool) {
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
		ctx.scroll = scroll_y
		keep_window(ctx)
		// What this frame shows must have its records.
		height := f64(ctx.height)
		if !layout.laid_out(&ctx.page, ctx.scroll - NEEDED_ABOVE * height, ctx.scroll + NEEDED_BELOW * height) &&
		   layout.lay_out(&ctx.page, ctx.scroll - LAID_ABOVE * height, ctx.scroll + LAID_BELOW * height, anchor_y) {
			layout_changed(ctx)
		}
		if !ctx.display_valid || left_shown_part(ctx) {
			show(ctx)
		}
		renderer.sync_atlases(&ctx.gpu, &ctx.cache)
		frame = renderer.frame_begin(&ctx.gpu, f32(math.floor(ctx.scroll * f64(ctx.scale)) - ctx.origin_px))
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
	tasks := make([]layout.Task_Place, max(int(capacity), 0), context.temp_allocator)
	count := layout.tasks_between(&ctx.page, top, bottom, tasks)
	size := f64(layout.task_box_size(ctx.page.m))
	for t, i in tasks[:min(count, len(tasks))] {
		out[i] = {f64(t.x), t.y, size, c.long(t.block.task_line), t.block.marker == .Task_Done}
	}
	return c.long(count)
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

Host_Place :: struct {
	block, cell, byte: c.long,
	fraction:          f64,
}

@(export)
mdcore_place_at :: proc "c" (handle: rawptr, y: f64, out: ^Host_Place) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if !ctx.layout_valid {
		return false
	}
	place := layout.place_at(&ctx.page, y) or_return
	out^ = {c.long(place.block), c.long(place.cell), c.long(place.byte), f64(place.fraction)}
	return true
}

@(export)
mdcore_place_y :: proc "c" (handle: rawptr, place: ^Host_Place, y: ^f64) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if !ctx.layout_valid {
		return false
	}
	wanted := layout.Place{int(place.block), int(place.cell), int(place.byte), f32(place.fraction)}
	// Only the part of the place, not the parts above it.
	if layout.lay_out_block(&ctx.page, wanted.block) {
		layout_changed(ctx)
	}
	y^ = layout.place_y(&ctx.page, wanted) or_return
	return true
}

// The shape of the pointer over a place of the page. The core decides
// it, because it knows what is there; the host only shows it. A link
// that opens will add a shape here.
Pointer_Shape :: enum c.int {
	Default = 0,
	Text    = 1,
	Busy    = 2, // not known now: another call works on the view
}

// The one export that does not wait for the view's state (`hold`): the
// host asks on its main thread for each move of the pointer and each step
// of a scroll, and a layout call or a frame can have the state for some
// milliseconds. It reads only, and uses no working memory.
@(export)
mdcore_pointer_shape :: proc "c" (handle: rawptr, x, y: f64) -> Pointer_Shape {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	if !sync.try_lock(&ctx.lock) {
		return .Busy
	}
	defer sync.unlock(&ctx.lock)
	if ctx.layout_valid && layout.text_at(&ctx.page, f32(x), y) {
		return .Text
	}
	return .Default
}

// phase 0 = mouse down, 1 = drag. x and y are points in document space.
@(export)
mdcore_mouse :: proc "c" (handle: rawptr, x, y: f64, phase: c.int) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	pos, ok := layout.hit_test(&ctx.page, f32(x), y)
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
	// The text that the view shows stays where it is.
	changed: bool
	ctx.selection, changed = layout.select_all(&ctx.page, ctx.scroll)
	if changed {
		layout_changed(ctx)
	}
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
	if from, to, ok := layout.selection_range(ctx.selection); ok && ctx.layout_valid {
		// The text comes from the records of its blocks.
		if layout.lay_out_blocks(&ctx.page, from.block, to.block, ctx.scroll) {
			layout_changed(ctx)
		}
		layout.selection_text(&ctx.page, ctx.selection, &ctx.clipboard)
	}
	length^ = c.long(len(ctx.clipboard))
	return raw_data(ctx.clipboard)
}
