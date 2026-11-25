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
	delete(ctx.caret_places)
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
	change_source(ctx, length > 0 ? string(utf8[:length]) : "", [2]int{int(start), int(end)})
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
change_source_held :: proc(ctx: ^Ctx, text: string, range: Maybe([2]int) = nil) {
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
	// All that takes time, with no change to the document: the parse of
	// the blocks around the edit, or of all of the source.
	pending := document.prepare(&ctx.doc, edit)
	// What is left of the two texts goes with no wait of a frame.
	defer document.discard(&pending)
	context.temp_allocator = ctx.temp
	hold(ctx)
	// From the layout of the text before.
	take_place(ctx)
	change := document.commit(&ctx.doc, &pending)
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
	// The caret is an offset in the source: after the edit it is as much
	// later as the source is longer, and one that was in the text that
	// went is at the end of the text that came.
	if ctx.caret >= 0 {
		edit := pending.edit
		if ctx.caret >= edit.end {
			ctx.caret += pending.bytes
		} else if ctx.caret > edit.start {
			ctx.caret = edit.end + pending.bytes
		}
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
	ctx.caret_places = document.block_map(&ctx.doc, block)
	ctx.caret_at = document.address_in(ctx.caret_places[:], block, ctx.caret)
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
	made:   bool,
}

@(private)
stop_delete :: proc(stop: Stop) {
	if stop.made {
		delete(stop.places)
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
			found.places, found.made = document.block_map(&ctx.doc, at.block), true
		}
	}
	found.offset, ok = document.place_of(&ctx.doc, found.places[:], at)
	// The address that the caret gets from that offset can be another
	// one (the two ends of one thing of the source), in the same block.
	ok &&= document.block_at_offset(&ctx.doc, found.offset) == at.block
	if ok {
		found.at = document.address_in(found.places[:], at.block, found.offset)
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
		ctx.caret_places = stop.places
	}
	ctx.caret, ctx.caret_at = stop.offset, stop.at
	ctx.caret_upstream, ctx.caret_goal = upstream, nil
	ctx.selection = {anchor = anchor, focus = stop.at, active = true}
	caret_placed(ctx)
}

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
		next.byte = document.paragraph_end(src.bytes[:], at.byte, move == .Paragraph_End)
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
	if move in MOVES_VERTICAL {
		// The line of the caret and the lines around it have their
		// records: a line with none is no line that the caret can go
		// to, and is not the end of the document.
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
		reach := f64(ctx.height)
		if !layout.laid_out(&ctx.page, y - reach, y + reach) && layout.lay_out(&ctx.page, y - reach, y + reach, y) {
			layout_changed(ctx)
		}
	}
	keep_goal := move in MOVES_VERTICAL
	next, next_upstream, found := move_from(ctx, at, upstream, move, goal)
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
	if ctx.doc.count == 0 {
		// A document with no text yet: text goes at its start.
		ctx.caret = 0
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
		}
		return false
	}
	// The selection is empty and at the caret, which can be beside the
	// point (at an end of an entity that is one thing): a drag from here
	// selects from this place (`mdcore_mouse`).
	set_caret(ctx, stop, upstream && stop.at == at, stop.at)
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
	ctx.caret = -1
	ctx.display_valid = false
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

// Puts text in at the caret. See the header.
@(export)
mdcore_insert :: proc "c" (handle: rawptr, utf8: [^]u8, length: c.long) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	// From the look at the caret to the end of the change: no other
	// change of the source comes between.
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	if ctx.caret < 0 || length <= 0 {
		return
	}
	change_source_held(ctx, string(utf8[:length]), [2]int{ctx.caret, ctx.caret})
}

// Takes out the character before the caret. See the header.
@(export)
mdcore_delete_backward :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	sync.lock(&ctx.source_lock)
	defer sync.unlock(&ctx.source_lock)
	if ctx.caret < 0 || ctx.doc.count == 0 {
		return
	}
	// Nothing at the start of a block: to join it with the block before
	// is not a thing the core does yet.
	if start, end, ok := document.char_before(&ctx.doc, ctx.caret_places[:], ctx.caret_at); ok {
		change_source_held(ctx, "", [2]int{start, end})
	}
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

// See the header.
@(export)
mdcore_select_none :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	context.temp_allocator = ctx.temp
	hold(ctx)
	ctx.selection = {}
	show_selection(ctx)
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
	if !document.set_task_done(&ctx.doc, int(line), checked) {
		return false
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
