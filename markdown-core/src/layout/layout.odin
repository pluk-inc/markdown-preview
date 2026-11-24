// Layout: gives each block of a document a place on the page. It breaks the
// text into lines and records where each line and each decoration is. The
// display list (display.odin) and the selection (selection.odin) are made
// from these records, only for the part of the page that the view shows.
//
// The layout runs in steps (`step`), so the first frame of a long document
// does not wait for all of it. Every block keeps its records; only the
// lines near the view keep their shaped text (window.odin).
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
import "core:time"

HEADING_LINE_HEIGHT :: 1.25
CODE_LINE_HEIGHT :: 1.3
CODE_PAD :: 16.0
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
	order:       int, // its number in reading order; the same after a new layout
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
	above:      bool, // a line through text: drawn over the selection, as the text is
	soft_done:  bool, // of text that is softer in a checked task (`done_color`)
}

// The place of one block and the range of its records in its part. The
// top and the bottom count from the top of the part.
Box :: struct {
	top, bottom:             f32,
	line_first, line_end:    int,
	decor_first, decor_end:  int,
}

// The records of the blocks of one part of the document
// (`document.Part`), in the order of the blocks. Part n of a layout is of
// part n of its document, and box n of a part is the place of block n of
// that part. The parts go down the page with no room between them: the
// space above a block is in the part of that block.
//
// A part that has a box for each of its blocks is closed: its records are
// in one piece of memory of their exact size. The records of the last
// part, while the layout works on it, are in arrays of the layout that
// grow (`Layout.work`), and the part shows what they have now.
Part :: struct {
	top:        f64, // of the part on the page, points
	height:     f32, // down to the bottom of its last block that is laid out
	paras:      []Para,
	lines:      []Line,
	decor:      []Decor,
	boxes:      []Box, // do not overlap and go down the page
	tasks:      []Task, // down the page
	closed:     bool,
	memory:     rawptr, // of the records of a closed part
	live_first: int, // all lines with shaped text are in [live_first, live_end)
	live_end:   int,
}

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
	// The records of the parts that the layout reached, in document order.
	parts:          [dynamic]Part,
	work:           Work, // of the last part, while it is not closed
	content_height: f64,
	// The range of the page that keeps its shaped text (window.odin).
	keep_y0:        f64,
	keep_y1:        f64,
	// Progress.
	next_block:     int,
	code_offset:    int, // code block in progress: byte offset of its next line
	in_block:       bool,
	y:              f32, // from the top of the last part
	order:          int,
	column_x:       f32,
	column:         f32,
	fonts:          [dynamic]Sized_Font,
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
	l.y = l.m.page_pad * 0.6
	l.content_height = f64(l.y)
	l.keep_y0, l.keep_y1 = 0, 1e30
}

// How far down the page the layout is, in points.
reached :: proc(l: ^Layout) -> f64 {
	if len(l.parts) == 0 {
		return f64(l.y)
	}
	return l.parts[len(l.parts) - 1].top + f64(l.y)
}

// The part that the layout works on.
@(private)
last_part :: proc(l: ^Layout) -> ^Part {
	return &l.parts[len(l.parts) - 1]
}

// Shows the records in work as the ones of the last part. After each
// change to them: an array that grows moves.
@(private)
show_work :: proc(l: ^Layout) {
	part := last_part(l)
	part.paras, part.lines, part.decor = l.work.paras[:], l.work.lines[:], l.work.decor[:]
	part.boxes, part.tasks = l.work.boxes[:], l.work.tasks[:]
}

// Closes the last part: its records go from the arrays that grow into one
// piece of memory of their exact size.
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
	part := last_part(l)
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
	part.closed = true
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
		part_destroy(&part)
	}
	clear(&l.parts)
	clear(&l.work.paras)
	clear(&l.work.lines)
	clear(&l.work.decor)
	clear(&l.work.boxes)
	clear(&l.work.tasks)
	l.next_block = 0
	l.code_offset = 0
	l.in_block = false
	l.order = 0
	l.content_height = 0
}

destroy :: proc(l: ^Layout) {
	reset(l)
	for f in l.fonts {
		text.font_release(f.font)
	}
	delete(l.fonts)
	delete(l.parts)
	delete(l.work.paras)
	delete(l.work.lines)
	delete(l.work.decor)
	delete(l.work.boxes)
	delete(l.work.tasks)
	l^ = {}
}

done :: proc(l: ^Layout) -> bool {
	return l.doc == nil || l.next_block >= l.doc.count
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
span_color :: proc(l: ^Layout, para: ^Para, style: document.Inline_Set, done: bool) -> base.Color {
	if .Link in style {
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
TASK_GAP :: 0.25 // between the box and the text

// Makes the paragraph of the bytes [from, to) of `src` in the last part
// and returns its index in the paragraphs of that part.
@(private)
make_para :: proc(l: ^Layout, src: ^document.Text, from, to: int, look: Text_Look) -> int {
	l.order += 1
	paras := &l.work.paras
	append(
		paras,
		Para {
			src = src,
			base = from,
			len = to - from,
			order = l.order,
			look = look,
		},
	)
	shape_para(l, len(l.parts) - 1, &paras[len(paras) - 1])
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

// Breaks a paragraph of the last part into lines of `width` at (x, y).
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
	case .Bullet:
		return "•"
	case .Number:
		return fmt.tprintf("%d.", b.number)
	case .Task_Open, .Task_Done:
		// A box that the host draws (`place_task`).
	}
	return ""
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
// middle of its first line.
@(private)
place_task :: proc(l: ^Layout, b: ^document.Block, x, y, line_height: f32) {
	size := task_box_size(l.m)
	bx := math.round(x - l.m.body * TASK_GAP - size)
	// Not on a whole point here: that is a point of the page, and y is
	// from the top of the part (`tasks_between`).
	by := y + (line_height - size) / 2
	append(&l.work.tasks, Task{bx, by, len(l.work.boxes) - 1})
}

// The bullet, number, or box of a list item, right-aligned left of x.
@(private)
place_marker :: proc(l: ^Layout, b: ^document.Block, x, y, line_height: f32) {
	if b.marker == .Task_Open || b.marker == .Task_Done {
		place_task(l, b, x, y, line_height)
		return
	}
	label := marker_text(b)
	if label == "" {
		return
	}
	paras := &l.work.paras
	append(paras, Para{block = len(l.work.boxes) - 1, len = len(label), size = l.m.body, line_height = line_height})
	shape_marker(l, &paras[len(paras) - 1], label)
	place_para(l, len(paras) - 1, x - l.m.list_indent, y, l.m.list_indent - 8, .Right)
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

// Lays out blocks until the page reaches `until_y` or `budget_ms` ends
// (0 = no time limit). Returns true when it added something.
step :: proc(l: ^Layout, until_y: f64, budget_ms: f64 = 0) -> bool {
	if done(l) {
		return false
	}
	started := time.tick_now()
	defer free_all(context.temp_allocator)
	progressed := false
	for l.next_block < l.doc.count && reached(l) < until_y {
		if progressed && budget_ms > 0 && time.duration_milliseconds(time.tick_since(started)) > budget_ms {
			break
		}
		progressed = true
		if !l.in_block {
			open_part(l)
		}
		work := &l.work
		// The block in progress has its box already.
		slot := l.in_block ? len(work.boxes) - 1 : len(work.boxes)
		b := &l.doc.parts[len(l.parts) - 1].blocks[slot]
		new_lines := len(work.lines)
		x := l.column_x + f32(b.list_depth) * l.m.list_indent + f32(b.quote_depth) * l.m.quote_indent
		width := l.column - (x - l.column_x)
		heading_size := l.m.body * HEADING_SCALE[b.kind == .Heading ? b.level : 0]

		if !l.in_block {
			if l.next_block > 0 {
				l.y += space_above(l, b, heading_size)
			}
			append(&work.boxes, Box{top = l.y, bottom = l.y, line_first = len(work.lines), decor_first = len(work.decor)})
			l.in_block = true
			l.code_offset = 0
			// The marker of a list item stands at the first line of its
			// first block, whatever the kind of the block.
			body_line := math.round(l.m.body * l.m.line_height)
			switch b.kind {
			case .Paragraph:
				place_marker(l, b, x, l.y, body_line)
			case .Heading:
				place_marker(l, b, x, l.y, heading_size * HEADING_LINE_HEIGHT)
			case .Code:
				place_marker(l, b, x, l.y + CODE_PAD, math.round(l.m.code_size * CODE_LINE_HEIGHT))
			case .Table:
				place_marker(l, b, x, l.y + CELL_PAD_Y, body_line)
			case .Rule:
				place_marker(l, b, x, l.y - body_line / 2, body_line)
			}
		}
		box := &work.boxes[slot]
		finished := true

		switch b.kind {
		case .Paragraph, .Heading:
			look := Text_Look {
				size        = heading_size,
				line_height = b.kind == .Heading ? heading_size * HEADING_LINE_HEIGHT : math.round(heading_size * l.m.line_height),
				heading     = b.kind == .Heading,
				quote       = b.quote_depth > 0,
			}
			para := make_para(l, &b.text, 0, len(b.text.bytes), look)
			l.y = place_para(l, para, x, l.y, width)
		case .Code:
			finished = step_code(l, b, x, width, started, budget_ms)
			if finished {
				// Backgrounds are drawn before all glyphs, so the card can
				// be added after the text gave its height.
				bottom := l.y + CODE_PAD
				push_decor(l, x - 0.5, box.top - 0.5, width + 1, bottom - box.top + 1, l.style.code_border, 8.5)
				push_decor(l, x, box.top, width, bottom - box.top, l.style.code_background, 8)
				l.y = bottom
			}
		case .Rule:
			push_decor(l, x, l.y, width, 1, l.style.rule)
			l.y += 1
		case .Table:
			l.y = place_table(l, b, x, l.y, width)
		}

		if finished {
			for depth in 0 ..< b.quote_depth {
				bar_x := l.column_x + f32(b.list_depth) * l.m.list_indent + f32(depth) * l.m.quote_indent
				push_decor(l, bar_x, box.top, 3, l.y - box.top, l.style.quote_bar, 1.5)
			}
			l.in_block = false
			l.next_block += 1
		}
		box.bottom = l.y
		box.line_end = len(work.lines)
		box.decor_end = len(work.decor)
		part := last_part(l)
		part.height = l.y
		show_work(l)
		// The new lines keep their shaped text only inside the window.
		if first, end := trim(l, part, new_lines, len(part.lines)); first < end {
			note_live(part, first, end)
		}
		if finished && len(part.boxes) == l.doc.parts[len(l.parts) - 1].count {
			close_part(l)
		}
	}
	l.content_height = reached(l) + f64(l.m.page_pad)
	when ODIN_DEBUG {
		assert(check(l) == "", check(l))
	}
	return progressed
}

// Makes the part of the next block the last part of the layout, when it
// is not that already: the part after the one that has all its blocks.
// The new part starts where the one before it ends.
@(private)
open_part :: proc(l: ^Layout) {
	for len(l.parts) == 0 || last_part(l).closed {
		top: f64
		if len(l.parts) > 0 {
			top = reached(l)
			l.y = 0
		}
		// A part of the document with no block has no records to wait for.
		append(&l.parts, Part{top = top, closed = l.doc.parts[len(l.parts)].count == 0})
	}
}

// Lays out down to the end of a block. For a place that the view must
// show (`place_y`): the layout above it is necessary to know where it is.
step_to_block :: proc(l: ^Layout, block: int) {
	for !done(l) && l.next_block <= block {
		step(l, reached(l) + 4096)
	}
}

// Lays out lines of a code block, each as its own paragraph, so a very long
// block does not hold one step. Returns true at the end of the block.
@(private)
step_code :: proc(l: ^Layout, b: ^document.Block, x, width: f32, started: time.Tick, budget_ms: f64) -> bool {
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
		if count > 0 && count % 32 == 0 && budget_ms > 0 && time.duration_milliseconds(time.tick_since(started)) > budget_ms {
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
			// An empty line: it has a number in reading order, so the copied
			// text keeps it.
			l.order += 1
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
