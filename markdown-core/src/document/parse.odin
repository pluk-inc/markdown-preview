package document

import "../base"
import "base:runtime"
import "core:c"
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
	item_blocks:  int, // blocks of the open item so far
	list_start:   bool, // the next item is the first of a top-level list
	// Table.
	table:        Block,
	in_table:     bool,
	cell:         Text,
	row_cells:    int,
	skip_row:     bool,
}

// Parses a Markdown source. The caller owns the result (`destroy`).
parse :: proc(source: string) -> Document {
	doc: Document
	p := Parser {
		ctx       = context,
		doc       = &doc,
		max_cells = MIN_TABLE_CELLS + len(source),
	}
	md := Md_Parser {
		flags       = MD_FLAG_TABLES | MD_FLAG_STRIKETHROUGH | MD_FLAG_TASKLISTS | MD_FLAG_PERMISSIVEAUTOLINKS,
		enter_block = enter_block,
		leave_block = leave_block,
		enter_span  = enter_span,
		leave_span  = leave_span,
		text        = on_text,
	}
	// md4c takes a 32-bit size; a larger source is cut there.
	size := c.uint(min(len(source), int(max(c.int))))
	md_parse(raw_data(source), size, &md, &p)
	close_text(&p)
	delete(p.lists)
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
append_text :: proc(p: ^Parser, s: string) {
	t := p.cur
	if t == nil || len(s) == 0 {
		return
	}
	start := len(t.bytes)
	append(&t.bytes, s)
	style := current_style(p)
	if n := len(t.spans); n > 0 && t.spans[n - 1].style == style && t.spans[n - 1].link == p.link {
		t.spans[n - 1].end = len(t.bytes)
		return
	}
	append(&t.spans, Span{start, len(t.bytes), style, p.link})
}

@(private)
append_rune :: proc(p: ^Parser, r: rune) {
	bytes, n := utf8.encode_rune(r)
	append_text(p, string(bytes[:n]))
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
		kind        = kind,
		list_depth  = len(p.lists),
		quote_depth = p.quote,
	}
	take_item_position(p, &b)
	return b
}

// Ends the block with text that is in progress: it goes into the document.
@(private)
push_block :: proc(p: ^Parser) {
	text_fit(&p.block.text)
	append(&p.doc.blocks, p.block)
	p.block = {}
	p.cur = nil
}

// Gives back the room that the arrays of a finished text grew ahead. Most
// texts have one span, and the first one reserves room for eight.
@(private)
text_fit :: proc(t: ^Text) {
	shrink(&t.bytes)
	shrink(&t.spans)
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
		if li.is_task != 0 {
			p.item_marker = li.task_mark == ' ' ? .Task_Open : .Task_Done
		} else {
			p.item_marker = list.ordered ? .Number : .Bullet
		}
	case .Hr:
		append(&p.doc.blocks, start_block(p, .Rule))
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
			// An item with nothing in it still shows its marker.
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
		append(&p.doc.blocks, p.table)
		p.table = {}
	}
	return 0
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
	#partial switch type {
	case .Nullchar:
		append_rune(p, utf8.RUNE_ERROR)
	case .Br:
		append_text(p, "\n")
	case .Softbr:
		append_text(p, " ")
	case .Entity:
		append_entity(p, s)
	case .Normal:
		append_collapsed(p, s)
	case:
		append_text(p, s)
	}
	return 0
}

// Appends normal text. A run of spaces and tabs becomes one space, as it
// does in HTML.
@(private)
append_collapsed :: proc(p: ^Parser, s: string) {
	is_space :: proc(ch: u8) -> bool {
		return ch == ' ' || ch == '\t'
	}
	for i := 0; i < len(s); {
		start := i
		for i < len(s) && !is_space(s[i]) {
			i += 1
		}
		append_text(p, s[start:i])
		if i < len(s) {
			append_text(p, " ")
			for i < len(s) && is_space(s[i]) {
				i += 1
			}
		}
	}
}

// Appends the character of "&name;", "&#123;" or "&#x7b;", or the source
// text when it names no character.
@(private)
append_entity :: proc(p: ^Parser, s: string) {
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
		append_rune(p, valid ? rune(value) : utf8.RUNE_ERROR)
		return
	}
	if entity := entity_lookup(raw_data(s), c.size_t(len(s))); entity != nil {
		append_rune(p, rune(entity.codepoints[0]))
		if entity.codepoints[1] != 0 {
			append_rune(p, rune(entity.codepoints[1]))
		}
		return
	}
	append_text(p, s)
}
