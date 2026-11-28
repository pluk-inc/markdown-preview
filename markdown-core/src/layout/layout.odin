// Layout: gives each block of a document a place on the page. It breaks the
// text into lines and records where each line and each decoration is. The
// display list (display.odin) and the selection (selection.odin) are made
// from these records, only for the part of the page that the view shows.
//
// The layout is made where the view is (`lay_out`), not from the first
// block down: a part of the document that nobody looked at has a height
// that is estimated from its text, and no records. So the first frame, a
// new width, and a jump to the end cost the work of what shows. A part
// that was laid out keeps its records; only the lines near the view keep
// their shaped text (window.odin).
//
// The records are kept for each part of the document by itself (`Part`),
// and every height in them counts from the top of that part. So the
// records of a part say nothing about the parts above it: when a block
// gets another height, only the tops of the parts below it change, not
// the records of each line of the rest of the document.
package layout

import "../base"
import "../document"
import "../text"
import "core:fmt"
import "core:math"
import "core:mem"

HEADING_LINE_HEIGHT :: 1.25
CODE_LINE_HEIGHT :: 1.3
CODE_PAD :: 16.0
// The corners of the card of a code block, as the card of the web
// renderer has them (`.md-code-wrap`).
CODE_RADIUS :: 16.0
CELL_PAD_X :: 12.0
CELL_PAD_Y :: 6.0

@(rodata)
HEADING_SCALE := [7]f32{1, 2, 1.692, 1.308, 1.154, 1, 0.846}

@(private)
Font_Kind :: enum {
	Regular,
	Bold,
	Italic,
	Bold_Italic,
	Semibold,
	Mono,
}

@(private)
Sized_Font :: struct {
	kind: Font_Kind,
	size: f32,
	font: base.Font,
}

// One laid-out text: a paragraph, a heading, a line of a code block, a
// table cell, or a list marker.
Para :: struct {
	handle:      ^text.Paragraph, // nil while it is released (window.odin), and for empty text
	src:         ^document.Text, // nil for a list marker, which cannot be selected
	block:       int, // of a list marker: the place in the part of the block that has its text
	base:        int, // byte offset of the paragraph in src
	len:         int, // bytes
	using look:  Text_Look,
}

Line :: struct {
	para:   int, // in the paragraphs of its part
	line:   text.Line,
	x, top: f32, // points; the top counts from the top of its part
}

// A background, a border, or a rule, in points. y counts from the top of
// its part.
Decor :: struct {
	x, y, w, h: f32,
	color:      base.Color,
	radius:     f32,
	// For a mark that stands beside text (the bullet of a list item):
	// how far below y the line is that the text stands on; 0 for each
	// other record. The text is drawn from the whole pixel of that
	// line, so the mark is too: at the same distance from it in each
	// line, and of the same size, in whole pixels (`mark_quad`). From
	// y, so a record that moves down the page needs no other change.
	to_baseline: f32,
	above:      bool, // a line through text: drawn over the selection, as the text is
	soft_done:  bool, // of text that is softer in a checked task (`done_color`)
}

// The place of one block and the range of its records in its part. The
// top and the bottom count from the top of the part.
Box :: struct {
	top, bottom:             f32,
	line_first, line_end:    int,
	decor_first, decor_end:  int,
	para_first, para_end:    int,
}

// The records of the blocks of one part of the document
// (`document.Part`), in the order of the blocks. Part n of a layout is of
// part n of its document, and box n of a part is the place of block n of
// that part. The parts go down the page with no room between them: the
// space above a block is in the part of that block.
//
// A layout has a part for each part of its document from the start. A
// part that is not laid out has no records, and its height is estimated.
// A part can be laid out down to one of its blocks only; the rest of its
// height is then estimated. The records of a part are in one piece of
// memory of their exact size, but for the one part that the layout works
// on (`Layout.open`): its records are in arrays of the layout that grow
// (`Layout.work`), and the part shows what they have now.
//
// A record can reach out of its part by less than `OVERHANG`: above the
// top (the marker of a list item that starts with a rule stands a little
// above its block), and below the end (the check box of a task is higher
// than a line with a small line spacing).
Part :: struct {
	top:         f64, // of the part on the page, points
	height:      f32, // what is laid out, and an estimate for the rest
	paras:       []Para,
	lines:       []Line,
	decor:       []Decor,
	boxes:       []Box, // do not overlap and go down the page
	tasks:       []Task, // down the page
	memory:      rawptr, // of the records, while the layout does not work on the part
	// How far the layout of the part is.
	complete:    bool, // each block has all its records
	in_block:    bool, // the last box is of a block in progress (a long code block)
	code_offset: int, // of that block: the byte offset of its next line
	y:           f32, // the bottom of what is laid out
	rest:        f32, // the estimated height of the blocks that have no box yet
	block_rest:  f32, // the estimated height of the block in progress, at its start
	live_first:  int, // all lines with shaped text are in [live_first, live_end)
	live_end:    int,
}

// How far out of its part a record can reach at most, in points.
OVERHANG :: 64.0

// The records of the part that the layout works on. They are used again
// for each part, so a part costs one allocation, not the steps of five
// arrays that grow.
@(private)
Work :: struct {
	paras: [dynamic]Para,
	lines: [dynamic]Line,
	decor: [dynamic]Decor,
	boxes: [dynamic]Box,
	tasks: [dynamic]Task,
}

Layout :: struct {
	doc:            ^document.Document,
	style:          base.Style,
	m:              base.Metrics,
	// A part for each part of the document, in document order.
	parts:          [dynamic]Part,
	// The top of the page. A part above the view that gets its real
	// height moves this, and not the text that the view shows: the
	// heights of the page that a host has stay true. A new layout
	// (`begin`) keeps it too, and `restore_place` moves it for the place
	// of the reader.
	origin:         f64,
	content_height: f64,
	// The part whose records are in `work`, or -1. The three values after
	// it are of that part, and of its block in progress.
	open:           int,
	work:           Work,
	// Room for the records below a change, while the changed blocks are
	// laid out (`remake_blocks`). Empty at each other time.
	below:          Work,
	code_offset:    int,
	in_block:       bool,
	y:              f32, // from the top of the open part
	// The range of the page that keeps its shaped text (window.odin).
	keep_y0:        f64,
	keep_y1:        f64,
	column_x:       f32,
	column:         f32,
	fonts:          [dynamic]Sized_Font,
	panel:          Panel, // of front matter, above the first part (panel.odin)
}

// Starts a new layout of `doc` for a view of `width` points. The records of
// the layout before it are freed.
begin :: proc(l: ^Layout, doc: ^document.Document, style: base.Style, width: f32) {
	reset(l)
	for f in l.fonts {
		text.font_release(f.font)
	}
	clear(&l.fonts)
	l.doc = doc
	l.style = style
	l.m = base.metrics(style)
	l.column = width - 2 * l.m.page_pad
	if l.m.column > 0 {
		l.column = min(l.column, l.m.column)
	}
	l.column_x = math.floor((width - l.column) / 2)
	// The inset makes the text narrower and leaves the column where it is.
	inset := min(l.m.inset, max((l.column - 100) / 2, 0))
	l.column_x += inset
	l.column -= 2 * inset
	l.keep_y0, l.keep_y1 = 0, 1e30
	panel_begin(l, true)
	if doc != nil {
		for _, p in doc.parts {
			append(&l.parts, part_new(l, p))
		}
	}
	sum_tops(l)
}

// The records of a part of the document that is not laid out: none, and
// a height that is estimated.
@(private)
part_new :: proc(l: ^Layout, part: int) -> Part {
	start := part_start(l, part)
	rest := estimate(l, part, 0)
	return {height = start + rest, y = start, rest = rest}
}

// After a change of the document (`document.commit`): the parts that
// were made again get parts with no records and an estimated height. The
// records of each other part stay, also of the parts below the change,
// which are at another height of the page after it. A change that made
// no part again (as many blocks as before) makes only the records of its
// blocks again (`remake_blocks`). The top of the page
// stays; the owner puts the reader's place back after it
// (`restore_place`).
apply_change :: proc(l: ^Layout, change: document.Change) {
	// Front matter that changed is another panel: the parts are at other
	// heights of the page.
	panel_changed := panel_begin(l)
	defer if panel_changed {
		sum_tops(l)
	}
	if change.parts_removed == 0 && change.parts_added == 0 {
		// The blocks of the range are at the places of the blocks
		// before: only their records are made again.
		for block := change.first; block < change.first + change.added; {
			p, slot := document.locate(l.doc, block)
			count := min(change.first + change.added - block, l.doc.parts[p].count - slot)
			remake_blocks(l, p, slot, count)
			block += count
		}
		if change.added > 0 {
			sum_tops(l)
			when ODIN_DEBUG {
				problem := check(l)
				assert(problem == "", problem)
			}
		}
		return
	}
	// The numbers of the parts are other ones after it.
	close_part(l)
	first := change.part_first
	for &part in l.parts[first:][:change.parts_removed] {
		part_destroy(&part)
	}
	remove_range(&l.parts, first, first + change.parts_removed)
	for p in first ..< first + change.parts_added {
		inject_at(&l.parts, p, part_new(l, p))
	}
	sum_tops(l)
	when ODIN_DEBUG {
		problem := check(l)
		assert(problem == "", problem)
	}
}

// The y that the first block of a part starts at: the page has room above
// its first block.
@(private)
part_start :: proc(l: ^Layout, part: int) -> f32 {
	return part == 0 ? l.m.page_pad * TOP_PAD : 0
}

TOP_PAD :: 0.6 // the room above the first block, in page paddings

// Gives each part its top from the heights of the parts above it, and
// the page its height.
@(private)
sum_tops :: proc(l: ^Layout) {
	// The panel of front matter is above the first part.
	top := l.origin + f64(l.panel.height)
	for &part in l.parts {
		part.top = top
		top += f64(part.height)
	}
	if len(l.parts) == 0 {
		top += f64(l.m.page_pad * TOP_PAD)
		// Below a panel, the line of the caret of a document with no
		// block is in the page: a panel higher than the view would
		// leave it below the end of the page, where no scroll goes.
		if l.panel.height > 0 {
			top += f64(text_line_height(l, nil) + l.m.page_pad)
		}
	} else {
		top += f64(l.m.page_pad)
	}
	l.content_height = top - l.origin
}

// The part whose records are in work.
@(private)
open_part :: proc(l: ^Layout) -> ^Part {
	return &l.parts[l.open]
}

// Shows the records in work as the ones of the open part. `advance`
// calls it after each block: an array that grows moves.
@(private)
show_work :: proc(l: ^Layout) {
	part := open_part(l)
	part.paras, part.lines, part.decor = l.work.paras[:], l.work.lines[:], l.work.decor[:]
	part.boxes, part.tasks = l.work.boxes[:], l.work.tasks[:]
}

// Ends the work on the open part: its records go from the arrays that
// grow into one piece of memory of their exact size.
@(private)
close_part :: proc(l: ^Layout) {
	take :: proc(memory: ^[]u8, records: ^[dynamic]$T) -> []T {
		bytes := len(records) * size_of(T)
		out := mem.slice_data_cast([]T, memory[:bytes])
		copy(out, records[:])
		memory^ = memory[bytes:]
		clear(records)
		return out
	}
	if l.open < 0 {
		return
	}
	part := open_part(l)
	work := &l.work
	bytes :=
		len(work.paras) * size_of(Para) +
		len(work.lines) * size_of(Line) +
		len(work.boxes) * size_of(Box) +
		len(work.tasks) * size_of(Task) +
		len(work.decor) * size_of(Decor)
	// The kinds with the largest alignment first, so each kind starts at
	// an address that it can have.
	#assert(align_of(Para) == 8 && align_of(Line) == 8 && align_of(Box) == 8 && align_of(Task) == 8 && align_of(Decor) <= 8)
	memory, _ := mem.alloc_bytes_non_zeroed(bytes, 8)
	part.memory = raw_data(memory)
	part.paras = take(&memory, &work.paras)
	part.lines = take(&memory, &work.lines)
	part.boxes = take(&memory, &work.boxes)
	part.tasks = take(&memory, &work.tasks)
	part.decor = take(&memory, &work.decor)
	l.open = -1
}

// Makes a part the open one: its records, if it has some, go into the
// arrays that grow, and the layout goes on where it was.
@(private)
open_for_work :: proc(l: ^Layout, index: int) {
	if l.open == index {
		return
	}
	close_part(l)
	l.open = index
	part := open_part(l)
	work := &l.work
	append(&work.paras, ..part.paras)
	append(&work.lines, ..part.lines)
	append(&work.boxes, ..part.boxes)
	append(&work.tasks, ..part.tasks)
	append(&work.decor, ..part.decor)
	free(part.memory)
	part.memory = nil
	show_work(l)
	l.in_block, l.code_offset, l.y = part.in_block, part.code_offset, part.y
}

@(private)
work_delete :: proc(work: ^Work) {
	delete(work.paras)
	delete(work.lines)
	delete(work.decor)
	delete(work.boxes)
	delete(work.tasks)
	work^ = {}
}

@(private)
work_clear :: proc(work: ^Work) {
	clear(&work.paras)
	clear(&work.lines)
	clear(&work.decor)
	clear(&work.boxes)
	clear(&work.tasks)
}

@(private)
part_destroy :: proc(part: ^Part) {
	for line in part.lines {
		text.line_destroy(line.line)
	}
	for para in part.paras {
		text.paragraph_destroy(para.handle)
	}
	free(part.memory)
}

@(private)
reset :: proc(l: ^Layout) {
	for &part in l.parts {
		// The records of the open part are in work, which is not the
		// part's to free.
		part_destroy(&part)
	}
	clear(&l.parts)
	work_clear(&l.work)
	l.open = -1
	l.content_height = 0
}

destroy :: proc(l: ^Layout) {
	reset(l)
	panel_destroy(l)
	for f in l.fonts {
		text.font_release(f.font)
	}
	delete(l.fonts)
	delete(l.parts)
	work_delete(&l.work)
	work_delete(&l.below)
	l^ = {}
}

// True when each part of the document has all its records.
done :: proc(l: ^Layout) -> bool {
	for part in l.parts {
		if !part.complete {
			return false
		}
	}
	return true
}

// The font of one kind at one size, made once for a layout.
@(private)
font :: proc(l: ^Layout, kind: Font_Kind, size: f32) -> base.Font {
	for f in l.fonts {
		if f.kind == kind && f.size == size {
			return f.font
		}
	}
	face: base.Font
	switch kind {
	case .Regular, .Italic:
		face = l.style.body_font
	case .Bold, .Bold_Italic:
		face = l.style.bold_font
	case .Semibold:
		face = l.style.heading_font
	case .Mono:
		face = l.style.code_font
	}
	sized := text.font_sized(face, size, kind == .Italic || kind == .Bold_Italic)
	append(&l.fonts, Sized_Font{kind, size, sized})
	return sized
}

@(private)
span_font :: proc(l: ^Layout, style: document.Inline_Set, size: f32, heading: bool) -> base.Font {
	if .Code in style {
		return font(l, .Mono, size * 0.9)
	}
	// The number of a footnote: small, and raised (`NOTE_RAISE`).
	if .Note in style {
		return font(l, .Regular, size * NOTE_SIZE)
	}
	bold := .Bold in style
	italic := .Italic in style || .Image in style
	switch {
	case italic && (bold || heading):
		return font(l, .Bold_Italic, size)
	case bold:
		return font(l, .Bold, size)
	case heading:
		return font(l, .Semibold, size)
	case italic:
		return font(l, .Italic, size)
	}
	return font(l, .Regular, size)
}

// The width that a page is laid out and drawn in, for a view of
// `view_width` whose host wants the page in its left `wanted` points
// (0: all of the view). Not wider than the view.
page_width :: proc(view_width, wanted: f32) -> f32 {
	return wanted > 0 ? min(wanted, view_width) : view_width
}

// The color of the text of a checked task: softer, with no line through
// it, so a long list stays easy to read.
done_color :: proc(l: ^Layout) -> base.Color {
	return mix(l.style.secondary, l.style.text, 0.3)
}

// The color of the text of a span. `done`: its block stands in a checked
// task item. The state is read from the document when the page is drawn,
// not kept in the layout, so a task that is checked needs no new layout.
NOTE_SIZE :: 0.72 // of the number of a footnote in the text, in sizes of the text
NOTE_RAISE :: 0.36 // how far its baseline is above the one of the text, in sizes of the text

span_color :: proc(l: ^Layout, para: ^Para, style: document.Inline_Set, done: bool) -> base.Color {
	// A mark of the source that shows at the caret.
	if .Mark in style {
		return l.style.secondary
	}
	if .Link in style || .Note in style {
		return l.style.link
	}
	if done && !para.quote && .Image not_in style {
		return done_color(l)
	}
	if para.quote || .Image in style {
		return l.style.secondary
	}
	return l.style.text
}

@(private)
push_decor :: proc(l: ^Layout, x, y, w, h: f32, color: base.Color, radius: f32 = 0) {
	append(&l.work.decor, Decor{x = x, y = y, w = w, h = h, color = color, radius = radius})
}

Text_Look :: struct {
	size:        f32,
	line_height: f32,
	heading:     bool, // the base weight is semibold
	mono:        bool, // a line of a code block
	quote:       bool,
}

// The place of the check box of a task item. The layout draws nothing
// there: the host puts its own control on it (`tasks_between`). The line
// of the task and its state are in the block.
Task :: struct {
	x, y:  f32, // points, y from the top of its part; the side is `task_box_size`
	block: int, // its place in the part
}

TASK_BOX :: 1.0 // side of a task box, in body sizes
TASK_GAP :: 0.4 // between the box and the text

// Makes the paragraph of the bytes [from, to) of `src` in the open part
// and returns its index in the paragraphs of that part.
@(private)
make_para :: proc(l: ^Layout, src: ^document.Text, from, to: int, look: Text_Look) -> int {
	paras := &l.work.paras
	append(
		paras,
		Para {
			src = src,
			base = from,
			len = to - from,
			look = look,
		},
	)
	shape_para(l, l.open, &paras[len(paras) - 1])
	return len(paras) - 1
}

// Makes the shaped text of a paragraph of a part from its record.
@(private)
shape_para :: proc(l: ^Layout, part: int, para: ^Para) {
	if para.len == 0 {
		return
	}
	if para.src == nil {
		shape_marker(l, para, marker_text(&l.doc.parts[part].blocks[para.block]))
		return
	}
	from, to := para.base, para.base + para.len
	runs := make([dynamic]text.Run, 0, 8, context.temp_allocator)
	if para.mono {
		append(&runs, text.Run{0, to - from, font(l, .Mono, para.size)})
	} else {
		for span in para.src.spans {
			if span.end <= from {
				continue
			}
			if span.start >= to {
				break
			}
			append(&runs, text.Run{max(span.start, from) - from, min(span.end, to) - from, span_font(l, span.style, para.size, para.heading)})
		}
	}
	para.handle = text.paragraph_create(string(para.src.bytes[from:to]), runs[:])
}

@(private)
shape_marker :: proc(l: ^Layout, para: ^Para, label: string) {
	runs := [1]text.Run{{0, len(label), font(l, .Regular, para.size)}}
	para.handle = text.paragraph_create(label, runs[:])
}

// Breaks a paragraph of the open part into lines of `width` at (x, y).
// Returns the y below the last line.
@(private)
place_para :: proc(l: ^Layout, index: int, x, y, width: f32, align := base.Align.Left) -> f32 {
	para := &l.work.paras[index]
	if para.len == 0 {
		return y + para.line_height
	}
	y := y
	start := 0
	for {
		line := text.paragraph_next_line(para.handle, start, max(width, 20)) or_break
		lx := x
		switch align {
		case .Left:
		case .Center:
			lx += (width - line.width) / 2
		case .Right:
			lx += width - line.width
		}
		append(&l.work.lines, Line{index, line, lx, y})
		if para.src != nil {
			decorate_line(l, para, line, lx, y)
		}
		y += para.line_height
		start = line.end
	}
	return y
}

// The backgrounds of inline code and the lines through struck text.
@(private)
decorate_line :: proc(l: ^Layout, para: ^Para, line: text.Line, x, top: f32) {
	src := para.src
	if len(src.spans) == 0 {
		return
	}
	line_start, line_end := para.base + line.start, para.base + line.end
	// Spans are in text order: start at the first one that reaches the line.
	for span in src.spans[document.span_index(src, line_start):] {
		if span.start >= line_end {
			break
		}
		if span.end <= line_start || span.style & {.Code, .Strike} == {} {
			continue
		}
		x1 := x + text.line_x_for_index(line, max(span.start, line_start) - para.base)
		x2 := x + text.line_x_for_index(line, min(span.end, line_end) - para.base)
		if .Code in span.style {
			h := para.size * 1.3
			y := top + (para.line_height - h) / 2
			push_decor(l, x1 - 3.5, y - 0.5, x2 - x1 + 7, h + 1, l.style.code_border, 5)
			push_decor(l, x1 - 3, y, x2 - x1 + 6, h, l.style.code_background, 4.5)
		}
		if .Strike in span.style {
			thickness := max(1, math.round(para.size / 14))
			y := top + para.line_height / 2 + para.size * 0.08
			// The color of the text. Where that is softer in a checked
			// task, the display takes it from the state of the block.
			color := span_color(l, para, span.style, false)
			soft := span_color(l, para, span.style, true) != color
			append(&l.work.decor, Decor{x = x1, y = y, w = x2 - x1, h = thickness, color = color, above = true, soft_done = soft})
		}
	}
}

@(private)
marker_text :: proc(b: ^document.Block) -> string {
	#partial switch b.marker {
	case .Number:
		return fmt.tprintf("%d.", b.number)
	case .Note:
		// The number of the footnote; none for a footnote that no text
		// refers to.
		if b.number > 0 {
			return fmt.tprintf("%d.", b.number)
		}
	}
	// A bullet is a circle and a task a box, with no text
	// (`place_marker`).
	return ""
}

// The circle of a bullet, in sizes of the body text: how far across it
// is (a quarter of the size of the text, as the bullet of a text font),
// and how far it stands in from the edge of the step of its list, at
// about the middle of where the "-" of a list line is drawn in an editor
// that keeps it (a step of 0.75, and half of the "-").
BULLET_SIZE :: 0.25
BULLET_IN :: 0.8
// The width that the number of an item has room in, left of its text, in
// body sizes: more than a number of many digits needs, so it is one line.
NUMBER_ROOM :: 6.0
// The room between the number of an item and its text, in body sizes.
BULLET_GAP :: 0.35
// Where the middle of a bullet or of a check box is above the line
// that the text stands on, in heights of the small letters: where the
// bullet of a font has its middle, a little above the middle of those
// letters. The middle of the line box is higher (near the middle of
// the capital letters), and a mark there looks too high beside small
// letters.
MARKER_MIDDLE :: 0.6

// The height of the middle of the mark of a list item (`MARKER_MIDDLE`)
// in a line at `y` with text of a font, and the line that the text
// stands on. With no font, the middle of the line and no line of text:
// a mark beside a block with no text (a rule).
@(private)
marker_middle :: proc(y, line_height: f32, text_font: base.Font) -> (middle, baseline: f32) {
	if text_font == nil {
		return y + line_height / 2, 0
	}
	ascent, descent, x_height := text.font_metrics(text_font)
	baseline = line_baseline(y, line_height, ascent, descent)
	return baseline - MARKER_MIDDLE * x_height, baseline
}

// The line that text stands on in a line of the page at `top`: the
// height of the font is in the middle of the height of the line.
line_baseline :: proc(top, line_height, ascent, descent: f32) -> f32 {
	return top + (line_height - (ascent + descent)) / 2 + ascent
}

// Part `t` of the way from one color to another.
@(private)
mix :: proc(a, b: base.Color, t: f32) -> base.Color {
	lerp :: proc(x, y: u8, t: f32) -> u8 {
		return u8(math.round(f32(x) + (f32(y) - f32(x)) * t))
	}
	return {lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t), lerp(a.a, b.a, t)}
}

// The side of a task's check box, in points.
task_box_size :: proc(m: base.Metrics) -> f32 {
	return math.round(m.body * TASK_BOX)
}

// Keeps the place of the check box of a task item: left of x, at the
// height of a bullet in its first line (`marker_middle`).
@(private)
place_task :: proc(l: ^Layout, b: ^document.Block, x, y, line_height: f32, text_font: base.Font) {
	size := task_box_size(l.m)
	bx := math.round(x - l.m.body * TASK_GAP - size)
	// Not on a whole point here: that is a point of the page, and y is
	// from the top of the part (`tasks_between`).
	middle, _ := marker_middle(y, line_height, text_font)
	by := middle - size / 2
	append(&l.work.tasks, Task{bx, by, len(l.work.boxes) - 1})
}

// The bullet, number, or box of a list item, left of x. The bullet stands
// a little in from the edge of the step of its list (`BULLET_IN`); a "-"
// that is being typed is text at that edge (`list_x`), so the space that
// makes it a list item moves it in by that much, once.
// `text_font`: the font of the text of the first line of the item, or
// nil for a block with no text (a rule).
@(private)
place_marker :: proc(l: ^Layout, b: ^document.Block, x, y, line_height: f32, text_font: base.Font) {
	if b.marker == .Task_Open || b.marker == .Task_Done {
		place_task(l, b, x, y, line_height, text_font)
		return
	}
	// A mark that is being typed is the text of the block: no item yet.
	if b.typed {
		return
	}
	if b.marker == .Bullet {
		// A circle, not the bullet of the font: that one is a fifth of
		// the size of the text in the system font, and each font has
		// its own. In the color of the text of the item: softer in a
		// quote.
		across := BULLET_SIZE * l.m.body
		middle, baseline := marker_middle(y, line_height, text_font)
		top := middle - across / 2
		append(&l.work.decor, Decor {
			x           = x - l.m.list_indent + BULLET_IN * l.m.body,
			y           = top,
			w           = across,
			h           = across,
			color       = b.quote_depth > 0 ? l.style.secondary : l.style.text,
			radius      = across / 2,
			to_baseline = text_font != nil ? baseline - top : 0,
		})
		return
	}
	label := marker_text(b)
	if label == "" {
		return
	}
	paras := &l.work.paras
	append(paras, Para{block = len(l.work.boxes) - 1, len = len(label), size = l.m.body, line_height = line_height, quote = b.quote_depth > 0})
	shape_marker(l, &paras[len(paras) - 1], label)
	// Right-aligned to the text, in one line: a number of more digits
	// ("123.") goes further left, into the edge of the step, and never
	// breaks into a second line.
	room := NUMBER_ROOM * l.m.body
	place_para(l, len(paras) - 1, x - BULLET_GAP * l.m.body - room, y, room, .Right)
}

@(private)
space_above :: proc(l: ^Layout, b: ^document.Block, heading_size: f32) -> f32 {
	switch b.spacing {
	case .List_Start:
		return l.m.paragraph
	case .Item:
		return l.m.list_item
	case .Continuation:
		return l.m.list_item * 2
	case .Block:
	}
	#partial switch b.kind {
	case .Heading:
		return 0.6 * l.m.body + 0.5 * heading_size
	case .Table:
		return l.m.large_block
	}
	return l.m.paragraph
}

// The room of one empty paragraph: the space above a paragraph, and a
// line of body text.
@(private)
empty_height :: proc(l: ^Layout) -> f32 {
	return l.m.paragraph + math.round(l.m.body * l.m.line_height)
}

// The height of a block that is not laid out, with the space above it:
// from the size of its text, with no shaping.
@(private)
estimate_block :: proc(l: ^Layout, b: ^document.Block, first: bool) -> f32 {
	// The mean width of a character, in sizes of its font.
	CHAR :: 0.5
	MONO_CHAR :: 0.6
	x := list_x(l, b) + f32(b.quote_depth) * l.m.quote_indent
	width := max(l.column - x, 20)
	size := l.m.body * HEADING_SCALE[b.kind == .Heading ? b.level : 0]
	height: f32
	switch b.kind {
	case .Paragraph, .Heading:
		line := text_line_height(l, b)
		lines := math.ceil(f32(len(b.text.bytes)) * CHAR * size / width)
		height = max(lines, 1) * line
	case .Code:
		line := math.round(l.m.code_size * CODE_LINE_HEIGHT)
		per_line := max(width - 2 * CODE_PAD, 20) / (MONO_CHAR * l.m.code_size)
		lines, run: f32
		for c in b.text.bytes {
			if c == '\n' {
				lines += max(math.ceil(run / per_line), 1)
				run = 0
			} else {
				run += 1
			}
		}
		lines += max(math.ceil(run / per_line), 1)
		height = lines * line + 2 * CODE_PAD
	case .Rule:
		height = 1
	case .Table:
		rows := b.columns > 0 ? len(b.cells) / b.columns : 0
		height = f32(rows) * (math.round(l.m.body * l.m.line_height) + 2 * CELL_PAD_Y)
	}
	// The lines of its empty paragraphs.
	height += f32(b.empties) * empty_height(l)
	return height + (first ? 0 : space_above(l, b, size))
}

// The estimated height of the blocks of a part from one of them on.
@(private)
estimate :: proc(l: ^Layout, part, from: int) -> (height: f32) {
	blocks := document.part_blocks(l.doc.parts[part])
	for &b, slot in blocks[min(from, len(blocks)):] {
		height += estimate_block(l, &b, part == 0 && from + slot == 0)
	}
	return
}

// How far the text of a block stands in from the column for its lists.
// A mark that is being typed at the caret (`Shape.typed`) is no list
// item yet: it stands at the edge of the step, where its line starts, and
// moves in only at the space that makes it a list item.
list_x :: proc(l: ^Layout, b: ^document.Block) -> f32 {
	depth := b.typed ? b.list_depth - 1 : b.list_depth
	return f32(max(depth, 0)) * l.m.list_indent
}

// The bars at the left of a block in a quote, one for each level.
@(private)
push_quote_bars :: proc(l: ^Layout, b: ^document.Block, top, height: f32) {
	for depth in 0 ..< b.quote_depth {
		bar_x := l.column_x + list_x(l, b) + f32(depth) * l.m.quote_indent
		push_decor(l, bar_x, top, 3, height, l.style.quote_bar, 1.5)
	}
}

// How many blocks of a part have all their records.
@(private)
blocks_done :: proc(part: ^Part) -> int {
	// The block in progress has its box already.
	return part.in_block ? len(part.boxes) - 1 : len(part.boxes)
}

// Lays out blocks of a part, from where its layout is, until the part
// has records down to `until` (from its top) and for the block
// `until_slot`. Returns true when it made records. The caller sums the
// tops again.
@(private)
advance :: proc(l: ^Layout, index: int, until: f32, until_slot: int) -> bool {
	{
		// Nothing to do for a part that has what the caller wants: no
		// records are moved for it.
		part := &l.parts[index]
		if part.complete || (part.y >= until && blocks_done(part) > until_slot) {
			return false
		}
	}
	open_for_work(l, index)
	defer free_all(context.temp_allocator)
	blocks := l.doc.parts[index]
	work := &l.work
	progressed := false
	for {
		// The block in progress has its box already.
		slot := l.in_block ? len(work.boxes) - 1 : len(work.boxes)
		if slot >= blocks.count || (l.y >= until && slot > until_slot) {
			break
		}
		progressed = true
		b := &blocks.blocks[slot]
		new_lines := len(work.lines)
		x := l.column_x + list_x(l, b) + f32(b.quote_depth) * l.m.quote_indent
		width := l.column - (x - l.column_x)
		heading_size := l.m.body * HEADING_SCALE[b.kind == .Heading ? b.level : 0]

		if !l.in_block {
			// The first block of the document has no space above it.
			if index > 0 || slot > 0 {
				l.y += space_above(l, b, heading_size)
			}
			// The block has a box from here on: its estimate goes out of
			// the rest of the part. The estimate of a block is made one
			// time for the first height of the part and one time here.
			part := open_part(l)
			part.block_rest = estimate_block(l, b, index == 0 && slot == 0)
			part.rest -= part.block_rest
			append(&work.boxes, Box{top = l.y, bottom = l.y, line_first = len(work.lines), decor_first = len(work.decor), para_first = len(work.paras)})
			l.in_block = true
			l.code_offset = 0
			// The marker of a list item stands at the first line of its
			// first block, whatever the kind of the block.
			body_line := math.round(l.m.body * l.m.line_height)
			switch b.kind {
			case .Paragraph:
				place_marker(l, b, x, l.y, body_line, block_font(l, b))
			case .Heading:
				place_marker(l, b, x, l.y, text_line_height(l, b), block_font(l, b))
			case .Code:
				// The card and the quote bars are there from the first
				// line and grow with the block: a long one can stay in
				// progress while the reader is in it. They are the first
				// records of the box, so the marker comes after them.
				push_decor(l, x - 0.5, l.y - 0.5, width + 1, 0, l.style.code_border, CODE_RADIUS + 0.5)
				push_decor(l, x, l.y, width, 0, l.style.code_background, CODE_RADIUS)
				push_quote_bars(l, b, l.y, 0)
				place_marker(l, b, x, l.y + CODE_PAD, math.round(l.m.code_size * CODE_LINE_HEIGHT), block_font(l, b))
			case .Table:
				// The first row of a table is its header.
				place_marker(l, b, x, l.y + CELL_PAD_Y, body_line, span_font(l, {}, l.m.body, true))
			case .Rule:
				place_marker(l, b, x, l.y - body_line / 2, body_line, nil)
			}
		}
		box := &work.boxes[slot]
		finished := true

		switch b.kind {
		case .Paragraph, .Heading:
			look := Text_Look {
				size        = heading_size,
				line_height = text_line_height(l, b),
				heading     = b.kind == .Heading,
				quote       = b.quote_depth > 0,
			}
			para := make_para(l, &b.text, 0, len(b.text.bytes), look)
			l.y = place_para(l, para, x, l.y, width)
		case .Code:
			// All of a block that the caller wants to its end.
			finished = place_code(l, b, x, width, slot <= until_slot ? max(f32) : until)
			// Down to the padding below the last line that is there.
			bottom := l.y + CODE_PAD
			work.decor[box.decor_first].h = bottom - box.top + 1
			for &d in work.decor[box.decor_first + 1:][:1 + b.quote_depth] {
				d.h = bottom - box.top
			}
			if finished {
				l.y = bottom
			}
		case .Rule:
			push_decor(l, x, l.y, width, 1, l.style.rule)
			l.y += 1
		case .Table:
			l.y = place_table(l, b, x, l.y, width)
		}

		if finished {
			if b.kind != .Code {
				push_quote_bars(l, b, box.top, l.y - box.top)
			}
			l.in_block = false
			// Each empty paragraph after the block has a line of its
			// own at the bottom of the box of the block, where a caret
			// can be.
			l.y += f32(b.empties) * empty_height(l)
		}
		box.bottom = l.y
		box.line_end = len(work.lines)
		box.decor_end = len(work.decor)
		box.para_end = len(work.paras)
		show_work(l)
		part := open_part(l)
		// The new lines keep their shaped text only inside the window.
		if first, end := trim(l, part, new_lines, len(part.lines)); first < end {
			note_live(part, first, end)
		}
	}
	if !progressed {
		return false
	}
	end_work(l)
	return true
}

// After work on the open part: the part has how far its layout is and
// its height, and a part with all its blocks is closed.
@(private)
end_work :: proc(l: ^Layout) {
	part := open_part(l)
	blocks := l.doc.parts[l.open]
	work := &l.work
	part.y, part.in_block, part.code_offset = l.y, l.in_block, l.code_offset
	if !l.in_block && len(work.boxes) == blocks.count {
		part.height = l.y
		part.complete = true
		close_part(l)
	} else {
		// What is laid out, and an estimate for the rest: of the blocks
		// with no box, and of the block in progress.
		part.complete = false
		part.height = l.y + max(part.rest, 0)
		if l.in_block {
			// What is left of a code block: of its first estimate, the
			// share of the bytes that have no line yet. No look at the
			// bytes again: a long block is laid out in many calls.
			bytes := len(blocks.blocks[len(work.boxes) - 1].text.bytes)
			part.height += part.block_rest * f32(max(bytes - l.code_offset, 0)) / f32(max(bytes, 1))
		}
	}
}

// Some blocks of a part got other content at their place in memory
// (`document.commit`, for as many blocks as before): `count` blocks from
// the block `first` of the part on. The records of the other blocks of
// the part stay. The ones below the change move by what the new text is
// higher. The caller sums the tops again.
@(private)
remake_blocks :: proc(l: ^Layout, index, first, count: int) {
	if first >= len(l.parts[index].boxes) {
		// No records of them: the part has another estimate. Not
		// through `end_work` for a part with no records at all, which
		// stays closed.
		part := &l.parts[index]
		part.rest = estimate(l, index, len(part.boxes))
		if len(part.boxes) == 0 {
			part.height = part.y + part.rest
		} else {
			open_for_work(l, index)
			end_work(l)
		}
		return
	}
	open_for_work(l, index)
	part := open_part(l)
	work, below := &l.work, &l.below
	// The layout of the part as it was.
	was := part^
	a := work.boxes[first]
	above := first > 0 ? work.boxes[first - 1].bottom : part_start(l, index)
	// The records below the changed blocks stay when the layout of the
	// part was past those blocks. If not (the change is in the block
	// that the layout was at, or reaches blocks with no records), the
	// part keeps its records down to the change.
	stays := first + count <= blocks_done(part)
	b := stays ? work.boxes[first + count - 1] : work.boxes[len(work.boxes) - 1]
	for line in work.lines[a.line_first:b.line_end] {
		text.line_destroy(line.line)
	}
	for para in work.paras[a.para_first:b.para_end] {
		text.paragraph_destroy(para.handle)
	}
	// The tasks go down the blocks.
	tasks, tasks_end := 0, 0
	for tasks < len(work.tasks) && work.tasks[tasks].block < first {
		tasks += 1
	}
	for tasks_end = tasks; tasks_end < len(work.tasks) && work.tasks[tasks_end].block < first + count; {
		tasks_end += 1
	}
	if stays {
		// Out of the way of the layout of the changed blocks, which
		// puts its records at the end.
		append(&below.boxes, ..work.boxes[first + count:])
		append(&below.lines, ..work.lines[b.line_end:])
		append(&below.decor, ..work.decor[b.decor_end:])
		append(&below.paras, ..work.paras[b.para_end:])
		append(&below.tasks, ..work.tasks[tasks_end:])
	}
	resize(&work.boxes, first)
	resize(&work.lines, a.line_first)
	resize(&work.decor, a.decor_first)
	resize(&work.paras, a.para_first)
	resize(&work.tasks, tasks)
	show_work(l)
	l.y, l.in_block, l.code_offset = above, false, 0
	// The lines that can have shaped text: the ones above the change now,
	// then the new ones, then the ones below.
	part.live_first, part.live_end = min(was.live_first, a.line_first), min(was.live_end, a.line_first)
	if !stays {
		part.rest = estimate(l, index, first)
		end_work(l)
		return
	}
	// The layout of the part is above the changed blocks for a moment.
	// `advance` takes each block that it lays out from the estimate of
	// what is left of the part; these were not in it.
	part.y, part.in_block, part.complete = above, false, false
	advance(l, index, 0, first + count - 1)
	if l.open != index {
		// The changed blocks were the last ones: the part is complete.
		return
	}
	part = open_part(l)
	part.rest, part.block_rest = was.rest, was.block_rest
	// The records below again, after the new ones, each as much lower
	// as the changed blocks are higher.
	down := l.y - b.bottom
	boxes, lines, decor, paras := len(work.boxes), len(work.lines), len(work.decor), len(work.paras)
	tasks = len(work.tasks)
	append(&work.boxes, ..below.boxes[:])
	append(&work.lines, ..below.lines[:])
	append(&work.decor, ..below.decor[:])
	append(&work.paras, ..below.paras[:])
	append(&work.tasks, ..below.tasks[:])
	work_clear(below)
	for &box in work.boxes[boxes:] {
		box.top += down
		box.bottom += down
		box.line_first += lines - b.line_end
		box.line_end += lines - b.line_end
		box.decor_first += decor - b.decor_end
		box.decor_end += decor - b.decor_end
		box.para_first += paras - b.para_end
		box.para_end += paras - b.para_end
	}
	for &line in work.lines[lines:] {
		line.para += paras - b.para_end
		line.top += down
	}
	for &d in work.decor[decor:] {
		d.y += down
	}
	for &task in work.tasks[tasks:] {
		task.y += down
	}
	show_work(l)
	if was.live_end > b.line_end {
		note_live(part, max(was.live_first, b.line_end) + lines - b.line_end, was.live_end + lines - b.line_end)
	}
	// The layout of the part is where it was, that much lower.
	l.y, l.in_block, l.code_offset = was.y + down, was.in_block, was.code_offset
	end_work(l)
}

// Lays out a part with all its blocks, or down to the block `until_slot`.
// `anchor`: the part that the view is at. The text of that part and of
// the parts below it stays where it is on the page: a part above it that
// gets another height moves the top of the page.
@(private)
lay_out_part :: proc(l: ^Layout, index, anchor: int, until_slot := max(int)) -> bool {
	part := &l.parts[index]
	before := part.height
	advance(l, index, 0, until_slot) or_return
	if index < anchor {
		l.origin -= f64(part.height) - f64(before)
	}
	sum_tops(l)
	return true
}

// The part that has a height of the page, or the nearest one. -1 for a
// layout with no part.
@(private)
part_at :: proc(l: ^Layout, y: f64) -> int {
	return min(first_part_below(l, y), len(l.parts) - 1)
}

// Lays out what the page has between two heights. `anchor_y` is the
// height that the view is at: the text there and below it stays where it
// is on the page (`lay_out_part`). Returns true when it made records.
lay_out :: proc(l: ^Layout, y0, y1, anchor_y: f64) -> (changed: bool) {
	// A document with no block has nothing to lay out.
	if len(l.parts) == 0 {
		return false
	}
	anchor := part_at(l, anchor_y)
	// From the anchor down. A part is laid out only down to the end of
	// the range, so a part with one very long block does not hold a frame.
	for p := max(part_at(l, y0), anchor); p < len(l.parts); p += 1 {
		part := &l.parts[p]
		if part.top >= y1 {
			break
		}
		if advance(l, p, f32(min(y1 - part.top, 1e30)), -1) {
			changed = true
			sum_tops(l)
		}
		if !part.complete {
			break
		}
	}
	// Then the parts above it, from the nearest one up. Each is laid out
	// with all its blocks: its real height says where its last lines are.
	for p := min(anchor - 1, part_at(l, y1)); p >= 0; p -= 1 {
		part := &l.parts[p]
		if part.top + f64(part.height) <= y0 {
			break
		}
		changed |= lay_out_part(l, p, anchor)
	}
	when ODIN_DEBUG {
		problem := check(l)
		assert(problem == "", problem)
	}
	return
}

// True when the page has its records between two heights.
laid_out :: proc(l: ^Layout, y0, y1: f64) -> bool {
	for p := first_part_below(l, y0); p < len(l.parts); p += 1 {
		part := &l.parts[p]
		if part.top >= y1 {
			break
		}
		if !part.complete && part.top + f64(part.y) < y1 {
			return false
		}
	}
	return true
}

// Lays out the last parts of the document, with all their blocks, until
// `height` points of its end have their records: the end of the page is
// then at its real height. `anchor_y` as for `lay_out`.
lay_out_end :: proc(l: ^Layout, height, anchor_y: f64) -> (changed: bool) {
	anchor := part_at(l, anchor_y)
	real: f64
	for p := len(l.parts) - 1; p >= 0 && real < height; p -= 1 {
		changed |= lay_out_part(l, p, anchor)
		real += f64(l.parts[p].height)
	}
	return
}

// Lays out a part down to one block, which a place is in
// (`restore_place`).
// That part is the anchor: it is where the view goes.
lay_out_block :: proc(l: ^Layout, block: int) -> bool {
	if l.doc == nil || block < 0 || block >= l.doc.count {
		return false
	}
	p, slot := document.locate(l.doc, block)
	return lay_out_part(l, p, p, slot)
}

// Lays out lines of a code block down to `until`, each as its own
// paragraph, so a very long block does not hold a frame. Returns true at
// the end of the block.
@(private)
place_code :: proc(l: ^Layout, b: ^document.Block, x, width, until: f32) -> bool {
	size := l.m.code_size
	look := Text_Look {
		size        = size,
		line_height = math.round(size * CODE_LINE_HEIGHT),
		mono        = true,
		quote       = b.quote_depth > 0,
	}
	bytes := b.text.bytes[:]
	if l.code_offset == 0 {
		l.y += CODE_PAD
	}
	count := 0
	for l.code_offset <= len(bytes) {
		// Not past what the caller wants: a block can be many views long.
		if count > 0 && l.y >= until {
			return false
		}
		count += 1
		end := l.code_offset
		for end < len(bytes) && bytes[end] != '\n' {
			end += 1
		}
		if end > l.code_offset {
			para := make_para(l, &b.text, l.code_offset, end, look)
			l.y = place_para(l, para, x + CODE_PAD, l.y, width - 2 * CODE_PAD)
		} else {
			// An empty line has no paragraph, only its height.
			l.y += look.line_height
		}
		l.code_offset = end + 1
	}
	return true
}

@(private)
place_table :: proc(l: ^Layout, b: ^document.Block, x, y, width: f32) -> f32 {
	columns := b.columns
	rows := columns > 0 ? len(b.cells) / columns : 0
	if rows == 0 {
		return y
	}
	body_look := Text_Look {
		size        = l.m.body,
		line_height = math.round(l.m.body * l.m.line_height),
		quote       = b.quote_depth > 0,
	}
	head_look := body_look
	head_look.heading = true

	// Column width = widest cell; shrink all columns evenly when too wide.
	work := &l.work
	first_para := len(work.paras)
	widths := make([]f32, columns, context.temp_allocator)
	for row in 0 ..< rows {
		for col in 0 ..< columns {
			cell := &b.cells[row * columns + col]
			para := make_para(l, cell, 0, len(cell.bytes), row == 0 ? head_look : body_look)
			if handle := work.paras[para].handle; handle != nil {
				widths[col] = max(widths[col], text.paragraph_natural_width(handle) + 1)
			}
		}
	}
	total: f32
	for &w in widths {
		w = max(w, 24)
		total += w + 2 * CELL_PAD_X
	}
	if total > width {
		padding := f32(columns) * 2 * CELL_PAD_X
		room := max(width - padding, f32(columns))
		for &w in widths {
			w = w / (total - padding) * room
		}
		total = room + padding
	}

	y := y
	top := y
	for row in 0 ..< rows {
		row_bottom := y
		row_decor := len(work.decor)
		cx := x
		for col in 0 ..< columns {
			para := first_para + row * columns + col
			bottom := place_para(l, para, cx + CELL_PAD_X, y + CELL_PAD_Y, widths[col], b.aligns[col])
			row_bottom = max(row_bottom, bottom + CELL_PAD_Y)
			cx += widths[col] + 2 * CELL_PAD_X
		}
		if row == 0 {
			// Under the decorations of the header cells.
			inject_at(&work.decor, row_decor, Decor{x = x, y = y, w = total, h = row_bottom - y, color = l.style.code_background})
		}
		y = row_bottom
		push_decor(l, x, y - 1, total, 1, l.style.rule)
	}
	push_decor(l, x, top, total, 1, l.style.rule)
	cx := x
	for col in 0 ..= columns {
		push_decor(l, min(cx, x + total - 1), top, 1, y - top, l.style.rule)
		if col < columns {
			cx += widths[col] + 2 * CELL_PAD_X
		}
	}
	return y
}
