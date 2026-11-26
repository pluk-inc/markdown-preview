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
import "core:strings"
import "core:sync"
import "core:time"
import "document"
import "history"
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
	selection:       document.Selection,
	// The caret of an editor: where text that is typed goes. An offset
	// in the source of the document, because that is what an edit
	// changes; -1 for no caret. `caret_at` is the address in the text of
	// a block that the offset is at now, for the place on the page.
	caret:           int,
	caret_at:        document.Address,
	// Where the text of the block of the caret is in the source
	// (`document.block_map`), for the next key. Of the document as it
	// is: each change makes it again.
	caret_places:    [dynamic]document.Place,
	// The marks of the styles of that block, for an edit that takes
	// text out of it (`document.replace_range`), and for the marks that
	// show at the caret.
	caret_pairs:     [dynamic]document.Pair,
	// The marks at the caret show as text (`document.Document.reveal`,
	// `reveal_update`), but not while the view does not take the keys.
	unfocused:       bool,
	// Where a selection that the keys make started, as an offset of the
	// source: with marks that show, some offsets are one place of the
	// text with no marks, and the caret comes back to the one that it
	// had when the selection is empty again.
	select_from:     Maybe(int),
	// Where the button of the pointer went down, and if the pointer
	// went away from there since: a click is no drag. The text under
	// the pointer can be another one after the click (marks that show
	// at the caret move the text of its line), so the button that comes
	// up at the same point selects nothing.
	mouse_down:      [2]f64,
	mouse_dragged:   bool,
	// The bytes of the source that the last delete took out
	// (`mdcore_deleted_text`).
	gone:            [dynamic]u8,
	// The changes that the reader made, for Undo and Redo. Under
	// `source_lock`.
	history:         history.History,
	// A change of Undo or Redo is in progress: it is no new step.
	replaying:       bool,
	caret_hidden:    bool, // the off half of a blink; the caret is there
	// A byte where a line of a paragraph ends and the next one starts
	// is two places on the page. The caret is at the end of the first
	// line with this, and at the start of the second one with no such.
	caret_upstream:  bool,
	// The x that a caret goes to in each line that it comes to with the
	// keys for the line above and below: the x that it had in the line
	// where those keys started. Each other move of the caret ends it.
	caret_goal:      Maybe(f32),
	source_out:      [dynamic]u8, // the source, for `mdcore_source`
	// The headings and their texts, for `mdcore_outline`.
	outline:         [dynamic]Host_Heading,
	outline_titles:  [dynamic]u8,
	// Held for all of a change of the source of the document, before
	// `lock`. A frame does not take it.
	source_lock:     sync.Mutex,
	// The view.
	width, height:   f32, // points
	page_width:      f32, // the part of the width that the page is laid out in; 0 for all of it
	layout_width:    f32, // the width of the layout that is there now
	scale:           f32,
	scroll:          f64, // points
	// The strip at the top of the view that the host covers (a toolbar):
	// the reader sees the page from the scroll position plus this.
	top_inset:       f64,
	// The place of the reader: the first line that their view shows. A
	// new layout puts it at the height it had, so the scroll position of
	// the host shows the same text. The host says its scroll position
	// when it changes (`mdcore_note_scroll`, with no wait for the state),
	// and each call that changes the layout takes the place first, from
	// the layout before the change (`take_place`). Not a frame: a new
	// layout put the place where it was, and to take it again from each
	// step of a live resize moves it by a little each time.
	place:           layout.Reader_Place,
	host_scroll:     u64, // the bits of the scroll position; read and written with no lock
	place_stale:     bool, // the host scrolled since the place was taken; with no lock too
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
	if ctx.caret >= 0 && !ctx.caret_hidden && ctx.layout_valid {
		if ctx.doc.count == 0 {
			layout.caret_quad_empty(&ctx.page, ctx.scale, ctx.origin_px, &ctx.selection_quads)
		} else {
			layout.caret_quad(&ctx.page, ctx.caret_at, ctx.caret_upstream, ctx.shown_y0, ctx.shown_y1, ctx.scale, ctx.origin_px, &ctx.selection_quads)
		}
	}
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
	ctx.caret = -1
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
	delete(ctx.source_out)
	delete(ctx.outline)
	delete(ctx.outline_titles)
	delete(ctx.caret_places)
	delete(ctx.caret_pairs)
	delete(ctx.gone)
	history.destroy(&ctx.history)
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
	// The layout holds fonts of the old style. It still knows the place.
	take_place(ctx)
	layout.begin(&ctx.page, nil, fresh, 0)
	style_release(&ctx.style)
	ctx.style = fresh
	ctx.layout_valid = false
}

// Takes a new text of the document. See the header.
@(export)
mdcore_set_markdown :: proc "c" (handle: rawptr, utf8: [^]u8, length: c.long) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	change_source(ctx, length > 0 ? string(utf8[:length]) : "")
}

// Puts a text in the place of a range of the source. See the header.
@(export)
mdcore_replace_text :: proc "c" (handle: rawptr, start, end: c.long, utf8: [^]u8, length: c.long) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	command(ctx, .Replace)
	defer command_end(ctx)
	typed(ctx, length > 0 ? string(utf8[:length]) : "", int(start), int(end))
}

// Text that a reader put in, from a key or from the host: it takes the
// place of a range of the source. In an empty paragraph it starts a
// paragraph of its own there (`document.empty_text`). The caller holds
// `source_lock`, and not the lock of the state: the text that is made
// here is memory of its own, because a frame uses the working memory
// of the view at the same time.
@(private)
typed :: proc(ctx: ^Ctx, text: string, start, end: int) {
	// Not for text that starts with a line break itself (the bytes of a
	// delete that come back): it has what makes it a paragraph of its own.
	// After front matter with no line break at its end (and no text
	// after it): a line of its own, or the text goes on the closing line.
	// Not after a byte order mark alone, and not for text that starts
	// with a line break of its own.
	if len(text) > 0 && text[0] != '\n' && text[0] != '\r' && start == end && ctx.doc.count == 0 && start == ctx.doc.hidden && start > document.bom_size(ctx.doc.source) && ctx.doc.source[start - 1] != '\n' && ctx.doc.source[start - 1] != '\r' {
		own := strings.concatenate({document.line_ending(ctx.doc.source), text})
		defer delete(own)
		change_source_held(ctx, own, [2]int{start, end})
		return
	}
	if len(text) > 0 && text[0] != '\n' && text[0] != '\r' && start == end && start == ctx.caret && ctx.doc.count > 0 && document.empty_of(&ctx.doc, ctx.caret_at) > 0 {
		own := document.empty_text(&ctx.doc, text)
		defer delete(own)
		change_source_held(ctx, own, [2]int{start, end})
		return
	}
	change_source_held(ctx, text, [2]int{start, end})
}

// The one way that the source of the document changes (but for a task
// that is set in place): `text` takes the place of a range of the source
// that is there, or, with no range, is all of the new source. The document
// changes in place: the blocks that are the same keep their records, and
// the layout makes only the parts of the others again. The first
// document and a document with no block in common are the same case.
@(private)
change_source :: proc(ctx: ^Ctx, text: string, range: Maybe([2]int) = nil) {
	// One change at a time, from its edit to its end: the edit is of the
	// source that is there, and the parse runs with no lock on the state,
	// so frames go on. Only a call that changes the source takes this
	// lock, and only such a call reads the source.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	change_source_held(ctx, text, range)
}

// `change_source` for a caller that holds `source_lock`: one that made
// the range from the source as it is (a key at the caret).
@(private)
change_source_held :: proc(ctx: ^Ctx, text: string, range: Maybe([2]int) = nil, caret_after := -1) {
	edit: document.Edit
	if r, given := range.?; given {
		edit = {r[0], r[1], text}
	} else {
		edit = document.edit_between(ctx.doc.source, text)
	}
	// The text that the document has: a host that gets its own save
	// back, or the source after a task click.
	if document.edit_is_empty(edit) {
		return
	}
	if !ctx.replaying {
		if _, given := range.?; given && ctx.history.depth > 0 {
			start := clamp(edit.start, 0, len(ctx.doc.source))
			history.record(&ctx.history, start, ctx.doc.source[start:clamp(edit.end, start, len(ctx.doc.source))], edit.text, time.tick_now())
		} else {
			// Another text from the host (a file that was read again),
			// or a change of no command of the reader: the steps are of
			// a source that is no more.
			history.clear(&ctx.history)
		}
	}
	// The marks at the caret show as text: the parse of the edit makes
	// the text of its blocks with the marks of the place where the
	// caret is after it. A block with marks that the edit is not in
	// gets its text with no marks first.
	want: Maybe(int)
	after := -1
	if ctx.caret >= 0 {
		start := clamp(edit.start, 0, len(ctx.doc.source))
		end := clamp(edit.end, start, len(ctx.doc.source))
		bytes := len(edit.text) - (end - start)
		// The caret is an offset in the source: after the edit it is as
		// much later as the source is longer, and one that was in the
		// text that went is at the end of the text that came. Or the
		// caller knows a place for it in the new text.
		after = ctx.caret
		if caret_after >= 0 {
			after = caret_after
		} else if after >= end {
			after += bytes
		} else if after > start {
			after = end + bytes
		}
		after = clamp(after, 0, len(ctx.doc.source) + bytes)
		if !ctx.unfocused {
			want = after
		}
		if shown, shows := ctx.doc.reveal.?; shows && ctx.doc.count > 0 {
			block := document.block_at_offset(&ctx.doc, shown)
			if block < document.block_at_offset(&ctx.doc, start) || block > document.block_at_offset(&ctx.doc, end) {
				context.temp_allocator = ctx.temp
				hold(ctx)
				reveal_block(ctx, block, nil)
			}
		}
	}
	// All that takes time, with no change to the document: the parse of
	// the blocks around the edit, or of all of the source.
	pending := document.prepare(&ctx.doc, edit, want)
	// What is left of the two texts goes with no wait of a frame.
	defer document.discard(&pending)
	context.temp_allocator = ctx.temp
	hold(ctx)
	commit_held(ctx, &pending)
	ctx.select_from = nil
	if ctx.caret >= 0 {
		ctx.caret = after
		// Not in a character: an edit that the core found between two
		// texts can end in one.
		source := ctx.doc.source
		for ctx.caret > 0 && ctx.caret < len(source) && source[ctx.caret] & 0xc0 == 0x80 {
			ctx.caret -= 1
		}
		caret_changed(ctx)
		// An edit ends the selection, at the caret: the ends that the
		// change moved with the text are no place of the caret.
		ctx.selection = {anchor = ctx.caret_at, focus = ctx.caret_at, active = true}
	}
	if ctx.layout_valid {
		layout.restore_place(&ctx.page, ctx.place)
		layout_changed(ctx)
	}
	reveal_update(ctx)
}

// Starts a command of the reader that changes the source: its changes
// are one step of Undo, which puts the caret and the selection back as
// they are now. With text selected it is a command of its own, of no
// kind that goes on from another one. The caller holds `source_lock`,
// and ends the command with `history.end` and the caret after all that
// the command did.
@(private)
command :: proc(ctx: ^Ctx, kind: history.Kind) {
	kind, anchor := kind, -1
	if from, to, selected := selection_offsets(ctx); selected {
		kind, anchor = .Other, ctx.caret == from ? to : from
	}
	history.begin(&ctx.history, kind, ctx.caret, anchor, ctx.caret_upstream)
}

// Ends a command (`command`), with the caret after all that it did.
@(private)
command_end :: proc(ctx: ^Ctx) {
	history.end(&ctx.history, ctx.caret, ctx.caret_upstream)
}

// Makes the changes of a group of the history again, or takes them
// back, and puts the caret where it was then. The caller holds
// `source_lock`.
@(private)
replay :: proc(ctx: ^Ctx, steps: []history.Step, group: history.Group, back: bool) {
	ctx.replaying = true
	defer ctx.replaying = false
	h := &ctx.history
	if back {
		#reverse for step in steps {
			change_source_held(ctx, string(history.gone_of(h, step)), [2]int{step.start, step.start + len(history.came_of(h, step))}, group.caret_before)
		}
	} else {
		for step in steps {
			change_source_held(ctx, string(history.came_of(h, step)), [2]int{step.start, step.start + len(history.gone_of(h, step))}, group.caret_after)
		}
	}
	// No caret (a task that was set in Read mode), or a view with no
	// caret now: the caret stays as the change left it.
	caret := back ? group.caret_before : group.caret_after
	if caret < 0 || ctx.caret < 0 || ctx.doc.count == 0 {
		return
	}
	context.temp_allocator = ctx.temp
	hold(ctx)
	ctx.select_from = nil
	// The text that was selected before the command is selected again:
	// the caret is at the end where it was.
	anchor := back ? group.anchor_before : -1
	ctx.caret = clamp(anchor >= 0 ? anchor : caret, 0, len(ctx.doc.source))
	caret_changed(ctx)
	from := ctx.caret_at
	if anchor >= 0 {
		ctx.caret = clamp(caret, 0, len(ctx.doc.source))
		caret_changed(ctx)
		ctx.select_from = anchor
	}
	// At the end of a line that wraps, where the caret was: the offset
	// is also the start of the next line.
	if upstream := back ? group.upstream_before : group.upstream_after; upstream && ctx.caret == caret {
		ctx.caret_upstream = true
		caret_placed(ctx)
	}
	ctx.selection = {anchor = from, focus = ctx.caret_at, active = true}
	ctx.display_valid = false
	reveal_update(ctx)
}

// Takes back the last change of the reader. See the header.
@(export)
mdcore_undo :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	steps, group := history.undo(&ctx.history) or_return
	replay(ctx, steps, group, true)
	return true
}

// Makes the change again that the last Undo took back. See the header.
@(export)
mdcore_redo :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	steps, group := history.redo(&ctx.history) or_return
	replay(ctx, steps, group, false)
	return true
}

// See the header.
@(export)
mdcore_end_undo_group :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	history.seal(&ctx.history)
}

// See the header.
@(export)
mdcore_forget_history :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	history.clear(&ctx.history)
}

// See the header.
@(export)
mdcore_can_undo :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	return history.can_undo(&ctx.history)
}

// See the header.
@(export)
mdcore_can_redo :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	return history.can_redo(&ctx.history)
}

// Makes the change of an edit that is ready, in the document and in the
// layout, and moves each address that the view holds. The caller holds
// the two locks, and gives the reader the place again after it
// (`layout.restore_place`).
@(private)
commit_held :: proc(ctx: ^Ctx, pending: ^document.Pending) {
	// From the layout of the text before.
	take_place(ctx)
	change := document.commit(&ctx.doc, pending)
	if ctx.layout_valid {
		layout.apply_change(&ctx.page, change)
	}
	// Each address that the view holds has the number that its block
	// has now. One in the blocks that changed is at the start of
	// them, so a reader who is in such a block stays there.
	ctx.selection.anchor, _ = document.moved(change, ctx.selection.anchor)
	ctx.selection.focus, _ = document.moved(change, ctx.selection.focus)
	if ctx.place.known {
		same: bool
		ctx.place.place.at, same = document.moved(change, ctx.place.place.at)
		if !same {
			ctx.place.place.fraction = 0
		}
	}
	if change.count == 0 {
		ctx.selection, ctx.place = {}, {}
	}
}

// True for an element with marks that has an offset of the source in it
// or at one of its ends: its marks show for a caret there.
@(private)
pair_has :: proc(pair: document.Pair, at: int) -> bool {
	return (pair.close >= 0 || pair.line) && pair.open_end > pair.open && at >= pair.from && at <= pair.to
}

// True for bytes of the source that are all in one of the two marks of
// an element.
@(private)
in_mark :: proc(pair: document.Pair, from, to: int) -> bool {
	return (from >= pair.open && to <= pair.open_end) || (pair.close >= 0 && from >= pair.close && to <= pair.close_end)
}

// Makes the text of a block again with the marks of an offset as text,
// or with none, and gives it its new layout. The addresses in that
// block are of another text then. The caller holds the two locks.
@(private)
reveal_block :: proc(ctx: ^Ctx, block: int, reveal: Maybe(int)) {
	// A line that is only a list mark is a mark that is being typed when
	// the caret is in it, and a list item when it is not (`typed_mark`):
	// another shape, which can join a list or end one, and the empty lines
	// before it are other ones. The blocks around it are parsed again, as
	// for an edit, with no change of the source.
	if start, end := document.block_source(&ctx.doc, block); start < len(ctx.doc.source) {
		line := document.block_start(&ctx.doc, block)
		line_end, _ := document.line_at(ctx.doc.source, line)
		if document.bare_mark_line(ctx.doc.source, line, line_end) {
			same := strings.clone(string(ctx.doc.source[start:end]))
			defer delete(same)
			pending := document.prepare(&ctx.doc, {start, end, same}, reveal)
			defer document.discard(&pending)
			commit_held(ctx, &pending)
			if ctx.caret >= 0 {
				caret_changed(ctx)
				// The empty lines before the line can be none now (in a
				// list): an offset of the caret in them is no place of a
				// text. The caret is where text that is typed at its
				// address goes, as it shows.
				if offset, placed := document.place_of(&ctx.doc, ctx.caret_places[:], ctx.caret_at); placed && offset != ctx.caret {
					ctx.caret = offset
					caret_changed(ctx)
				}
			}
			if ctx.layout_valid {
				layout.restore_place(&ctx.page, ctx.place)
				layout_changed(ctx)
			}
			return
		}
	}
	take_place(ctx)
	pairs: [dynamic]document.Pair
	places, change := document.reveal_block(&ctx.doc, block, reveal, &pairs)
	if ctx.caret >= 0 && block == ctx.caret_at.block {
		// The map of the block of the caret is of the new text.
		delete(ctx.caret_places)
		delete(ctx.caret_pairs)
		ctx.caret_places, ctx.caret_pairs = places, pairs
	} else {
		delete(places)
		delete(pairs)
	}
	if ctx.layout_valid {
		layout.apply_change(&ctx.page, change)
	}
	// The place of the reader is at the text that it was at: marks that
	// came before it in its block make its byte another one.
	if ctx.place.known {
		same: bool
		ctx.place.place.at, same = document.moved(change, ctx.place.place.at)
		if !same {
			ctx.place.place.fraction = 0
		}
	}
	if ctx.layout_valid {
		layout.restore_place(&ctx.page, ctx.place)
		layout_changed(ctx)
	}
}

// After the caret or the selection changed: the marks of the elements
// that the caret is in show as text, and no other marks. Nothing shows
// with text selected, with no caret, and while the view does not take
// the keys. The text of a block changes with it, so the caret and the
// ends of the selection, which are offsets of the source for this, get
// their addresses again. True when the text of a block changed. The
// caller holds the two locks.
@(private)
reveal_update :: proc(ctx: ^Ctx) -> (changed: bool) {
	if ctx.doc.count == 0 {
		return
	}
	from, to, selected := selection_offsets(ctx)
	// A selection that is empty again: the caret is at the offset where
	// the selection started, when that is the same place of the text.
	if start, held := ctx.select_from.?; held && !selected && ctx.caret >= 0 && start != ctx.caret {
		if start <= len(ctx.doc.source) && document.block_at_offset(&ctx.doc, start) == ctx.caret_at.block && document.address_for(&ctx.doc, ctx.caret_places[:], ctx.caret_at.block, start) == ctx.caret_at {
			ctx.caret = start
		}
		ctx.select_from = nil
	}
	// A selection of only bytes of marks that show (Shift and a step
	// over a "*") is a selection of text that is there only while the
	// marks show: they stay, as with nothing selected.
	hides := selected
	if selected && ctx.caret >= 0 && ctx.doc.reveal != nil {
		only_marks := true
		for at := from; at < to && only_marks; at += 1 {
			only_marks = false
			for pair in ctx.caret_pairs {
				if in_mark(pair, at, at + 1) {
					only_marks = true
					break
				}
			}
		}
		hides = !only_marks
	}
	// A selection of marks that show keeps them also while the view does
	// not take the keys: with no marks it would be a selection of
	// nothing, and it is there again when the view takes the keys.
	if selected && !hides && ctx.unfocused {
		return false
	}
	want: Maybe(int)
	count := 0
	if ctx.caret >= 0 && !ctx.unfocused && !hides {
		for pair in ctx.caret_pairs {
			count += int(pair_has(pair, ctx.caret))
		}
		if count > 0 {
			want = ctx.caret
		}
	}
	shown := -1
	if old, shows := ctx.doc.reveal.?; shows {
		shown = document.block_at_offset(&ctx.doc, old)
		// The same elements as before: the text is right as it is.
		if count > 0 && shown == ctx.caret_at.block {
			same := true
			for pair in ctx.caret_pairs {
				same &&= pair_has(pair, old) == pair_has(pair, ctx.caret)
			}
			if same {
				ctx.doc.reveal = want
				return false
			}
		}
	}
	if shown < 0 && count == 0 {
		return false
	}
	// The block that has marks gets its text with none, when it is not
	// the block that gets marks now.
	forward := ctx.selection.anchor == ctx.selection.focus || document.before(ctx.selection.anchor, ctx.selection.focus)
	if shown >= 0 && (count == 0 || shown != ctx.caret_at.block) {
		reveal_block(ctx, shown, nil)
	}
	if count > 0 {
		reveal_block(ctx, ctx.caret_at.block, want)
	}
	// The addresses of the offsets, in the text that the blocks have now.
	if ctx.caret >= 0 {
		ctx.caret_at = document.address_for(&ctx.doc, ctx.caret_places[:], ctx.caret_at.block, ctx.caret)
		// With no marks in its block, the caret is at no byte in a mark
		// that it was in: at the place where text goes for its address.
		// At an end of a mark it stays: text that is typed after "**"
		// is after it when the marks do not show too.
		if count == 0 {
			inside := false
			for pair in ctx.caret_pairs {
				// With a byte of the mark before it and one after it.
				inside ||= in_mark(pair, ctx.caret - 1, ctx.caret + 1)
			}
			if offset, placed := document.place_of(&ctx.doc, ctx.caret_places[:], ctx.caret_at); placed && inside {
				ctx.caret = offset
			}
		}
		caret_placed(ctx)
	}
	if selected {
		first := from == ctx.caret && ctx.caret >= 0 ? ctx.caret_at : document.address_of(&ctx.doc, from)
		last := to == ctx.caret && ctx.caret >= 0 ? ctx.caret_at : document.address_of(&ctx.doc, to)
		ctx.selection.anchor, ctx.selection.focus = forward ? first : last, forward ? last : first
	} else if ctx.selection.active && ctx.caret >= 0 {
		ctx.selection.anchor, ctx.selection.focus = ctx.caret_at, ctx.caret_at
	}
	if ctx.display_valid {
		show_selection(ctx)
	}
	return true
}

// After the document changed, or the caret got another offset: the
// address of the caret in the text, where the text of its block is in
// the source, and the records of its block, so the caret has a place.
// The caller holds `source_lock` and the lock of the state.
@(private)
caret_changed :: proc(ctx: ^Ctx) {
	if ctx.caret < 0 || ctx.doc.count == 0 {
		return
	}
	block := document.block_at_offset(&ctx.doc, ctx.caret)
	delete(ctx.caret_places)
	clear(&ctx.caret_pairs)
	ctx.caret_places = document.block_map(&ctx.doc, block, &ctx.caret_pairs)
	ctx.caret_at = document.address_for(&ctx.doc, ctx.caret_places[:], block, ctx.caret)
	ctx.caret_upstream, ctx.caret_goal = false, nil
	caret_placed(ctx)
}

// After the caret got its address: the records of its block, so the
// caret has a place, and the quad of the caret.
@(private)
caret_placed :: proc(ctx: ^Ctx) {
	// The records of its block, when the caret has no place with the
	// ones that are there: a long code block is not laid out to its end
	// for a caret in one of its first lines.
	if ctx.layout_valid {
		if _, _, _, _, placed := layout.caret_place(&ctx.page, ctx.caret_at, ctx.caret_upstream); !placed {
			if layout.lay_out_block(&ctx.page, ctx.caret_at.block) {
				layout_changed(ctx)
			}
		}
	}
	// The caret is drawn with the selection; the quads of the page are
	// as they were.
	if ctx.display_valid {
		show_selection(ctx)
	}
}

// A place that a caret can have: an address with its offset in the
// source. `places` is the map of its block; `made` when it is not the
// one of the caret's block, and then it is the caller's to delete or
// to give to `set_caret`.
@(private)
Stop :: struct {
	at:     document.Address,
	offset: int,
	places: [dynamic]document.Place,
	pairs:  [dynamic]document.Pair,
	made:   bool,
}

@(private)
stop_delete :: proc(stop: Stop) {
	if stop.made {
		delete(stop.places)
		delete(stop.pairs)
	}
}

// The stop of an address, with a map that is of its block (`found.places`
// from a look at an address of the same block before, or none). False
// for an address that the source has no room for (a table cell with no
// text); `found` then still has the map, for the next look.
@(private)
stop_look :: proc(ctx: ^Ctx, at: document.Address, held: Stop) -> (found: Stop, ok: bool) {
	found = held
	if found.places == nil {
		found.places = ctx.caret_places
		if ctx.caret < 0 || at.block != ctx.caret_at.block {
			found.places, found.made = document.block_map(&ctx.doc, at.block, &found.pairs), true
		}
	}
	found.offset, ok = document.place_of(&ctx.doc, found.places[:], at)
	// The address that the caret gets from that offset can be another
	// one (the two ends of one thing of the source), in the same block.
	ok &&= document.block_at_offset(&ctx.doc, found.offset) == at.block
	if ok {
		found.at = document.address_for(&ctx.doc, found.places[:], at.block, found.offset)
	}
	return
}

// The stop of an address. False for an address that is none.
@(private)
stop_at :: proc(ctx: ^Ctx, at: document.Address) -> (stop: Stop, ok: bool) {
	if stop, ok = stop_look(ctx, at, {}); !ok {
		stop_delete(stop)
		return {}, false
	}
	return
}

// The stop at an address, or the first one from there in reading order
// or against it. False when the rest of the document has none. The map
// of a block is made one time for all of its addresses.
@(private)
stop_from :: proc(ctx: ^Ctx, at: document.Address, forward: bool) -> (stop: Stop, ok: bool) {
	at := at
	for {
		if stop, ok = stop_look(ctx, at, stop); ok {
			return
		}
		next, more := document.step(&ctx.doc, at, .Character, forward)
		if !more || next.block != at.block {
			stop_delete(stop)
			stop = {}
		}
		if !more {
			return {}, false
		}
		at = next
	}
}

// Puts the caret at a stop: the one writer of the caret that is not an
// edit. The selection ends at the caret, and starts at `anchor`.
@(private)
set_caret :: proc(ctx: ^Ctx, stop: Stop, upstream: bool, anchor: document.Address) {
	if stop.made {
		delete(ctx.caret_places)
		delete(ctx.caret_pairs)
		ctx.caret_places, ctx.caret_pairs = stop.places, stop.pairs
	}
	ctx.caret, ctx.caret_at = stop.offset, stop.at
	ctx.caret_upstream, ctx.caret_goal = upstream, nil
	ctx.selection = {anchor = anchor, focus = stop.at, active = true}
	caret_placed(ctx)
}

// How far the pointer goes from the point of a click, in points, before
// it is a drag that selects.
MOUSE_SLOP :: 3

// The moves of `mdcore_caret_move`, with the numbers of the header.
Move :: enum c.int {
	Left            = 0,
	Right           = 1,
	Word_Left       = 2,
	Word_Right      = 3,
	Up              = 4,
	Down            = 5,
	Line_Start      = 6,
	Line_End        = 7,
	Document_Start  = 8,
	Document_End    = 9,
	Paragraph_Start = 10,
	Paragraph_End   = 11,
}

// The moves that go on in reading order; each other one but up and down
// goes against it.
MOVES_FORWARD :: bit_set[Move]{.Right, .Word_Right, .Line_End, .Document_End, .Paragraph_End}
MOVES_VERTICAL :: bit_set[Move]{.Up, .Down}
MOVES_TO_END :: bit_set[Move]{.Line_Start, .Line_End, .Document_Start, .Document_End, .Paragraph_Start, .Paragraph_End}

// The address that a move of the caret goes to from a place, before
// the look for a stop there. False when there is none: at an end of
// the document, in the first or the last line for up and down, and for
// a caret with no place.
@(private)
move_from :: proc(ctx: ^Ctx, at: document.Address, upstream: bool, move: Move, goal: f32) -> (next: document.Address, next_upstream: bool, ok: bool) {
	switch move {
	case .Left, .Right:
		next, ok = document.step(&ctx.doc, at, .Character, move == .Right)
	case .Word_Left, .Word_Right:
		next, ok = document.step(&ctx.doc, at, .Word, move == .Word_Right)
	case .Up, .Down:
		return layout.caret_line_step(&ctx.page, at, upstream, goal, move == .Down)
	case .Line_Start, .Line_End:
		return layout.caret_line_end(&ctx.page, at, upstream, move == .Line_End)
	case .Document_Start, .Document_End:
		first, last := document.caret_ends(&ctx.doc) or_return
		next, ok = move == .Document_Start ? first : last, true
	case .Paragraph_Start, .Paragraph_End:
		src := document.text_at(&ctx.doc, at)
		if src == nil {
			return
		}
		next, ok = at, true
		// An empty paragraph is a paragraph with one place.
		if document.empty_of(&ctx.doc, at) > 0 {
			return
		}
		next.byte, next.spaces = document.paragraph_end(src.bytes[:], at.byte, move == .Paragraph_End), 0
		if move == .Paragraph_End {
			next = document.with_end_spaces(&ctx.doc, next)
		}
	}
	return
}

// Moves the caret. See the header.
@(export)
mdcore_caret_move :: proc "c" (handle: rawptr, move: Move, extend: bool) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// The source does not change under the look at it.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	// A change after a move of the caret is a step of its own.
	history.seal(&ctx.history)
	went := Move.Left
	if !extend {
		ctx.select_from = nil
	} else if _, _, selected := document.selection_range(ctx.selection); !selected && ctx.caret >= 0 {
		ctx.select_from = ctx.caret
	}
	moved := caret_move(ctx, move, extend, &went)
	// A move to an end of a line, a paragraph, or the document that made
	// marks show there: the end is after those marks (before them, for
	// a start), so the move goes on one time in the text with the marks.
	if reveal_update(ctx) && moved && went in MOVES_TO_END {
		caret_move(ctx, went, extend)
		reveal_update(ctx)
	}
	return moved
}

// `mdcore_caret_move`, for a caller that holds `source_lock` and the
// lock of the state. The marks at the caret are the caller's to bring
// up to date (`reveal_update`). `went`: the move that was made.
@(private)
caret_move :: proc(ctx: ^Ctx, move: Move, extend: bool, went: ^Move = nil) -> bool {
	if ctx.caret < 0 || ctx.doc.count == 0 || move < min(Move) || move > max(Move) {
		return false
	}
	// The caret is the end of the selection that moves. With text
	// selected and no `extend`, the move starts at the end of the
	// selection that is in its direction, and a step of one character
	// goes no farther than that.
	at, upstream := ctx.caret_at, ctx.caret_upstream
	anchor := ctx.selection.active && ctx.selection.focus == at ? ctx.selection.anchor : at
	collapse := !extend && anchor != at
	if collapse {
		first, last, _ := document.selection_range({active = true, anchor = anchor, focus = at})
		side := move in MOVES_FORWARD || move == .Down ? last : first
		if side != at {
			at, upstream = side, false
		}
		if move == .Left || move == .Right {
			if stop, ok := stop_from(ctx, at, move == .Right); ok {
				set_caret(ctx, stop, upstream && stop.at == at, stop.at)
				return true
			}
		}
	}
	move := move
	goal: f32
	if move in MOVES_VERTICAL || move == .Line_Start || move == .Line_End {
		// A move by lines needs the records of the line of the caret,
		// and one up or down those of the lines around it: a line with
		// none is no line that the caret can go to, and is not the end
		// of the document.
		if !ctx.layout_valid {
			return false
		}
		x, y, _, placed := layout.caret_y(&ctx.page, at, upstream)
		if !placed {
			if layout.lay_out_block(&ctx.page, at.block) {
				layout_changed(ctx)
			}
			x, y, _, placed = layout.caret_y(&ctx.page, at, upstream)
			if !placed {
				return false
			}
		}
		goal = ctx.caret_goal.? or_else x
	}
	keep_goal := move in MOVES_VERTICAL
	next: document.Address
	next_upstream, found: bool
	if move in MOVES_VERTICAL {
		// The lines around the caret get their records, farther each
		// time, until one of them is the next line or the page ends
		// there: blocks with no text (many rules) can be between the
		// caret and the next line.
		// From a reach that is more than nothing: a view with no height
		// yet would look at the same lines each time.
		for reach := max(f64(ctx.height), 64);; reach *= 4 {
			_, y, _, _ := layout.caret_y(&ctx.page, at, upstream)
			if !layout.laid_out(&ctx.page, y - reach, y + reach) && layout.lay_out(&ctx.page, y - reach, y + reach, y) {
				layout_changed(ctx)
				_, y, _, _ = layout.caret_y(&ctx.page, at, upstream)
			}
			next, next_upstream, found = move_from(ctx, at, upstream, move, goal)
			if found || (move == .Up ? y - reach <= ctx.page.origin : y + reach >= ctx.page.origin + ctx.page.content_height) {
				break
			}
		}
	} else {
		next, next_upstream, found = move_from(ctx, at, upstream, move, goal)
	}
	if !found && move in MOVES_VERTICAL {
		// No line above the first line and none below the last one: to
		// that end of the document.
		move = move == .Up ? .Document_Start : .Document_End
		next, next_upstream, found = move_from(ctx, at, upstream, move, goal)
	}
	// Some addresses are no place for a caret (a table cell with no
	// text), and some are one place of the source: the caret goes to
	// the first stop on from where the move went to (back into the
	// text from its end), and a step to the left or to the right goes
	// on until the caret is at another stop. A step of a word goes on
	// by words.
	forward := move in MOVES_FORWARD
	words := move == .Word_Left || move == .Word_Right
	on_from_there := bit_set[Move]{.Right, .Word_Right, .Down, .Document_Start, .Line_Start, .Paragraph_Start}
	for found {
		stop: Stop
		placed: bool
		if words {
			stop, placed = stop_at(ctx, next)
		} else {
			stop, placed = stop_from(ctx, next, move in on_from_there)
		}
		moved := false
		if placed {
			// The side is of the address that the move went to.
			next_upstream &&= stop.at == next
			switch {
			case move in MOVES_VERTICAL:
				moved = stop.at != at || next_upstream != upstream
			case forward:
				moved = document.before(at, stop.at)
			case:
				moved = document.before(stop.at, at)
			}
		}
		if moved {
			set_caret(ctx, stop, next_upstream, extend ? anchor : stop.at)
			if keep_goal {
				ctx.caret_goal = goal
			}
			// The move that it was: up in the first line is a move to
			// the start of the document.
			if went != nil {
				went^ = move
			}
			return true
		}
		if placed {
			stop_delete(stop)
		}
		#partial switch move {
		case .Left, .Right, .Word_Left, .Word_Right:
			next, next_upstream, found = move_from(ctx, next, false, move, goal)
		case:
			found = false
		}
	}
	if collapse {
		// The caret is at an end of the document already: the selection
		// ends all the same, at its end in the direction of the move.
		if stop, ok := stop_from(ctx, at, forward); ok {
			set_caret(ctx, stop, upstream && stop.at == at, stop.at)
			return true
		}
	}
	return false
}

// Puts the caret at the text that is nearest to a point of the page.
// See the header.
@(export)
mdcore_caret_set :: proc "c" (handle: rawptr, x, y: f64) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// The source does not change under the look at it.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	history.seal(&ctx.history)
	if ctx.doc.count == 0 {
		// A document with no text yet: text goes at its start, after
		// the bytes that are no Markdown (front matter, which does not
		// show).
		ctx.caret = ctx.doc.hidden
		ctx.display_valid = false
		return true
	}
	// Not at text that has no place in the source for text to go to.
	// The caret then stays, and so does the selection at it: the click
	// (`mdcore_mouse`) put the selection at the text of the point.
	stop: Stop
	at, upstream, placed := layout.caret_hit(&ctx.page, f32(x), y)
	if placed {
		stop, placed = stop_at(ctx, at)
	}
	if !placed {
		if ctx.caret >= 0 {
			ctx.selection = {anchor = ctx.caret_at, focus = ctx.caret_at, active = true}
			show_selection(ctx)
			ctx.select_from = nil
			reveal_update(ctx)
		}
		return false
	}
	// The selection is empty and at the caret, which can be beside the
	// point (at an end of an entity that is one thing): a drag from here
	// selects from this place (`mdcore_mouse`).
	ctx.select_from = nil
	set_caret(ctx, stop, upstream && stop.at == at, stop.at)
	reveal_update(ctx)
	return true
}

// See the header.
@(export)
mdcore_caret_clear :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	// A selection with marks that show is of those marks only (text
	// that is selected shows none): it goes with them, or its ends
	// would be at other text.
	if ctx.doc.reveal != nil {
		if _, _, selected := document.selection_range(ctx.selection); selected {
			ctx.selection = {}
		}
	}
	ctx.caret = -1
	ctx.display_valid = false
	reveal_update(ctx)
}

// See the header.
@(export)
mdcore_caret_offset :: proc "c" (handle: rawptr) -> c.long {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	return c.long(ctx.caret)
}

// See the header.
@(export)
mdcore_caret_show :: proc "c" (handle: rawptr, shown: bool) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if ctx.caret_hidden == shown {
		ctx.caret_hidden = !shown
		// Only the quads of the selection and the caret: the page is
		// the same.
		if ctx.display_valid {
			show_selection(ctx)
		}
	}
}

// See the header.
@(export)
mdcore_set_focused :: proc "c" (handle: rawptr, focused: bool) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	if ctx.unfocused == focused {
		ctx.unfocused = !focused
		reveal_update(ctx)
	}
}

// See the header.
@(export)
mdcore_caret_rect :: proc "c" (handle: rawptr, x, y, height: ^f64) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if ctx.caret < 0 || !ctx.layout_valid {
		return false
	}
	if ctx.doc.count == 0 {
		cx, top, h := layout.caret_place_empty(&ctx.page)
		x^, y^, height^ = f64(cx), ctx.page.origin + f64(top), f64(h)
		return true
	}
	cx, cy, h := layout.caret_y(&ctx.page, ctx.caret_at, ctx.caret_upstream) or_return
	x^, y^, height^ = f64(cx), cy, f64(h)
	return true
}

// The offset in the source of an end of the selection: the caret's, or
// the place of its address, or of the first one from there to the
// inside of the selection.
@(private)
selection_end :: proc(ctx: ^Ctx, at: document.Address, inward: bool) -> (offset: int, ok: bool) {
	if at == ctx.caret_at {
		return ctx.caret, true
	}
	stop := stop_from(ctx, at, inward) or_return
	defer stop_delete(stop)
	return stop.offset, true
}

// The offsets in the source of the two ends of the text that is
// selected, in the order of the source. False with no text selected.
@(private)
selection_offsets :: proc(ctx: ^Ctx) -> (from, to: int, ok: bool) {
	if ctx.caret < 0 || ctx.doc.count == 0 {
		return
	}
	first, last := document.selection_range(ctx.selection) or_return
	from = selection_end(ctx, first, true) or_return
	to = selection_end(ctx, last, false) or_return
	return from, to, from < to
}

// Puts `text` in the place of the text between two offsets of the
// source that are places of a caret, and the caret after it. False for
// a range that the document has no edit for (`document.replace_range`):
// nothing changes then.
@(private)
replace_between :: proc(ctx: ^Ctx, from, to: int, text: string) -> bool {
	// The map of the block of the caret is there already.
	// The marks that show at the caret are text: one that is selected
	// goes as text does, and is not kept for the text of its style. So
	// the edit does not know the elements of the marks that go.
	pairs := ctx.caret_pairs[:]
	hidden: [dynamic]document.Pair
	defer delete(hidden)
	if shown, shows := ctx.doc.reveal.?; shows {
		for pair in ctx.caret_pairs {
			// Only the elements with a mark that the range has a byte
			// of: for each other one the edit keeps the style right, as
			// it does with no marks in the text.
			touched := pair_has(pair, shown) && ((from < pair.open_end && to > pair.open) || (pair.close >= 0 && from < pair.close_end && to > pair.close))
			if !touched {
				append(&hidden, pair)
			}
		}
		pairs = hidden[:]
	}
	held := document.Held{ctx.caret_at.block, ctx.caret_places[:], pairs, true}
	clear(&ctx.gone)
	edit, caret := document.replace_range(&ctx.doc, from, to, text, held, gone = &ctx.gone) or_return
	defer delete(edit.text)
	change_source_held(ctx, edit.text, [2]int{edit.start, edit.end}, caret)
	return true
}

// Puts `text` in the place of the text that is selected. `selected`:
// there was such text; with none, the caller does what it does at a
// caret. `changed` is false for a selection that has no edit.
@(private)
replace_selection :: proc(ctx: ^Ctx, text: string) -> (selected, changed: bool) {
	from, to := selection_offsets(ctx) or_return
	return true, replace_between(ctx, from, to, text)
}

// After an edit that left the caret at an offset where no text goes
// (before the marks of a line): the caret is where text that is typed
// at its address goes.
@(private)
caret_to_place :: proc(ctx: ^Ctx) {
	if ctx.caret < 0 || ctx.doc.count == 0 {
		return
	}
	if offset, placed := document.place_of(&ctx.doc, ctx.caret_places[:], ctx.caret_at); placed && offset != ctx.caret {
		context.temp_allocator = ctx.temp
		// A reader of the caret holds the lock of the state.
		hold(ctx)
		ctx.caret = offset
		reveal_update(ctx)
	}
}

// Puts text in at the caret, or in the place of the text that is
// selected. See the header.
@(export)
mdcore_insert :: proc "c" (handle: rawptr, utf8: [^]u8, length: c.long) -> bool {
	context = runtime.default_context()
	return insert(cast(^Ctx)handle, utf8, length, .Typing)
}

// `mdcore_insert` for text that the reader did not type: a group of its
// own for Undo. See the header.
@(export)
mdcore_paste :: proc "c" (handle: rawptr, utf8: [^]u8, length: c.long) -> bool {
	context = runtime.default_context()
	return insert(cast(^Ctx)handle, utf8, length, .Other)
}

@(private)
insert :: proc(ctx: ^Ctx, utf8: [^]u8, length: c.long, kind: history.Kind) -> bool {
	// From the look at the caret to the end of the change: no other
	// change of the source comes between.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	if ctx.caret < 0 || length <= 0 {
		return false
	}
	command(ctx, kind)
	defer command_end(ctx)
	if selected, changed := replace_selection(ctx, string(utf8[:length])); selected {
		return changed
	}
	// A mark that is being typed (`Shape.typed`) is a list item after a
	// space: it can join the list above it.
	space := length == 1 && (utf8[0] == ' ' || utf8[0] == '\t')
	was_mark := space && ctx.doc.count > 0 && ctx.caret_at.empty == 0 && document.block_at(&ctx.doc, ctx.caret_at.block).typed
	typed(ctx, string(utf8[:length]), ctx.caret, ctx.caret)
	// A list that the reader starts below another one, after empty
	// lines, is a list of its own: its mark is the other one, in the same
	// step of Undo.
	if was_mark && ctx.doc.count > 0 && ctx.caret_at.empty == 0 {
		if at, mark := document.new_list_mark(&ctx.doc, ctx.caret_at.block); at >= 0 {
			change_source_held(ctx, string([]u8{mark}), [2]int{at, at + 1}, ctx.caret)
		}
	}
	return true
}

// Return at the caret. See the header.
@(export)
mdcore_insert_break :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	if ctx.caret < 0 {
		return
	}
	// Return does nothing in a table, so nothing goes there.
	if ctx.doc.count > 0 && ctx.caret_at.empty == 0 && document.block_at(&ctx.doc, ctx.caret_at.block).kind == .Table {
		return
	}
	command(ctx, .Other)
	defer command_end(ctx)
	// The text that is selected goes first: the line break is at the
	// place where it was. Nothing for a selection that has no edit.
	if selected, changed := replace_selection(ctx, ""); selected && !changed {
		return
	}
	if ctx.doc.count == 0 {
		// A document with no block: a line break, as each other text
		// that is typed there.
		change_source_held(ctx, document.line_ending(ctx.doc.source), [2]int{ctx.caret, ctx.caret})
		return
	}
	// The text is memory of its own: a frame uses the working memory of
	// the view at the same time.
	if start, end, text, caret, ok := document.line_break(&ctx.doc, ctx.caret_places[:], ctx.caret_at); ok {
		defer delete(text)
		change_source_held(ctx, text, [2]int{start, end}, caret)
		// The caret can be before the marks of its new line (the mark
		// of a quote): text that is typed goes where its address is.
		// Not in a document that has no block now (the item with no
		// text was all of it): the caret has no address there.
		caret_to_place(ctx)
	}
}

// Takes out the character before the caret. True when the source
// changed. The caller holds `source_lock`.
@(private)
delete_back :: proc(ctx: ^Ctx) -> bool {
	// An empty paragraph or a list item with no text goes, and the
	// caret is at the end of what is before it.
	if start, end, caret, ok := document.delete_back(&ctx.doc, ctx.caret_places[:], ctx.caret_at); ok {
		clear(&ctx.gone)
		append(&ctx.gone, ..ctx.doc.source[start:end])
		change_source_held(ctx, "", [2]int{start, end}, caret)
		return true
	}
	// The character before the caret, with the marks of a style that
	// has no other text. After spaces at the end of a text, one of them.
	// At the start of a block, its text goes on in the block before it.
	return delete_to(ctx, .Left)
}

// Takes out the text from the caret to where a move of the caret goes.
// True when the source changed. The caller holds `source_lock`.
@(private)
delete_to :: proc(ctx: ^Ctx, move: Move) -> bool {
	start, was := ctx.caret, ctx.caret_at
	moved: bool
	{
		// The marks stay as they are for the selection of a moment that
		// the move makes: the text that goes is what shows now.
		context.temp_allocator = ctx.temp
		hold(ctx)
		moved = caret_move(ctx, move, true)
	}
	if !moved {
		return false
	}
	from, to := min(start, ctx.caret), max(start, ctx.caret)
	// One character of a text goes with the bytes that the source has
	// for it, and no more: between two pieces of a mark that shows
	// over two lines are a line break and the mark of a quote, which
	// are no part of the character on either side.
	if now := ctx.caret_at; (move == .Left || move == .Right) && was.block == now.block && was.cell == now.cell && was.empty == 0 && now.empty == 0 && was.spaces == 0 && now.spaces == 0 {
		earlier, later := move == .Left ? now : was, move == .Left ? was : now
		// All of the character: a letter with a mark of its own is some
		// code points, and one step. A thing that the source has in
		// another form (an entity) is one piece, which goes as a whole.
		first, last, found := document.char_source(&ctx.doc, ctx.caret_places[:], later, earlier.byte, later.byte)
		if !found {
			first, last, found = document.char_before(&ctx.doc, ctx.caret_places[:], later)
			found &&= later.byte - earlier.byte <= 4
		}
		if found && first >= from && last <= to && first < last {
			from, to = first, last
		}
	}
	if ctx.caret != start && replace_between(ctx, from, to, "") {
		return true
	}
	// No edit for that text: the caret is where it was, with nothing
	// selected.
	context.temp_allocator = ctx.temp
	hold(ctx)
	ctx.caret = start
	caret_changed(ctx)
	ctx.selection = {anchor = ctx.caret_at, focus = ctx.caret_at, active = true}
	show_selection(ctx)
	reveal_update(ctx)
	return false
}

// Takes out the text that is selected, or the text from the caret to
// where a move goes. See the header.
@(export)
mdcore_delete :: proc "c" (handle: rawptr, move: Move) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	// The bytes of the delete before are of that delete only.
	clear(&ctx.gone)
	if ctx.caret < 0 || ctx.doc.count == 0 || move < min(Move) || move > max(Move) {
		return false
	}
	command(ctx, move == .Left ? .Back : move == .Right ? .Forward : .Other)
	defer command_end(ctx)
	if selected, changed := replace_selection(ctx, ""); selected {
		return changed
	}
	move := move
	at := ctx.caret_at
	text := document.text_at(&ctx.doc, at)
	if text != nil {
		// At an end of a text, a word or the rest of a paragraph is the
		// line break only: the text beside it stays.
		empty := document.empty_of(&ctx.doc, at) > 0
		#partial switch move {
		case .Word_Left:
			move = at.byte <= 0 || empty ? .Left : move
		case .Word_Right:
			move = at.byte >= len(text.bytes) ? .Right : move
		case .Paragraph_End:
			move = empty || document.paragraph_end(text.bytes[:], at.byte, true) == at.byte ? .Right : move
		case .Paragraph_Start:
			move = empty || document.paragraph_end(text.bytes[:], at.byte, false) == at.byte ? .Left : move
		}
	}
	if move == .Left {
		return delete_back(ctx)
	}
	return delete_to(ctx, move)
}

// See the header.
@(export)
mdcore_deleted_text :: proc "c" (handle: rawptr, length: ^c.long) -> [^]u8 {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// A delete writes the bytes with this lock.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	length^ = c.long(len(ctx.gone))
	return raw_data(ctx.gone)
}

// Takes out the lines of the source that the caret or the selection is
// in. See the header.
@(export)
mdcore_delete_lines :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	if ctx.caret < 0 || ctx.doc.count == 0 {
		return false
	}
	from, to, selected := selection_offsets(ctx)
	if !selected {
		from, to = ctx.caret, ctx.caret
	}
	edit, caret := document.remove_lines(&ctx.doc, from, to) or_return
	defer delete(edit.text)
	command(ctx, .Other)
	defer command_end(ctx)
	change_source_held(ctx, edit.text, [2]int{edit.start, edit.end}, caret)
	caret_to_place(ctx)
	return true
}

// Changes the places of the two characters around the caret. See the
// header.
@(export)
mdcore_transpose :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	if ctx.caret < 0 || ctx.doc.count == 0 {
		return false
	}
	if _, _, selected := document.selection_range(ctx.selection); selected {
		return false
	}
	edit, caret := document.transpose(&ctx.doc, ctx.caret_places[:], ctx.caret_at) or_return
	defer delete(edit.text)
	command(ctx, .Other)
	defer command_end(ctx)
	change_source_held(ctx, edit.text, [2]int{edit.start, edit.end}, caret)
	return true
}

// The source of the document as it is now. See the header.
@(export)
mdcore_source :: proc "c" (handle: rawptr, length: ^c.long) -> [^]u8 {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	clear(&ctx.source_out)
	append(&ctx.source_out, ..ctx.doc.source)
	length^ = c.long(len(ctx.source_out))
	return raw_data(ctx.source_out)
}

Host_Heading :: struct {
	level, line:            c.long,
	title_start, title_end: c.long, // a range of the texts (`mdcore_outline`)
}

// The headings of the document, for an outline. See the header.
@(export)
mdcore_outline :: proc "c" (handle: rawptr, count: ^c.long, titles: ^[^]u8) -> [^]Host_Heading {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	headings := make([dynamic]document.Heading, context.temp_allocator)
	clear(&ctx.outline_titles)
	document.outline(&ctx.doc, &ctx.outline_titles, &headings)
	clear(&ctx.outline)
	for h in headings {
		append(&ctx.outline, Host_Heading{c.long(h.level), c.long(h.line), c.long(h.title[0]), c.long(h.title[1])})
	}
	count^ = c.long(len(ctx.outline))
	titles^ = raw_data(ctx.outline_titles)
	return raw_data(ctx.outline)
}

// See the header.
@(export)
mdcore_select_none :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// An edit reads the selection with this lock.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	ctx.selection = {}
	show_selection(ctx)
	reveal_update(ctx)
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
		take_place(ctx)
		ctx.layout_width = page_width
		layout.begin(&ctx.page, &ctx.doc, ctx.style, page_width)
		// The text that the reader was at keeps its height on the page.
		layout.restore_place(&ctx.page, ctx.place)
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

// The view is at a scroll position: lays out what it shows there, and
// takes the reader's place from it. `anchor_y`: the height of the page
// whose text stays where it is when a part is laid out for it.
@(private)
scroll_to :: proc(ctx: ^Ctx, scroll_y, anchor_y: f64) {
	ctx.scroll = scroll_y
	keep_window(ctx)
	height := f64(ctx.height)
	if !layout.laid_out(&ctx.page, ctx.scroll - NEEDED_ABOVE * height, ctx.scroll + NEEDED_BELOW * height) &&
	   layout.lay_out(&ctx.page, ctx.scroll - LAID_ABOVE * height, ctx.scroll + LAID_BELOW * height, anchor_y) {
		layout_changed(ctx)
	}
}

// Takes the reader's place from the layout that is there, when the host
// scrolled since it was taken. Each call that ends or changes the layout
// calls this first.
@(private)
take_place :: proc(ctx: ^Ctx) {
	if !ctx.layout_valid || !sync.atomic_load(&ctx.place_stale) {
		return
	}
	sync.atomic_store(&ctx.place_stale, false)
	// Only the line of the place needs its records: the first line of
	// text at or below the height. That can be some way down (below a
	// rule, below blank lines of a code block), so the range grows until
	// it has one, or until the end of the page.
	at := transmute(f64)sync.atomic_load(&ctx.host_scroll) + ctx.top_inset
	for reach := f64(1);; reach *= 8 {
		if layout.lay_out(&ctx.page, at, at + reach, at) {
			layout_changed(ctx)
		}
		ctx.place = layout.take_place(&ctx.page, at)
		bottom := ctx.page.origin + ctx.page.content_height
		if ctx.place.known || at <= ctx.page.origin + 0.5 || at + reach >= bottom {
			break
		}
	}
}

// See the header. No wait for the state of the view: the host calls this
// for each step of a scroll.
@(export)
mdcore_note_scroll :: proc "c" (handle: rawptr, scroll_y: f64) {
	ctx := cast(^Ctx)handle
	bits := transmute(u64)scroll_y
	if sync.atomic_exchange(&ctx.host_scroll, bits) != bits {
		sync.atomic_store(&ctx.place_stale, true)
	}
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
		scroll_to(ctx, scroll_y, anchor_y)
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
		out[i] = {f64(t.x), t.y, size, c.long(document.task_line(&ctx.doc, t.part, t.block)), t.block.marker == .Task_Done}
	}
	return c.long(count)
}

@(export)
mdcore_set_task_checked :: proc "c" (handle: rawptr, line: c.long, checked: bool) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// The mark goes into the source too.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	mark := -1
	was: u8
	if !document.set_task_done(&ctx.doc, int(line), checked, &mark, &was) {
		return false
	}
	// A step of Undo: the one byte of the mark. Also with no caret (in
	// Read mode): it is a change of the source as each other one, and a
	// step that is not there would make the later ones wrong.
	if mark >= 0 {
		command(ctx, .Other)
		history.record(&ctx.history, mark, []u8{was}, string(ctx.doc.source[mark:mark + 1]), time.tick_now())
		command_end(ctx)
	}
	// The places are the same; only the color of the item's text changes.
	ctx.display_valid = false
	return true
}

// See the header.
@(export)
mdcore_set_top_inset :: proc "c" (handle: rawptr, inset: f64) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	if inset != ctx.top_inset {
		// The place was of the line below the strip before.
		take_place(ctx)
		ctx.top_inset = inset
		// Another line is the first one now.
		sync.atomic_store(&ctx.place_stale, true)
	}
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
	// The caret goes with a drag, and its place is a look at the source.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	history.seal(&ctx.history)
	if phase == 0 {
		ctx.mouse_down, ctx.mouse_dragged = {x, y}, false
	} else if !ctx.mouse_dragged {
		if abs(x - ctx.mouse_down.x) + abs(y - ctx.mouse_down.y) < MOUSE_SLOP {
			return
		}
		ctx.mouse_dragged = true
	}
	if phase != 0 && ctx.caret >= 0 {
		// The caret of an editor is the end of the selection that
		// moves: the next key goes on from there. Its place is the one
		// that a click at the point gives. Not at a place where the
		// source has no room for text; the caret then stays.
		pos, upstream, hit := layout.caret_hit(&ctx.page, f32(x), y)
		if !hit {
			return
		}
		if stop, placed := stop_at(ctx, pos); placed {
			upstream &&= stop.at == pos
			if stop.at != ctx.caret_at || upstream != ctx.caret_upstream || !ctx.selection.active {
				set_caret(ctx, stop, upstream, ctx.selection.active ? ctx.selection.anchor : stop.at)
				reveal_update(ctx)
			} else {
				stop_delete(stop)
			}
		}
		return
	}
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

// See the header.
@(export)
mdcore_has_selection :: proc "c" (handle: rawptr) -> bool {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	_, _, selected := document.selection_range(ctx.selection)
	return selected
}

@(export)
mdcore_select_all :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	// The caret goes to the end of the selection: a look at the source.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	hold(ctx)
	ctx.selection = document.select_all(&ctx.doc)
	ctx.display_valid = false
	if ctx.caret >= 0 && ctx.selection.active {
		// The caret of an editor is the end of the selection, so the
		// next key with the selection goes on from there.
		if stop, ok := stop_from(ctx, ctx.selection.focus, false); ok {
			set_caret(ctx, stop, false, ctx.selection.anchor)
		}
	}
	reveal_update(ctx)
}

// The selected text as UTF-8. The pointer is valid until the next call.
@(export)
mdcore_selection_text :: proc "c" (handle: rawptr, length: ^c.long) -> [^]u8 {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	clear(&ctx.clipboard)
	document.selection_text(&ctx.doc, ctx.selection, &ctx.clipboard)
	length^ = c.long(len(ctx.clipboard))
	return raw_data(ctx.clipboard)
}
