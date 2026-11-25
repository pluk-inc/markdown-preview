// Bindings for the md4c parser in pkg/md4c. build.sh compiles it into the
// library with these two names.
package document

import "core:c"

foreign import md4c_lib "system:mdcore_md4c"

Md_Block :: enum c.int {
	Doc,
	Quote,
	Ul,
	Ol,
	Li,
	Hr,
	H,
	Code,
	Html,
	P,
	Table,
	Thead,
	Tbody,
	Tr,
	Th,
	Td,
	Footnote_Def_Section,
	Footnote_Def,
	Admonition,
	Blank,
}

Md_Span :: enum c.int {
	Em,
	Strong,
	A,
	Img,
	Code,
	Ins,
	Del,
	Latexmath,
	Latexmath_Display,
	Wikilink,
	U,
	Spoiler,
	Superscript,
	Subscript,
	Footnote_Ref,
	Mark,
}

Md_Text :: enum c.int {
	Normal,
	Nullchar,
	Br,
	Softbr,
	Entity,
	Code,
	Html,
	Latexmath,
}

Md_Align :: enum c.int {
	Default,
	Left,
	Center,
	Right,
}

Md_Attribute :: struct {
	text:           [^]u8,
	size:           c.uint,
	substr_types:   [^]Md_Text,
	substr_offsets: [^]c.uint,
}

Md_Ol_Detail :: struct {
	start:          c.uint,
	is_tight:       c.int,
	mark_delimiter: c.char,
}

Md_Li_Detail :: struct {
	is_task:          c.int,
	task_mark:        c.char,
	task_mark_offset: c.uint,
}

Md_H_Detail :: struct {
	level: c.uint,
}

Md_Code_Detail :: struct {
	info:       Md_Attribute,
	lang:       Md_Attribute,
	fence_char: c.char,
}

Md_Table_Detail :: struct {
	col_count:      c.uint,
	head_row_count: c.uint,
	body_row_count: c.uint,
}

Md_Td_Detail :: struct {
	align: Md_Align,
}

Md_A_Detail :: struct {
	href:        Md_Attribute,
	title:       Md_Attribute,
	is_autolink: c.int,
}

MD_FLAG_PERMISSIVEAUTOLINKS :: 0x4 | 0x8 | 0x400
MD_FLAG_TABLES :: 0x100
MD_FLAG_STRIKETHROUGH :: 0x200
MD_FLAG_TASKLISTS :: 0x800

Md_Parser :: struct {
	abi_version: c.uint,
	flags:       c.uint,
	enter_block: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int,
	leave_block: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int,
	enter_span:  proc "c" (type: Md_Span, detail: rawptr, userdata: rawptr) -> c.int,
	leave_span:  proc "c" (type: Md_Span, detail: rawptr, userdata: rawptr) -> c.int,
	text:        proc "c" (type: Md_Text, text: [^]u8, size: c.uint, userdata: rawptr) -> c.int,
	debug_log:   proc "c" (msg: cstring, userdata: rawptr),
	syntax:      proc "c" (),
	// Not in upstream md4c (pkg/md4c/README.md): the start of the source
	// line where a block starts, before the block comes.
	block_offset: proc "c" (type: Md_Block, offset: c.uint, userdata: rawptr),
	// Not in upstream md4c either: the range of the source of each
	// definition of a link, in the order of the source.
	ref_def:      proc "c" (start, end: c.uint, userdata: rawptr),
	// And: each use of a definition, with the size that it counts for
	// in the parser's limit for such uses, and if the limit had room.
	ref_def_use:  proc "c" (size: c.uint, accepted: c.int, userdata: rawptr),
}

Md_Entity :: struct {
	name:       cstring,
	codepoints: [2]c.uint,
}

@(default_calling_convention = "c")
foreign md4c_lib {
	@(link_name = "mdcore_md_parse")
	md_parse :: proc(text: [^]u8, size: c.uint, parser: ^Md_Parser, userdata: rawptr) -> c.int ---
	@(link_name = "mdcore_entity_lookup")
	entity_lookup :: proc(name: [^]u8, name_size: c.size_t) -> ^Md_Entity ---
}
