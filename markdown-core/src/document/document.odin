// The document model: what a Markdown source says, with no fonts, colors,
// or sizes. The layout package gives it a look.
package document

import "../base"
import "core:bytes"

Inline :: enum u8 {
	Bold,
	Italic,
	Code,
	Link,
	Image, // the alternative text of an image
	Strike,
	// The number of a footnote, in the place of its reference in the
	// source ("[^label]", "^[text]"). `Span.link` is that number.
	Note,
	// A mark of the source that shows as text: the "**" of bold text
	// that the caret is in (`Document.reveal`).
	Mark,
}

Inline_Set :: bit_set[Inline;u8]

// A run of text with one style. The spans of a text are in order and cover
// all of its bytes.
Span :: struct {
	start, end: int, // byte offsets in Text.bytes
	style:      Inline_Set,
	link:       int, // index + 1 in Document.links; 0 = no link
}

Text :: struct {
	bytes: [dynamic]u8, // UTF-8
	spans: [dynamic]Span,
}

Block_Kind :: enum u8 {
	Paragraph,
	Heading,
	Code,
	Rule,
	Table,
}

Marker :: enum u8 {
	None,
	Bullet,
	Number,
	Task_Open,
	Task_Done,
	// The first block of the definition of a footnote ("[^label]: "):
	// `number` is the number of the footnote, 0 for one with no
	// reference.
	Note,
}

// Where a block stands in a list, for the space above it.
Spacing :: enum u8 {
	Block, // a block of its own
	List_Start, // first block of the first item of a top-level list
	Item, // first block of another item
	Continuation, // a later block of an item
}

// What a block is for a layout, but its texts: each field has one value,
// so two of these compare with `==`. A new field that a layout reads goes
// in here (or, a text, in `Block` and in `layout_equal`).
Shape :: struct {
	kind:        Block_Kind,
	marker:      Marker,
	spacing:     Spacing,
	// How many empty paragraphs come after the block: lines of the
	// source with nothing in them that are a paragraph of their own when
	// text is typed into them (`empties.odin`). The page shows each as
	// an empty line. Small, and here, so a block is no larger for it.
	empties:     u16,
	level:       int, // heading: 1 to 6
	number:      int, // marker == .Number
	list_depth:  int,
	quote_depth: int,
	columns:     int, // table
	// The mark of the line of the block is in its text, as a mark that
	// shows (`Document.reveal`): the "#" of a heading, the ">" of a quote.
	mark_shown:  bool,
	// The block is of the definition of a footnote: its first block
	// (`marker` is `.Note`), a later block of its item, or a block of a
	// list in its text. A page that is read shows none of these in their
	// place.
	noted:       bool,
	// A list item with nothing in it at the caret whose mark has nothing
	// after it ("-", "1."): the mark is plain text that is being typed,
	// no list item yet (`typed_mark`). A layout draws no bullet and no
	// number for it and puts it where its line starts.
	typed:       bool,
}

Block :: struct {
	// What a layout reads: the shape and the texts. Two blocks that are
	// the same in these get the same records (`layout_equal`).
	using shape: Shape,
	text:        Text, // paragraph, heading, code
	language:    string, // code: the info string's first word
	// Table: row-major cells, the first row is the header.
	cells:       [dynamic]Text,
	aligns:      [dynamic]base.Align,

	// What no layout reads. A change to one of these needs no new records.
	// The start of the block's first line in the source; for the first
	// block of a list item or a quote, the line of their mark. Counted
	// from the start of the block's part (`Part.source`), so a change
	// of the source moves the blocks after it with one number for each
	// part. See `block_source`.
	source:      int,
	// A task marker: the byte between its "[" and "]", counted as
	// `source` is; 0 for no task. Its line: `task_line`.
	task_mark:   int,
	done:        bool, // the block stands directly in a checked task item
	fenced:      bool, // code: between two fence lines, not code by its indent
	// Code in a fence that has its closing fence: the last line of the
	// block. The parser says: a line of the block after the fence that
	// is no line of the code.
	closed:      bool,
	// How many spaces and tabs the source has after the end of the text
	// of a paragraph or a heading, on its last line: Markdown leaves
	// them out of the text, and a caret has a place after each of them
	// (`Address.spaces`). 0 for each other block. Counted with the empty
	// paragraphs (`count_empties`).
	end_spaces:  u16,
	// How many bytes of the source the lines of the block have, from
	// `source`: to the start of the line after its last one (the
	// parser says; the closing fence of code and the line under a
	// heading are lines of the block, the empty lines after it are not).
	lines:       u32,
	item:        int, // the list item that the block stands directly in: a number from 1, 0 for none
}

// The limit of the parser for the uses of definitions of links, for a
// text of a size: see `MD_PARSER.ref_def_use` in the parser copy.
@(private)
defs_limit :: proc(size: int) -> int {
	return 16 * min(size, 1024 * 1024 / 16)
}

// The definition of a link in the source ("[name]: target").
Def :: struct {
	start, end: int, // its range of the source
	// A number for the first word of its name, small letters for
	// capital ones (`word_number`). Text that uses the definition has
	// that word. `always`: the name has a byte that this does not
	// cover (a letter that is not ASCII, a backslash), so each text
	// can use it.
	word:       u64,
	always:     bool,
}

// A number for a word, the same for capital and small ASCII letters
// (the FNV-1a hash of its bytes, with small letters for capital ones).
@(private)
word_number :: proc(word: []u8) -> (number: u64) {
	number = 0xcbf29ce484222325
	for ch in word {
		number = (number ~ u64(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch)) * 0x100000001b3
	}
	return
}

// True for a byte that ends a word of a name: white space and the two
// brackets.
@(private)
ends_word :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '[' || ch == ']'
}

// True for a word of a name that `word_number` covers: the parser takes
// two names as one by rules for all of Unicode (capital and small
// letters, kinds of white space), and a backslash is a byte of a name.
@(private)
plain_word :: proc(word: []u8) -> bool {
	for ch in word {
		if ch >= 0x80 || ch == '\\' || ch < ' ' {
			return false
		}
	}
	return true
}

// Fills in what a definition says of its name. `text` is its source,
// from the "[" of the name on.
@(private)
def_name :: proc(def: ^Def, text: []u8) {
	at := 1
	for at < len(text) && (text[at] == ' ' || text[at] == '\t') {
		at += 1
	}
	first := at
	for at < len(text) && !ends_word(text[at]) {
		at += 1
	}
	def.word = word_number(text[first:at])
	// A name that starts in the next line is not covered either.
	def.always = first == at || !plain_word(text[first:at])
}

// The memory of one part of the document, in bytes. A little less than
// 16 KB, which the system's allocator gives with no room that is not
// used; the allocator of the core puts a few bytes of its own before the
// part. (One block more, and a part takes 20 KB from the system.)
PART_BYTES :: 16 * 1024 - 64

// How many blocks a part of the document has at most.
PART_BLOCKS :: (PART_BYTES - 3 * size_of(int)) / size_of(Block)

// A part of the document: blocks that are next to each other. The blocks
// are in parts, not in one array, so that a change to the document moves
// the blocks of one part only, and so that the layout can keep its records
// for each part by itself (`layout.Part`). A block stays at its address
// while its part has the same blocks.
Part :: struct {
	blocks: [PART_BLOCKS]Block,
	count:  int,
	// Where the part is in the source: the start of the first line of
	// its first block, and how many lines of the source end before it.
	// The offsets of its blocks count from here.
	source: int,
	line:   int,
}

#assert(size_of(Part) <= PART_BYTES)

Document :: struct {
	// An offset of the source whose marks show as text: each element
	// that has the offset in it or at one of its ends (bold text, code,
	// a link) has its two marks in the text of its block, as text of
	// the style `.Mark`. An editor sets it to the place of its caret,
	// so the marks around the caret show (`prepare`, `reveal_block`).
	// It is there only while a text has such marks: none for a reader,
	// and none for an offset that is in no element.
	reveal: Maybe(int),
	// The bytes at the start of the source that are no Markdown
	// (`hidden_start`: a byte order mark, front matter), and if its first
	// line opens front matter that nothing closes. A parse of all sets
	// them; an edit that can change them is one (`prepare`).
	hidden:   int,
	unclosed: bool,
	parts:  [dynamic]^Part,
	starts: [dynamic]int, // for each part, the number of its first block
	count:  int, // the blocks of all parts
	links:  [dynamic]string,
	// The footnotes of the document, from the last parse of all of the
	// source. A change of a piece keeps them: it is a parse of the piece
	// only when the piece has the footnotes that it had, in their order,
	// and then only their offsets change (`piece_footnotes`,
	// `notes_commit`). The labels are in `note_keys`.
	notes:       Footnotes,
	// For the label of each definition among them (as `footnote_key`
	// makes it), which of the notes it is. The document has the strings.
	note_keys:   map[string]int,
	// How many links the last parse of all of the source gave. An edit
	// adds the links of its blocks and takes none out; see `prepare`.
	links_parsed: int,
	// A table keeps a number of cells that is of the size of all of
	// the source at most (`MIN_TABLE_CELLS`), so another size can be
	// another table at any distance: the cells of the largest table so
	// far, and if a table lost rows to the limit. An edit takes
	// nothing off the first; see `prepare`.
	cells_most:  int,
	cells_cut:   bool,
	// The parser has a limit for the uses of definitions: 16 times the
	// size of what it parses, 1 MB at most (`defs_limit`). What the
	// uses so far count for in it, if a use had no room (it is text
	// then, and each use after it), and the longest definition. An
	// edit adds to the first and takes nothing off; see `prepare`.
	defs_used:   int,
	defs_cut:    bool,
	def_longest: int,
	// The list items so far: an item gets the next number, and no item
	// of the document has the number of another, also after edits.
	items:  int,
	// The definitions of links in the source ("[name]: target"): their
	// ranges of it, in its order. One changes text at any distance, so
	// a parse of a piece of the source gets the definitions of the
	// rest of it, and an edit that changes one is a parse of all.
	defs:   [dynamic]Def,
	// A definition has the mark of a quote between its lines, so its
	// text is no definition at another place. Then each edit is a parse
	// of all of the source.
	defs_marked: bool,
	// The Markdown text that the blocks came from. Each block has a range
	// of it (`block_source`), and a change to a block in place changes it
	// too (`set_task_done`), so it is always the text of the blocks.
	source: []u8,
}

// The range of the source that a block has: from the start of its first
// line to the start of the first line of the next block. So the ranges
// of all blocks are the source, with no byte two times. A block has the
// lines after it that are not a block: empty lines, the end of a code
// fence, raw HTML, the definition of a link. The first block also has
// such lines before it.
block_source :: proc(doc: ^Document, block: int) -> (start, end: int) {
	start = block == 0 ? 0 : block_start(doc, block)
	end = block + 1 < doc.count ? block_start(doc, block + 1) : len(doc.source)
	return
}

// The start of the first line of a block in the source.
block_start :: proc(doc: ^Document, block: int) -> int {
	part, slot := locate(doc, block)
	return doc.parts[part].source + doc.parts[part].blocks[slot].source
}

// The last block that starts at an offset of the source or before it; 0
// when the first block starts after it. The document has a block.
block_at_offset :: proc(doc: ^Document, offset: int) -> int {
	// The last part that starts at the offset or before it, then the
	// last block in it.
	lo, hi := 0, len(doc.parts)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.parts[mid].source <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return 0
	}
	part := doc.parts[lo - 1]
	first, last := 0, part.count
	for first < last {
		mid := (first + last) / 2
		if part.source + part.blocks[mid].source <= offset {
			first = mid + 1
		} else {
			last = mid
		}
	}
	return doc.starts[lo - 1] + first - 1
}

// How many lines of the source end between two offsets. A line ends
// with LF, CR LF (counted at its LF), or CR alone, as the parser reads
// lines.
@(private)
count_lines :: proc(source: []u8, from, to: int) -> (count: int) {
	first, last := max(from, 0), min(to, len(source))
	if first >= last {
		return 0
	}
	// Most text has no CR; then this is one count of a byte.
	if bytes.index_byte(source[first:min(last + 1, len(source))], '\r') < 0 {
		return bytes.count(source[first:last], {'\n'})
	}
	#no_bounds_check for at in first ..< last {
		ch := source[at]
		count += int(ch == '\n')
		if ch == '\r' && !(at + 1 < len(source) && source[at + 1] == '\n') {
			count += 1
		}
	}
	return
}

// A walk over the lines of a part: the line of an offset, then of a
// later one, with a count of the lines between the two only. It starts
// at the part (`part_lines`).
Line_Walk :: struct {
	line, counted: int, // the line of the offset `counted`, from 1
}

part_lines :: proc(part: ^Part) -> Line_Walk {
	return {part.line + 1, part.source}
}

// The source line, from 1, of an offset at `counted` of the walk or
// later.
line_to :: proc(doc: ^Document, walk: ^Line_Walk, at: int) -> int {
	walk.line += count_lines(doc.source, walk.counted, at)
	walk.counted = at
	return walk.line
}

// The source line of the mark of a task, from 1; 0 for a block that is
// no task. `part` is the part of the block.
task_line :: proc(doc: ^Document, part: ^Part, b: ^Block) -> int {
	if b.task_mark == 0 {
		return 0
	}
	return part.line + count_lines(doc.source, part.source, part.source + b.task_mark) + 1
}

// Makes the offsets of the blocks of some parts count from their part,
// and says where each of those parts is in the source. Before it, the
// offsets of their blocks count from the start of the source; the part
// before them, when there is one, is in order.
@(private)
anchor :: proc(doc: ^Document, first, last: int) {
	for p in first ..= min(last, len(doc.parts) - 1) {
		part := doc.parts[p]
		base := part.blocks[0].source
		part.line = p == 0 ? count_lines(doc.source, 0, base) : doc.parts[p - 1].line + count_lines(doc.source, doc.parts[p - 1].source, base)
		part.source = base
		for &b in part_blocks(part) {
			move_block(&b, -base)
		}
	}
}

// Moves the offsets of a block in the source.
@(private)
move_block :: proc(b: ^Block, by: int) {
	b.source += by
	if b.task_mark > 0 {
		b.task_mark += by
	}
}

// Adds a block at the end of the document.
append_block :: proc(doc: ^Document, b: Block) {
	if len(doc.parts) == 0 || doc.parts[len(doc.parts) - 1].count == PART_BLOCKS {
		append(&doc.parts, new(Part))
		append(&doc.starts, doc.count)
	}
	part := doc.parts[len(doc.parts) - 1]
	part.blocks[part.count] = b
	part.count += 1
	doc.count += 1
}

// The part that has the block with a number, and the place of the block
// in it. The number must be one of a block of the document.
locate :: proc(doc: ^Document, block: int) -> (part, slot: int) {
	// The last part that starts at or before the block.
	lo, hi := 0, len(doc.starts)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.starts[mid] <= block {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1, block - doc.starts[lo - 1]
}

// The block with a number, from 0. For one block: a procedure that goes
// through the blocks goes through the parts.
block_at :: proc(doc: ^Document, block: int) -> ^Block {
	part, slot := locate(doc, block)
	return &doc.parts[part].blocks[slot]
}

// The blocks of a part.
part_blocks :: proc(part: ^Part) -> []Block {
	return part.blocks[:part.count]
}

text_destroy :: proc(t: ^Text) {
	delete(t.bytes)
	delete(t.spans)
	t^ = {}
}

// Sets the state of the task whose mark is on a source line, in place: the
// marker of the item, and `done` of each block that stands directly in it
// (not of the items inside it, which have their own state). False when no
// task has its mark on that line. The result is the same as a new parse
// of the source with that mark changed, and the source gets that mark.
// `mark` gets the offset of the byte of the mark in the source when that
// byte changed, and `was` the byte that it had ("x" or "X").
set_task_done :: proc(doc: ^Document, line: int, done: bool, mark: ^int = nil, was: ^u8 = nil) -> bool {
	// The last part that starts on the line or before it.
	lo, hi := 0, len(doc.parts)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.parts[mid].line < line {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if line <= 0 || lo == 0 {
		return false
	}
	p := lo - 1
	part := doc.parts[p]
	// The lines of the marks go up with the blocks.
	lines := part_lines(part)
	for &b, slot in part_blocks(part) {
		if b.task_mark == 0 {
			continue
		}
		at := line_to(doc, &lines, part.source + b.task_mark)
		counted := lines.counted
		if at < line {
			continue
		}
		if at > line {
			break
		}
		b.marker = done ? .Task_Done : .Task_Open
		b.done = done
		if mark != nil && doc.source[counted] != (done ? 'x' : ' ') {
			mark^ = counted
			if was != nil {
				was^ = doc.source[counted]
			}
		}
		doc.source[counted] = done ? 'x' : ' '
		// The later blocks of the same item, which can come after
		// lists inside it. The item is over where its list is.
		from := slot + 1
		for later in doc.parts[p:] {
			for &next in part_blocks(later)[from:] {
				if next.list_depth < b.list_depth {
					return true
				}
				if next.item == b.item {
					next.done = done
				}
			}
			from = 0
		}
		return true
	}
	return false
}

// Frees all that a block owns.
@(private)
block_destroy :: proc(b: ^Block) {
	text_destroy(&b.text)
	delete(b.language)
	for &cell in b.cells {
		text_destroy(&cell)
	}
	delete(b.cells)
	delete(b.aligns)
	b^ = {}
}

destroy :: proc(doc: ^Document) {
	notes_destroy(&doc.notes)
	note_keys_destroy(doc)
	for part in doc.parts {
		for &b in part_blocks(part) {
			block_destroy(&b)
		}
		free(part)
	}
	delete(doc.parts)
	delete(doc.starts)
	for link in doc.links {
		delete(link)
	}
	delete(doc.links)
	delete(doc.defs)
	delete(doc.source)
	doc^ = {}
}

// The span that holds the byte at `index`.
span_at :: proc(t: ^Text, index: int) -> ^Span {
	return &t.spans[span_index(t, index)]
}

// The number of the span that holds the byte at `index`: the first one
// that ends after it. The text has one span or more.
span_index :: proc(t: ^Text, index: int) -> int {
	lo, hi := 0, len(t.spans) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if t.spans[mid].end <= index {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}
