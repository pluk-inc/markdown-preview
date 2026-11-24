// The document model: what a Markdown source says, with no fonts, colors,
// or sizes. The layout package gives it a look.
package document

import "../base"

Inline :: enum u8 {
	Bold,
	Italic,
	Code,
	Link,
	Image, // the alternative text of an image
	Strike,
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
}

// Where a block stands in a list, for the space above it.
Spacing :: enum u8 {
	Block, // a block of its own
	List_Start, // first block of the first item of a top-level list
	Item, // first block of another item
	Continuation, // a later block of an item
}

Block :: struct {
	kind:        Block_Kind,
	level:       int, // heading: 1 to 6
	text:        Text, // paragraph, heading, code
	language:    string, // code: the info string's first word
	marker:      Marker,
	number:      int, // marker == .Number
	task_line:   int, // a task marker: the source line of its "[ ]", from 1
	done:        bool, // the block stands directly in a checked task item
	item:        int, // the list item that the block stands directly in: a number from 1, 0 for none
	spacing:     Spacing,
	list_depth:  int,
	quote_depth: int,
	// Table: row-major cells, the first row is the header.
	cells:       [dynamic]Text,
	columns:     int,
	aligns:      [dynamic]base.Align,
}

Document :: struct {
	blocks: [dynamic]Block,
	links:  [dynamic]string,
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
// of the source with that mark changed.
set_task_done :: proc(doc: ^Document, line: int, done: bool) -> bool {
	if line <= 0 {
		return false
	}
	for &b, i in doc.blocks {
		if b.task_line != line {
			continue
		}
		b.marker = done ? .Task_Done : .Task_Open
		b.done = done
		// The later blocks of the same item, which can come after lists
		// inside it. The item is over where its list is.
		for &next in doc.blocks[i + 1:] {
			if next.list_depth < b.list_depth {
				break
			}
			if next.item == b.item {
				next.done = done
			}
		}
		return true
	}
	return false
}

destroy :: proc(doc: ^Document) {
	for &b in doc.blocks {
		text_destroy(&b.text)
		delete(b.language)
		for &cell in b.cells {
			text_destroy(&cell)
		}
		delete(b.cells)
		delete(b.aligns)
	}
	delete(doc.blocks)
	for link in doc.links {
		delete(link)
	}
	delete(doc.links)
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
