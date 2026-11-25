package document

import "../base"
import "base:runtime"
import "core:c"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A short source can ask for rows x columns cells without the text for
// them, because a row with fewer cells than the header gets empty ones. A
// table keeps at most this many cells plus one for each byte of the source.
MIN_TABLE_CELLS :: 50_000

@(private)
List :: struct {
	ordered: bool,
	next:    int,
	done:    bool, // the open item is a checked task
	item:    int, // the number of the open item
}

@(private)
Parser :: struct {
	ctx:          runtime.Context,
	doc:          ^Document,
	max_cells:    int,
	// The block that takes text now. `cur` is nil between blocks.
	block:        Block,
	cur:          ^Text,
	in_code:      bool,
	in_html:      bool,
	// Inline state.
	bold:         int,
	italic:       int,
	code:         int,
	image:        int,
	strike:       int,
	link:         int, // index + 1 in doc.links
	// Containers.
	quote:        int,
	lists:        [dynamic]List,
	item_marker:  Marker, // marker of the list item that has no block yet
	item_number:  int,
	item_mark:    int, // a task: the byte offset of its mark in the source; 0 for no task
	// The start of the source line of the block that comes next: of the
	// first thing that started after the last block, so a block that is
	// the first one of a list item or a quote starts at the line of
	// their mark. `at_known` is false when nothing started yet. A list,
	// an item, or a quote that ends with no block in it takes its start
	// with it (`at_depth`: how many of these were open around the thing
	// that started), so the start of an item stays when an empty quote
	// in it ends.
	at:           int,
	at_known:     bool,
	at_depth:     int,
	open:         int, // the lists, items, and quotes that are open
	item_count:   int, // list items so far
	item_blocks:  int, // blocks of the open item so far
	list_start:   bool, // the next item is the first of a top-level list
	// For `block_map`: where the text of one block is in the source. Nil
	// for a parse that makes a document only.
	places:       ^[dynamic]Place,
	places_block: int, // the number of that block in what is parsed
	bytes:        []u8, // what is parsed
	// Table.
	table:        Block,
	in_table:     bool,
	cell:         Text,
	row_cells:    int,
	skip_row:     bool,
}

// Parses a Markdown source. The caller owns the result (`destroy`).
parse :: proc(source: string) -> Document {
	return parse_owned(slice.clone(transmute([]u8)source))
}

// Parses a Markdown source that the document keeps: memory of the
// allocator of the context, which goes with the document.
parse_owned :: proc(bytes: []u8) -> Document {
	return parse_piece(bytes, 0, len(bytes))
}

// Parses a piece of the source of a document that starts where a block
// starts that is in no list and no quote. The offsets of its blocks count
// from the start of the piece. `items` is the number of list items of
// the document so far, and `full_size` the size of all of its source.
@(private)
parse_piece :: proc(bytes: []u8, items, full_size: int, places: ^[dynamic]Place = nil, places_block := 0) -> Document {
	source := string(bytes)
	doc: Document
	p := Parser {
		ctx          = context,
		doc          = &doc,
		max_cells    = MIN_TABLE_CELLS + full_size,
		item_count   = items,
		places       = places,
		places_block = places_block,
		bytes        = bytes,
	}
	md := Md_Parser {
		flags       = MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS | MD_FLAG_PERMISSIVEAUTOLINKS,
		enter_block = enter_block,
		leave_block = leave_block,
		enter_span  = enter_span,
		leave_span  = leave_span,
		text        = on_text,
		block_offset = on_block_offset,
		ref_def     = on_ref_def,
		ref_def_use = on_ref_def_use,
	}
	// md4c takes a 32-bit size; a larger source is cut there.
	size := c.uint(min(len(source), int(max(c.int))))
	md_parse(raw_data(source), size, &md, &p)
	close_text(&p)
	delete(p.lists)
	doc.source = bytes
	doc.items = p.item_count
	doc.links_parsed = len(doc.links)
	for &def in doc.defs {
		def_name(&def, bytes[def.start:def.end])
		doc.def_longest = max(doc.def_longest, def.end - def.start)
		// The mark of a quote at the start of a later line.
		for at := def.start; at < def.end; at += 1 {
			if source[at] != '\n' && source[at] != '\r' {
				continue
			}
			for at + 1 < def.end && (source[at + 1] == ' ' || source[at + 1] == '\t') {
				at += 1
			}
			doc.defs_marked ||= at + 1 < def.end && source[at + 1] == '>'
		}
	}
	when ODIN_DEBUG {
		// The blocks are in the order of the source, each with lines of
		// its own.
		last := -1
		for part in doc.parts {
			for &b in part_blocks(part) {
				assert(b.source > last && b.source < max(len(source), 1), "a block starts before the block before it ends")
				last = b.source
			}
		}
	}
	// The parser gave offsets from the start of the source.
	anchor(&doc, 0, len(doc.parts) - 1)
	return doc
}


@(private)
current_style :: proc(p: ^Parser) -> Inline_Set {
	style: Inline_Set
	if p.bold > 0 {style += {.Bold}}
	if p.italic > 0 {style += {.Italic}}
	if p.code > 0 {style += {.Code}}
	if p.image > 0 {style += {.Image}}
	if p.strike > 0 {style += {.Strike}}
	if p.link > 0 {style += {.Link}}
	return style
}

@(private)
append_text :: proc(p: ^Parser, s: string, source := -1, source_len := 0, line_break := false) {
	t := p.cur
	if t == nil || len(s) == 0 {
		return
	}
	start := len(t.bytes)
	append(&t.bytes, s)
	if p.places != nil && p.doc.count == p.places_block {
		cell := p.in_table && p.cur == &p.cell ? len(p.table.cells) : 0
		append(p.places, Place{cell, start, len(s), source, source_len, source < 0 || source_len != len(s), source < 0, line_break})
	}
	style := current_style(p)
	if n := len(t.spans); n > 0 && t.spans[n - 1].style == style && t.spans[n - 1].link == p.link {
		t.spans[n - 1].end = len(t.bytes)
		return
	}
	append(&t.spans, Span{start, len(t.bytes), style, p.link})
}

@(private)
append_rune :: proc(p: ^Parser, r: rune, source := -1, source_len := 0) {
	bytes, n := utf8.encode_rune(r)
	append_text(p, string(bytes[:n]), source, source_len)
}

// Where a piece of the text of a block came from in the source.
Place :: struct {
	cell:               int, // of a table; 0 for other blocks
	text, text_len:     int,
	source, source_len: int,
	// The source has the piece in another form (a character as an
	// entity, a run of spaces for one space, a line break): it is one
	// thing, which goes out as a whole. If not, a byte of the text is
	// the byte of the source at the same distance from the start.
	whole:              bool,
	// The parser made the text (a line break, the space for one, the
	// spaces of an indent): the source has no text for it, and its
	// place is what is between the pieces around it (`place_made`).
	made:               bool,
	line_break:         bool, // of a made piece: it is for a line break
}

// Starts a paragraph or a heading. It takes the marker of a list item that
// has no block yet.
@(private)
open_text :: proc(p: ^Parser, kind: Block_Kind, level := 0) {
	close_text(p)
	p.block = start_block(p, kind)
	p.block.level = level
	p.cur = &p.block.text
}

// A new block in the containers that are open now. It takes the marker of
// a list item that has no block yet.
@(private)
start_block :: proc(p: ^Parser, kind: Block_Kind) -> Block {
	b := Block {
		shape = {kind = kind, list_depth = len(p.lists), quote_depth = p.quote},
		source = p.at,
		done = len(p.lists) > 0 && p.lists[len(p.lists) - 1].done,
		item = len(p.lists) > 0 ? p.lists[len(p.lists) - 1].item : 0,
	}
	p.at_known = false
	take_item_position(p, &b)
	return b
}

// Ends the block with text that is in progress: it goes into the document.
@(private)
push_block :: proc(p: ^Parser) {
	text_fit(&p.block.text)
	append_block(p.doc, p.block)
	p.block = {}
	p.cur = nil
}

// Gives back the room that the arrays of a finished text grew ahead. Most
// texts have one span, and the first one reserves room for eight.
@(private)
text_fit :: proc(t: ^Text) {
	fit(&t.bytes)
	fit(&t.spans)
}

// Makes an array as large as what it holds, in new memory: the system
// keeps the room of an array that is made smaller in place.
@(private)
fit :: proc(array: ^[dynamic]$T) {
	if cap(array) == len(array) {
		return
	}
	exact := make([dynamic]T, len(array), len(array))
	copy(exact[:], array[:])
	delete(array^)
	array^ = exact
}

// Gives a block its marker and its place in the open list item.
@(private)
take_item_position :: proc(p: ^Parser, b: ^Block) {
	if len(p.lists) == 0 {
		return
	}
	if p.item_blocks == 0 {
		b.marker = p.item_marker
		b.number = p.item_number
		b.task_mark = p.item_mark
		b.spacing = p.list_start ? .List_Start : .Item
		p.list_start = false
	} else {
		b.spacing = .Continuation
	}
	p.item_blocks += 1
}

@(private)
close_text :: proc(p: ^Parser) {
	if p.cur == nil || p.in_table || p.in_code {
		return
	}
	push_block(p)
}

@(private)
attribute :: proc(a: Md_Attribute) -> string {
	return a.text == nil ? "" : string(a.text[:a.size])
}

@(private)
enter_block :: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int {
	p := cast(^Parser)userdata
	context = p.ctx
	// Text that stands directly in a list item (a tight list) ends where
	// the next block starts.
	#partial switch type {
	case .Quote, .Ul, .Ol, .Li, .Hr, .H, .Code, .Html, .P, .Table:
		close_text(p)
	}
	#partial switch type {
	case .Quote, .Ul, .Ol, .Li:
		p.open += 1
	}
	#partial switch type {
	case .Quote:
		p.quote += 1
	case .Ul:
		p.list_start = len(p.lists) == 0
		append(&p.lists, List{})
	case .Ol:
		p.list_start = len(p.lists) == 0
		append(&p.lists, List{ordered = true, next = int((cast(^Md_Ol_Detail)detail).start)})
	case .Li:
		list := p.lists[len(p.lists) - 1]
		li := cast(^Md_Li_Detail)detail
		p.item_blocks = 0
		p.item_number = list.next
		p.item_mark = 0
		is_done := false
		if li.is_task != 0 {
			is_done = li.task_mark != ' '
			p.item_marker = is_done ? .Task_Done : .Task_Open
			p.item_mark = int(li.task_mark_offset)
		} else {
			p.item_marker = list.ordered ? .Number : .Bullet
		}
		p.lists[len(p.lists) - 1].done = is_done
		p.item_count += 1
		p.lists[len(p.lists) - 1].item = p.item_count
	case .Hr:
		append_block(p.doc, start_block(p, .Rule))
	case .H:
		open_text(p, .Heading, clamp(int((cast(^Md_H_Detail)detail).level), 1, 6))
	case .P:
		open_text(p, .Paragraph)
	case .Code:
		p.block = start_block(p, .Code)
		p.block.language = strings.clone(attribute((cast(^Md_Code_Detail)detail).lang))
		p.cur = &p.block.text
		p.in_code = true
	case .Html:
		p.in_html = true
	case .Table:
		p.table = start_block(p, .Table)
		p.table.columns = int((cast(^Md_Table_Detail)detail).col_count)
		p.in_table = true
	case .Tr:
		p.row_cells = 0
		p.skip_row = len(p.table.cells) + p.table.columns > p.max_cells
		p.doc.cells_cut ||= p.skip_row
	case .Th, .Td:
		p.cell = {}
		p.cur = &p.cell
		if type == .Th {
			align: base.Align
			#partial switch (cast(^Md_Td_Detail)detail).align {
			case .Center:
				align = .Center
			case .Right:
				align = .Right
			}
			append(&p.table.aligns, align)
		}
	}
	return 0
}

@(private)
leave_block :: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int {
	p := cast(^Parser)userdata
	context = p.ctx
	// What started in a list, an item, or a quote and made no block (a
	// quote with only raw HTML in it) is no start of the block after it.
	defer #partial switch type {
	case .Quote, .Ul, .Ol, .Li:
		p.open -= 1
		if p.at_depth >= p.open {
			p.at_known = false
		}
	}
	#partial switch type {
	case .Quote:
		close_text(p)
		p.quote -= 1
	case .Ul, .Ol:
		close_text(p)
		pop(&p.lists)
	case .Li:
		close_text(p)
		if p.item_blocks == 0 {
			// An item with nothing in it still shows its marker. Its
			// block starts where the item does.
			open_text(p, .Paragraph)
			close_text(p)
		}
		p.lists[len(p.lists) - 1].next += 1
		// A later block of the parent item is a continuation of it.
		p.item_blocks = 1
	case .H, .P:
		close_text(p)
	case .Code:
		// The last line break is the end of the block, not a line of it.
		if n := len(p.block.text.bytes); n > 0 && p.block.text.bytes[n - 1] == '\n' {
			pop(&p.block.text.bytes)
			if spans := &p.block.text.spans; len(spans) > 0 {
				spans[len(spans) - 1].end = n - 1
			}
		}
		p.in_code = false
		push_block(p)
	case .Html:
		p.in_html = false
	case .Th, .Td:
		p.cur = nil
		if p.skip_row || p.row_cells >= p.table.columns {
			text_destroy(&p.cell)
		} else {
			text_fit(&p.cell)
			append(&p.table.cells, p.cell)
			p.row_cells += 1
		}
		p.cell = {}
	case .Tr:
		// Every row has one cell for each column.
		for !p.skip_row && p.row_cells < p.table.columns {
			append(&p.table.cells, Text{})
			p.row_cells += 1
		}
	case .Table:
		for len(p.table.aligns) < p.table.columns {
			append(&p.table.aligns, base.Align.Left)
		}
		p.in_table = false
		p.doc.cells_most = max(p.doc.cells_most, len(p.table.cells))
		append_block(p.doc, p.table)
		p.table = {}
	}
	return 0
}

@(private)
on_block_offset :: proc "c" (type: Md_Block, offset: c.uint, userdata: rawptr) {
	p := cast(^Parser)userdata
	// Raw HTML is no block of the document: its lines go with the block
	// before it.
	if type != .Html && !p.at_known {
		p.at = int(offset)
		p.at_known = true
		p.at_depth = p.open
	}
}

@(private)
on_ref_def :: proc "c" (start, end: c.uint, userdata: rawptr) {
	p := cast(^Parser)userdata
	context = p.ctx
	append(&p.doc.defs, Def{start = int(start), end = int(end)})
}

@(private)
on_ref_def_use :: proc "c" (size: c.uint, accepted: c.int, userdata: rawptr) {
	doc := (cast(^Parser)userdata).doc
	if accepted != 0 {
		doc.defs_used += int(size)
	} else {
		doc.defs_cut = true
	}
}

@(private)
span_counter :: proc(p: ^Parser, type: Md_Span) -> ^int {
	#partial switch type {
	case .Em:
		return &p.italic
	case .Strong:
		return &p.bold
	case .Code:
		return &p.code
	case .Img:
		return &p.image
	case .Del:
		return &p.strike
	}
	return nil
}

@(private)
enter_span :: proc "c" (type: Md_Span, detail: rawptr, userdata: rawptr) -> c.int {
	p := cast(^Parser)userdata
	context = p.ctx
	if type == .A {
		append(&p.doc.links, strings.clone(attribute((cast(^Md_A_Detail)detail).href)))
		p.link = len(p.doc.links)
	} else if counter := span_counter(p, type); counter != nil {
		counter^ += 1
	}
	return 0
}

@(private)
leave_span :: proc "c" (type: Md_Span, detail: rawptr, userdata: rawptr) -> c.int {
	p := cast(^Parser)userdata
	context = p.ctx
	if type == .A {
		p.link = 0
	} else if counter := span_counter(p, type); counter != nil {
		counter^ -= 1
	}
	return 0
}

@(private)
on_text :: proc "c" (type: Md_Text, text: [^]u8, size: c.uint, userdata: rawptr) -> c.int {
	p := cast(^Parser)userdata
	context = p.ctx
	// Raw HTML is not shown.
	if p.in_html || type == .Html {
		return 0
	}
	// Text directly in a list item, without a paragraph around it.
	if p.cur == nil {
		if len(p.lists) == 0 || p.in_table {
			return 0
		}
		open_text(p, .Paragraph)
	}
	s := string(text[:size])
	// Where the text is in what is parsed, for a parse that notes
	// places; -1 for text that the parser made.
	at := -1
	if p.places != nil {
		from := int(uintptr(text) - uintptr(raw_data(p.bytes)))
		if uintptr(text) >= uintptr(raw_data(p.bytes)) && from < len(p.bytes) {
			at = from
		}
	}
	#partial switch type {
	case .Nullchar:
		append_rune(p, utf8.RUNE_ERROR)
	case .Br:
		append_text(p, "\n", line_break = true)
	case .Softbr:
		append_text(p, " ", line_break = true)
	case .Entity:
		append_entity(p, s, at)
	case .Normal:
		append_collapsed(p, s, at)
	case:
		// A line of code is in the source; the line break after it and
		// the spaces of its indent are made.
		append_text(p, s, at, len(s), at < 0 && s == "\n")
	}
	return 0
}

// Appends normal text. A run of spaces and tabs becomes one space, as it
// does in HTML.
@(private)
append_collapsed :: proc(p: ^Parser, s: string, at: int) {
	is_space :: proc(ch: u8) -> bool {
		return ch == ' ' || ch == '\t'
	}
	for i := 0; i < len(s); {
		start := i
		for i < len(s) && !is_space(s[i]) {
			i += 1
		}
		append_text(p, s[start:i], at < 0 ? -1 : at + start, i - start)
		if i < len(s) {
			run := i
			for i < len(s) && is_space(s[i]) {
				i += 1
			}
			append_text(p, " ", at < 0 ? -1 : at + run, i - run)
		}
	}
}

// Appends the character of "&name;", "&#123;" or "&#x7b;", or the source
// text when it names no character.
@(private)
append_entity :: proc(p: ^Parser, s: string, at: int) {
	if len(s) > 3 && s[1] == '#' {
		digits := s[2:len(s) - 1]
		radix := 10
		if digits[0] == 'x' || digits[0] == 'X' {
			digits = digits[1:]
			radix = 16
		}
		value := 0
		for ch in digits {
			digit: int
			switch ch {
			case '0' ..= '9':
				digit = int(ch - '0')
			case 'a' ..= 'f':
				digit = int(ch - 'a') + 10
			case 'A' ..= 'F':
				digit = int(ch - 'A') + 10
			}
			value = min(value * radix + digit, 0x110000)
		}
		valid := value > 0 && value < 0x110000 && !(value >= 0xd800 && value < 0xe000)
		append_rune(p, valid ? rune(value) : utf8.RUNE_ERROR, at, len(s))
		return
	}
	if entity := entity_lookup(raw_data(s), c.size_t(len(s))); entity != nil {
		// One piece of text, also for an entity of two characters.
		both: [8]u8
		first, n := utf8.encode_rune(rune(entity.codepoints[0]))
		copy(both[:], first[:n])
		if entity.codepoints[1] != 0 {
			second, m := utf8.encode_rune(rune(entity.codepoints[1]))
			copy(both[n:], second[:m])
			n += m
		}
		append_text(p, string(both[:n]), at, len(s))
		return
	}
	append_text(p, s, at, len(s))
}
