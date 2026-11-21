package mdcore

import "core:c"
import "base:runtime"
import CF "core:sys/darwin/CoreFoundation"
import CG "core:sys/darwin/CoreGraphics"
import CT "core:sys/darwin/CoreText"

SELECTION_COLOR :: Color{0, 122, 255, 64}

// One laid-out line, kept so the pointer can be mapped to a character.
Line_Rec :: struct {
	text:       ^Text,
	order:      int, // number of the text in layout order; the same after a resize
	line:       CT.LineRef,
	x, top:     f32, // points, document space
	width:      f32,
	start, end: int, // UTF-16 range in the text
}

Sel_Pos :: struct {
	order, index: int,
}

sel_less :: proc(a, b: Sel_Pos) -> bool {
	return a.order < b.order || (a.order == b.order && a.index < b.index)
}

sel_range :: proc(ctx: ^Ctx) -> (from, to: Sel_Pos, ok: bool) {
	if !ctx.has_sel || ctx.sel_anchor == ctx.sel_focus {
		return
	}
	from, to = ctx.sel_anchor, ctx.sel_focus
	if sel_less(to, from) {
		from, to = to, from
	}
	return from, to, true
}

free_lines :: proc(ctx: ^Ctx) {
	for l in ctx.lines {
		CF.Release(CF.TypeRef(l.line))
	}
	clear(&ctx.lines)
}

// The character nearest to a point in document space.
hit_test :: proc(ctx: ^Ctx, x, y: f32) -> (pos: Sel_Pos, ok: bool) {
	best := -1
	best_score: f32 = 1e30
	for l, i in ctx.lines {
		bottom := l.top + l.text.line_height
		dy := y < l.top ? l.top - y : (y >= bottom ? y - bottom : 0)
		dx := x < l.x ? l.x - x : (x > l.x + l.width ? x - (l.x + l.width) : 0)
		score := dy * 1000 + dx
		if score < best_score {
			best, best_score = i, score
		}
	}
	if best < 0 {
		return
	}
	l := ctx.lines[best]
	index := int(CT.LineGetStringIndexForPosition(l.line, CG.Point{f64(x - l.x), 0}))
	return Sel_Pos{l.order, clamp(index, l.start, l.end)}, true
}

// The part of a line that is inside the selection, as a UTF-16 range.
line_selection :: proc(l: Line_Rec, from, to: Sel_Pos) -> (s, e: int, ok: bool) {
	if l.order < from.order || l.order > to.order {
		return
	}
	s = l.order == from.order ? max(from.index, l.start) : l.start
	e = l.order == to.order ? min(to.index, l.end) : l.end
	return s, e, s < e
}

build_selection_rects :: proc(ctx: ^Ctx) {
	clear(&ctx.sel_rects)
	from, to, ok := sel_range(ctx)
	if !ok {
		return
	}
	scale := ctx.scale
	for l in ctx.lines {
		s, e := line_selection(l, from, to) or_continue
		x1 := f32(CT.LineGetOffsetForStringIndex(l.line, CF.Index(s), nil))
		x2 := f32(CT.LineGetOffsetForStringIndex(l.line, CF.Index(e), nil))
		if x2 < x1 {
			x1, x2 = x2, x1
		}
		append(
			&ctx.sel_rects,
			Instance {
				pos = {(l.x + x1) * scale, l.top * scale},
				size = {max(x2 - x1, 2) * scale, l.text.line_height * scale},
				color = SELECTION_COLOR,
				kind = 0,
			},
		)
	}
}

// Rebuilds the highlight quads and sends them to the GPU.
update_selection :: proc(ctx: ^Ctx) {
	build_selection_rects(ctx)
	gpu_upload_selection(ctx)
}

// phase 0 = mouse down, 1 = drag. x and y are points in document space.
@(export)
mdcore_mouse :: proc "c" (handle: rawptr, x, y: f64, phase: c.int) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	pos, ok := hit_test(ctx, f32(x), f32(y))
	if !ok {
		return
	}
	if phase == 0 {
		ctx.sel_anchor = pos
	}
	ctx.sel_focus = pos
	ctx.has_sel = true
	update_selection(ctx)
}

@(export)
mdcore_select_all :: proc "c" (handle: rawptr) {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	if len(ctx.lines) == 0 {
		return
	}
	last := ctx.lines[len(ctx.lines) - 1]
	ctx.sel_anchor = Sel_Pos{ctx.lines[0].order, ctx.lines[0].start}
	ctx.sel_focus = Sel_Pos{last.order, last.end}
	ctx.has_sel = true
	update_selection(ctx)
}

// The selected text as UTF-8. The pointer is valid until the next call.
@(export)
mdcore_selection_text :: proc "c" (handle: rawptr, length: ^c.long) -> [^]u8 {
	context = runtime.default_context()
	ctx := cast(^Ctx)handle
	clear(&ctx.clip)
	from, to, ok := sel_range(ctx)
	prev_order := -1
	if ok {
		for l in ctx.lines {
			s, e := line_selection(l, from, to) or_continue
			if prev_order >= 0 && prev_order != l.order {
				append(&ctx.clip, '\n')
			}
			prev_order = l.order
			str := CF.AttributedStringGetString(CF.AttributedStringRef(l.text.astr))
			old := len(ctx.clip)
			resize(&ctx.clip, old + (e - s) * 3)
			used: CF.Index
			CF.StringGetBytes(str, CF.Range{CF.Index(s), CF.Index(e - s)}, UTF8, '?', false, &ctx.clip[old], CF.Index((e - s) * 3), &used)
			resize(&ctx.clip, old + int(used))
		}
	}
	length^ = c.long(len(ctx.clip))
	return raw_data(ctx.clip)
}
