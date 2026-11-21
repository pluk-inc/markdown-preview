package mdcore

import "core:fmt"
import "core:math"
import "core:strings"
import CF "core:sys/darwin/CoreFoundation"
import CT "core:sys/darwin/CoreText"
import cm "vendor:commonmark"

@(rodata)
HEADING_SCALE := [7]f32{1, 2, 1.692, 1.308, 1.154, 1, 0.846}

style_font :: proc(ctx: ^Ctx, kind: Font_Kind, size: f32) -> CT.FontRef {
	for f in ctx.style_fonts {
		if f.kind == kind && f.size == size {
			return f.font
		}
	}
	font: CT.FontRef
	switch kind {
	case .Regular:
		font = CT.FontCreateUIFontForLanguage(.System, f64(size), nil)
	case .Semibold:
		name := CF.StringCreateWithCString(nil, ".AppleSystemUIFontDemi", UTF8)
		font = CT.FontCreateWithName(name, f64(size), nil)
		CF.Release(CF.TypeRef(name))
	case .Bold:
		font = CT.FontCreateUIFontForLanguage(.EmphasizedSystem, f64(size), nil)
	case .Italic, .Bold_Italic:
		base := style_font(ctx, kind == .Italic ? .Regular : .Bold, size)
		font = CT.FontCreateCopyWithSymbolicTraits(base, f64(size), nil, {.Italic}, {.Italic})
		if font == nil {
			font = CT.FontRef(CF.Retain(CF.TypeRef(base)))
		}
	case .Mono:
		name := CF.StringCreateWithCString(nil, ".AppleSystemUIFontMonospaced-Regular", UTF8)
		font = CT.FontCreateWithName(name, f64(size), nil)
		CF.Release(CF.TypeRef(name))
	}
	append(&ctx.style_fonts, Style_Font{kind, size, font})
	return font
}

UTF8 :: CF.StringEncoding(CF.StringBuiltInEncodings.UTF8)

text_init :: proc(t: ^Text, size: f32, line_height: f32) {
	t.astr = CF.AttributedStringCreateMutable(nil, 0)
	t.size = size
	t.line_height = line_height
}

text_append :: proc(t: ^Text, s: string, font: CT.FontRef, color: Color, flags: bit_set[Span_Flag] = {}) {
	if len(s) == 0 {
		return
	}
	str := CF.StringCreateWithBytes(nil, raw_data(s), CF.Index(len(s)), UTF8, false)
	if str == nil {
		return
	}
	n := int(CF.StringGetLength(str))
	CF.AttributedStringReplaceString(t.astr, CF.Range{CF.Index(t.len), 0}, str)
	CF.AttributedStringSetAttribute(t.astr, CF.Range{CF.Index(t.len), CF.Index(n)}, CT.kFontAttributeName, CF.TypeRef(font))
	append(&t.spans, Span{t.len, t.len + n, color, flags})
	t.len += n
	CF.Release(CF.TypeRef(str))
}

List_State :: struct {
	ordered: bool,
	n:       int,
}

Parser :: struct {
	ctx:            ^Ctx,
	block:          Block,
	cur:            ^Text, // where inline nodes go; nil outside a text block
	inline_only:    bool, // table cell: paragraphs do not make blocks
	base_bold:      bool,
	size:           f32,
	bold, italic:   int,
	link, image:    int,
	quote:          int,
	lists:          [dynamic]List_State,
	item_start:     bool, // the next text block is the first of a list item
	list_start:     bool, // next item is the first of a top-level list
}

inline_font :: proc(p: ^Parser) -> CT.FontRef {
	bold := p.bold > 0 || p.base_bold
	italic := p.italic > 0 || p.image > 0
	kind: Font_Kind = .Regular
	if bold && italic {
		kind = .Bold_Italic
	} else if bold {
		kind = p.base_bold && p.bold == 0 ? .Semibold : .Bold
	} else if italic {
		kind = .Italic
	}
	return style_font(p.ctx, kind, p.size)
}

inline_color :: proc(p: ^Parser) -> Color {
	if p.link > 0 {
		return LINK_COLOR
	}
	if p.quote > 0 || p.image > 0 {
		return SECONDARY_COLOR
	}
	return TEXT_COLOR
}

begin_text_block :: proc(p: ^Parser, heading: int) {
	if p.inline_only {
		return
	}
	p.block = Block {
		kind        = .Text,
		quote_depth = p.quote,
		indent      = f32(len(p.lists)) * LIST_INDENT,
	}
	p.size = BODY_SIZE * HEADING_SCALE[heading]
	p.base_bold = heading > 0
	if heading > 0 {
		text_init(&p.block.text, p.size, p.size * HEADING_LINE_HEIGHT)
		p.block.space_before = 0.6 * BODY_SIZE + 0.5 * p.size
	} else {
		text_init(&p.block.text, p.size, p.size * BODY_LINE_HEIGHT)
		// A later paragraph of a list item sits closer than a new paragraph.
		p.block.space_before = len(p.lists) > 0 ? LIST_ITEM_SPACING * 2 : PARAGRAPH_SPACING
	}
	if p.item_start && len(p.lists) > 0 {
		list := p.lists[len(p.lists) - 1]
		p.block.space_before = p.list_start ? PARAGRAPH_SPACING : LIST_ITEM_SPACING
		p.list_start = false
		text_init(&p.block.marker, BODY_SIZE, BODY_SIZE * BODY_LINE_HEIGHT)
		label := list.ordered ? fmt.tprintf("%d.", list.n) : "•"
		text_append(&p.block.marker, label, style_font(p.ctx, .Regular, BODY_SIZE), SECONDARY_COLOR)
	}
	p.item_start = false
	p.cur = &p.block.text
}

end_text_block :: proc(p: ^Parser) {
	if p.inline_only {
		return
	}
	if p.cur != nil {
		append(&p.ctx.blocks, p.block)
		p.block = {}
		p.cur = nil
		p.base_bold = false
		p.size = BODY_SIZE
	}
}

// The app links cmark-gfm, which has the same function names as cmark but
// other node type numbers: 0x8000 | n for blocks and 0xc000 | n for inlines.
// This maps both to cmark's numbers.
node_kind :: proc(node: ^cm.Node) -> cm.Node_Type {
	raw := u16(cm.node_get_type(node))
	if raw & 0x8000 == 0 {
		return cm.Node_Type(raw)
	}
	n := raw & 0xff
	if n == 0 || n > 10 {
		return .None // footnote nodes
	}
	return cm.Node_Type(raw & 0x4000 != 0 ? n + 10 : n)
}

walk :: proc(p: ^Parser, src: string) {
	if len(strings.trim_space(src)) == 0 {
		return
	}
	root := cm.parse_document(raw_data(src), len(src), cm.DEFAULT_OPTIONS)
	if root == nil {
		return
	}
	defer cm.node_free(root)
	iter := cm.iter_new(root)
	defer cm.iter_free(iter)
	for {
		ev := cm.iter_next(iter)
		if ev == .Done {
			break
		}
		node := cm.iter_get_node(iter)
		enter := ev == .Enter
		kind := node_kind(node)
		#partial switch kind {
		case .Block_Quote:
			p.quote += enter ? 1 : -1
		case .List:
			if enter {
				p.list_start = len(p.lists) == 0
				append(&p.lists, List_State{cm.node_get_list_type(node) == .Ordered, int(cm.node_get_list_start(node))})
			} else {
				pop(&p.lists)
			}
		case .Item:
			if enter {
				p.item_start = true
			} else if len(p.lists) > 0 {
				p.lists[len(p.lists) - 1].n += 1
			}
		case .Paragraph:
			if enter {
				begin_text_block(p, 0)
			} else {
				end_text_block(p)
			}
		case .Heading:
			if enter {
				begin_text_block(p, clamp(int(cm.node_get_heading_level(node)), 1, 6))
			} else {
				end_text_block(p)
			}
		case .Code_Block:
			if p.inline_only {
				continue
			}
			b := Block {
				kind         = .Code,
				quote_depth  = p.quote,
				indent       = f32(len(p.lists)) * LIST_INDENT,
				space_before = PARAGRAPH_SPACING,
			}
			text_init(&b.text, CODE_SIZE, math.round(f32(CODE_SIZE * 1.3)))
			code := strings.trim_right(string(cm.node_get_literal(node)), "\n")
			text_append(&b.text, code, style_font(p.ctx, .Mono, CODE_SIZE), TEXT_COLOR)
			append(&p.ctx.blocks, b)
		case .Thematic_Break:
			if !p.inline_only {
				append(&p.ctx.blocks, Block{kind = .Rule, quote_depth = p.quote, space_before = PARAGRAPH_SPACING})
			}
		case .Text, .Soft_Break, .Line_Break:
			if p.cur != nil {
				literal := kind == .Text ? string(cm.node_get_literal(node)) : (kind == .Soft_Break ? " " : "\n")
				text_append(p.cur, literal, inline_font(p), inline_color(p))
			}
		case .Code:
			if p.cur != nil {
				text_append(p.cur, string(cm.node_get_literal(node)), style_font(p.ctx, .Mono, p.size * 0.9), inline_color(p), {.Code_Bg})
			}
		case .Emph:
			p.italic += enter ? 1 : -1
		case .Strong:
			p.bold += enter ? 1 : -1
		case .Link:
			p.link += enter ? 1 : -1
		case .Image:
			p.image += enter ? 1 : -1
		}
	}
}

// ---- GFM tables: cmark has none, so a small scanner cuts them out ----------

is_delimiter_row :: proc(line: string) -> bool {
	s := strings.trim_space(line)
	if len(s) < 3 || !strings.contains_rune(s, '-') || !strings.contains_rune(s, '|') {
		return false
	}
	for ch in s {
		if ch != '|' && ch != '-' && ch != ':' && ch != ' ' && ch != '\t' {
			return false
		}
	}
	return true
}

split_cells :: proc(line: string, out: ^[dynamic]string) {
	s := strings.trim_space(line)
	if strings.has_prefix(s, "|") {
		s = s[1:]
	}
	if strings.has_suffix(s, "|") && !strings.has_suffix(s, "\\|") {
		s = s[:len(s) - 1]
	}
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' {
			i += 1
		} else if s[i] == '|' {
			append(out, strings.trim_space(s[start:i]))
			start = i + 1
		}
	}
	append(out, strings.trim_space(s[start:]))
}

parse_table :: proc(ctx: ^Ctx, lines: []string) {
	b := Block {
		kind         = .Table,
		space_before = BODY_SIZE * 1.6,
	}
	cells: [dynamic]string
	defer delete(cells)
	split_cells(lines[1], &cells)
	b.ncols = len(cells)
	for spec in cells {
		left := strings.has_prefix(spec, ":")
		right := strings.has_suffix(spec, ":")
		append(&b.aligns, right ? (left ? Align.Center : Align.Right) : Align.Left)
	}
	for line, row in lines {
		if row == 1 {
			continue
		}
		clear(&cells)
		split_cells(line, &cells)
		for col in 0 ..< b.ncols {
			cell: Text
			text_init(&cell, BODY_SIZE, BODY_SIZE * BODY_LINE_HEIGHT)
			if col < len(cells) {
				p := Parser {
					ctx         = ctx,
					inline_only = true,
					size        = BODY_SIZE,
					base_bold   = row == 0,
				}
				p.cur = &cell
				walk(&p, cells[col])
				delete(p.lists)
			}
			append(&b.cells, cell)
		}
	}
	append(&ctx.blocks, b)
}

parse_document :: proc(ctx: ^Ctx, src: string) {
	lines := strings.split_lines(src)
	defer delete(lines)
	// Byte offset of each line start, to cut the source without a copy.
	offsets := make([]int, len(lines) + 1)
	defer delete(offsets)
	{
		pos := 0
		for line, i in lines {
			offsets[i] = pos
			pos += len(line)
			if pos < len(src) && src[pos] == '\r' {
				pos += 1
			}
			if pos < len(src) && src[pos] == '\n' {
				pos += 1
			}
		}
		offsets[len(lines)] = len(src)
	}
	// A table cuts the source into pieces that cmark parses one by one. Link
	// reference definitions must reach every piece, so they go after each one.
	refs := strings.builder_make()
	defer strings.builder_destroy(&refs)
	for line in lines {
		t := strings.trim_left_space(line)
		if strings.has_prefix(t, "[") && !strings.has_prefix(t, "[^") && strings.contains(t, "]:") {
			strings.write_string(&refs, "\n\n")
			strings.write_string(&refs, t)
		}
	}
	flush :: proc(ctx: ^Ctx, src: string, refs: string) {
		p := Parser {
			ctx  = ctx,
			size = BODY_SIZE,
		}
		walk(&p, refs == "" ? src : strings.concatenate({src, refs}, context.temp_allocator))
		delete(p.lists)
	}
	ref_text := strings.to_string(refs)
	seg_start := 0
	in_fence := false
	for i := 0; i < len(lines); i += 1 {
		t := strings.trim_left_space(lines[i])
		if strings.has_prefix(t, "```") || strings.has_prefix(t, "~~~") {
			in_fence = !in_fence
			continue
		}
		if in_fence || i + 1 >= len(lines) || !strings.contains_rune(lines[i], '|') || !is_delimiter_row(lines[i + 1]) {
			continue
		}
		end := i + 2
		for end < len(lines) && strings.contains_rune(lines[end], '|') && len(strings.trim_space(lines[end])) > 0 {
			end += 1
		}
		flush(ctx, src[offsets[seg_start]:offsets[i]], ref_text)
		parse_table(ctx, lines[i:end])
		seg_start = end
		i = end - 1
	}
	flush(ctx, src[offsets[seg_start]:], ref_text)
	free_all(context.temp_allocator)
}
