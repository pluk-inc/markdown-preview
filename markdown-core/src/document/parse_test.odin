package document

import "../base"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private = "file")
content :: proc(t: ^Text) -> string {
	return string(t.bytes[:])
}

// The source line of the task of a block, from 1; 0 for no task.
@(private = "file")
line_of_task :: proc(doc: ^Document, block: int) -> int {
	part, slot := locate(doc, block)
	return task_line(doc, doc.parts[part], &doc.parts[part].blocks[slot])
}

// The target of the link of a span; "" for no link.
@(private = "file")
target :: proc(doc: ^Document, span: Span) -> string {
	return span.link > 0 ? doc.links[span.link - 1] : ""
}

// Makes the source of a document another text, as the core does it.
@(private = "file")
change_to :: proc(doc: ^Document, after: string) -> Change {
	return apply(doc, edit_between(doc.source, after))
}

@(test)
test_paragraph_and_heading :: proc(t: ^testing.T) {
	doc := parse("# Title\n\nOne *two* **three** `four` ~~five~~\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 2)
	testing.expect_value(t, block_at(&doc, 0).kind, Block_Kind.Heading)
	testing.expect_value(t, block_at(&doc, 0).level, 1)
	testing.expect_value(t, content(&block_at(&doc, 0).text), "Title")
	body := &block_at(&doc, 1).text
	testing.expect_value(t, content(body), "One two three four five")
	testing.expect_value(t, span_at(body, 4).style, Inline_Set{.Italic})
	testing.expect_value(t, span_at(body, 8).style, Inline_Set{.Bold})
	testing.expect_value(t, span_at(body, 14).style, Inline_Set{.Code})
	testing.expect_value(t, span_at(body, 19).style, Inline_Set{.Strike})
}

@(test)
test_spans_cover_the_text :: proc(t: ^testing.T) {
	doc := parse("a [link](https://example.com) and *b **c** d*\n")
	defer destroy(&doc)
	text := &block_at(&doc, 0).text
	at := 0
	for span in text.spans {
		testing.expect_value(t, span.start, at)
		testing.expect(t, span.end > span.start)
		at = span.end
	}
	testing.expect_value(t, at, len(text.bytes))
	link := span_at(text, 2)
	testing.expect_value(t, link.style, Inline_Set{.Link})
	testing.expect_value(t, doc.links[link.link - 1], "https://example.com")
}

@(test)
test_lists :: proc(t: ^testing.T) {
	doc := parse("intro\n\n- one\n- two\n  - nested\n\n3. three\n4. four\n\n- [ ] open\n- [x] done\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 8)
	one, two, nested := block_at(&doc, 1), block_at(&doc, 2), block_at(&doc, 3)
	testing.expect_value(t, one.marker, Marker.Bullet)
	testing.expect_value(t, one.spacing, Spacing.List_Start)
	testing.expect_value(t, two.spacing, Spacing.Item)
	testing.expect_value(t, nested.list_depth, 2)
	testing.expect_value(t, nested.spacing, Spacing.Item)
	testing.expect_value(t, block_at(&doc, 4).marker, Marker.Number)
	testing.expect_value(t, block_at(&doc, 4).number, 3)
	testing.expect_value(t, block_at(&doc, 5).number, 4)
	testing.expect_value(t, block_at(&doc, 6).marker, Marker.Task_Open)
	testing.expect_value(t, block_at(&doc, 7).marker, Marker.Task_Done)
	testing.expect_value(t, content(&block_at(&doc, 7).text), "done")
}

@(test)
test_loose_item_continuation :: proc(t: ^testing.T) {
	doc := parse("- first\n\n  second\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 2)
	testing.expect_value(t, block_at(&doc, 0).marker, Marker.Bullet)
	testing.expect_value(t, block_at(&doc, 1).marker, Marker.None)
	testing.expect_value(t, block_at(&doc, 1).spacing, Spacing.Continuation)
}

@(test)
test_empty_item_keeps_its_marker :: proc(t: ^testing.T) {
	doc := parse("1.\n2. next\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 2)
	testing.expect_value(t, block_at(&doc, 0).marker, Marker.Number)
	testing.expect_value(t, block_at(&doc, 0).number, 1)
	testing.expect_value(t, content(&block_at(&doc, 0).text), "")
	testing.expect_value(t, block_at(&doc, 1).number, 2)
}

@(test)
test_item_that_starts_with_code_has_the_marker :: proc(t: ^testing.T) {
	doc := parse("1. ```\n   code\n   ```\n")
	defer destroy(&doc)
	testing.expect_value(t, block_at(&doc, 0).kind, Block_Kind.Code)
	testing.expect_value(t, block_at(&doc, 0).marker, Marker.Number)
}

@(test)
test_code_block :: proc(t: ^testing.T) {
	doc := parse("````odin\na | b\n```\n--- | ---\n\nlast\n````\n\n> quoted\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 2)
	code := block_at(&doc, 0)
	testing.expect_value(t, code.kind, Block_Kind.Code)
	testing.expect_value(t, code.language, "odin")
	testing.expect_value(t, content(&code.text), "a | b\n```\n--- | ---\n\nlast")
	testing.expect_value(t, block_at(&doc, 1).quote_depth, 1)
}

@(test)
test_table :: proc(t: ^testing.T) {
	doc := parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | **2** |\n\n```inline``` text\n\n| x | y |\n|---|---|\n| 1 | 2 |\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 3)
	table := block_at(&doc, 0)
	testing.expect_value(t, table.kind, Block_Kind.Table)
	testing.expect_value(t, table.columns, 3)
	testing.expect_value(t, len(table.cells), 6) // the short row gets an empty cell
	testing.expect_value(t, table.aligns[1], base.Align.Center)
	testing.expect_value(t, table.aligns[2], base.Align.Right)
	testing.expect_value(t, content(&table.cells[4]), "2")
	testing.expect_value(t, content(&table.cells[5]), "")
	// A line of inline code is not a code fence: the next table is a table.
	testing.expect_value(t, block_at(&doc, 2).kind, Block_Kind.Table)
}

@(test)
test_table_cell_limit :: proc(t: ^testing.T) {
	// 30 columns and 3,000 rows of one cell ask for 90,000 cells from 6 KB.
	// The parser itself refuses such a table only above 32 columns.
	COLUMNS :: 30
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "|")
	for _ in 0 ..< COLUMNS {strings.write_string(&b, "a|")}
	strings.write_string(&b, "\n|")
	for _ in 0 ..< COLUMNS {strings.write_string(&b, "-|")}
	strings.write_string(&b, "\n")
	for _ in 0 ..< 3000 {strings.write_string(&b, "a|\n")}
	strings.write_string(&b, "\nafter\n")
	source := strings.to_string(b)
	doc := parse(source)
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 2)
	table := block_at(&doc, 0)
	testing.expect_value(t, table.kind, Block_Kind.Table)
	testing.expect_value(t, table.columns, COLUMNS)
	limit := MIN_TABLE_CELLS + len(source)
	testing.expect(t, len(table.cells) > MIN_TABLE_CELLS)
	testing.expect(t, len(table.cells) <= limit)
	testing.expect(t, len(table.cells) > limit - COLUMNS) // cut at the limit, not before
	testing.expect_value(t, len(table.cells) % COLUMNS, 0)
	testing.expect_value(t, content(&block_at(&doc, 1).text), "after")
}

@(test)
test_sparse_wide_table_is_text :: proc(t: ^testing.T) {
	// Above 32 columns the parser reads a table of mostly missing cells as
	// a paragraph.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "|")
	for _ in 0 ..< 100 {strings.write_string(&b, "a|")}
	strings.write_string(&b, "\n|")
	for _ in 0 ..< 100 {strings.write_string(&b, "-|")}
	strings.write_string(&b, "\n")
	for _ in 0 ..< 2000 {strings.write_string(&b, "a|\n")}
	doc := parse(strings.to_string(b))
	defer destroy(&doc)
	for i in 0 ..< doc.count {
		testing.expect(t, block_at(&doc, i).kind != .Table)
	}
}

@(test)
test_entities_and_breaks :: proc(t: ^testing.T) {
	doc := parse("a &amp; b &#65; &#x1F600; &nope;\nsoft  \nhard\n")
	defer destroy(&doc)
	testing.expect_value(t, content(&block_at(&doc, 0).text), "a & b A \U0001F600 &nope; soft\nhard")
}

@(test)
test_white_space_collapses :: proc(t: ^testing.T) {
	doc := parse("a    b\tc `x  y`\n\n    code  stays\n")
	defer destroy(&doc)
	testing.expect_value(t, content(&block_at(&doc, 0).text), "a b c x  y")
	testing.expect_value(t, content(&block_at(&doc, 1).text), "code  stays")
}

@(test)
test_raw_html_is_dropped :: proc(t: ^testing.T) {
	doc := parse("<div>\nblock\n</div>\n\ntext <b>bold</b> end\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 1)
	testing.expect_value(t, content(&block_at(&doc, 0).text), "text bold end")
}

@(test)
test_empty_and_rule :: proc(t: ^testing.T) {
	empty := parse("")
	defer destroy(&empty)
	testing.expect_value(t, empty.count, 0)
	rule := parse("---\n")
	defer destroy(&rule)
	testing.expect_value(t, rule.count, 1)
	testing.expect_value(t, block_at(&rule, 0).kind, Block_Kind.Rule)
}

@(test)
test_a_finished_text_keeps_no_spare_room :: proc(t: ^testing.T) {
	doc := parse("# Title\n\nPlain words and *some* in `code`.\n\n```\nline\n```\n\n| a | b |\n|---|---|\n| 1 |   |\n")
	defer destroy(&doc)
	check :: proc(t: ^testing.T, text: ^Text) {
		testing.expect_value(t, cap(text.bytes), len(text.bytes))
		testing.expect_value(t, cap(text.spans), len(text.spans))
	}
	texts := 0
	for i in 0 ..< doc.count {
		block := block_at(&doc, i)
		check(t, &block.text)
		texts += 1
		for &cell in block.cells {
			check(t, &cell)
			texts += 1
		}
	}
	// The heading, the paragraph, the code block, the table's own (empty)
	// text, and its four cells, one of them empty.
	testing.expect_value(t, texts, 8)
	// The text itself is all there.
	testing.expect_value(t, string(block_at(&doc, 1).text.bytes[:]), "Plain words and some in code.")
	testing.expect_value(t, len(block_at(&doc, 1).text.spans), 5)
}

@(test)
test_task_items_know_their_line_and_state :: proc(t: ^testing.T) {
	doc := parse("# List\n\n- [ ] open\n- [x] done\n\n  more of done\n  - [ ] inside\n- plain\n\nafter\n")
	defer destroy(&doc)
	// heading, open, done, more of done, inside, plain, after
	testing.expect_value(t, doc.count, 7)
	open, done, more, inside, plain, after := block_at(&doc, 1), block_at(&doc, 2), block_at(&doc, 3), block_at(&doc, 4), block_at(&doc, 5), block_at(&doc, 6)
	testing.expect_value(t, open.marker, Marker.Task_Open)
	testing.expect_value(t, line_of_task(&doc, 1), 3)
	testing.expect_value(t, open.done, false)
	testing.expect_value(t, done.marker, Marker.Task_Done)
	testing.expect_value(t, line_of_task(&doc, 2), 4)
	testing.expect_value(t, done.done, true)
	// A later block of the checked item is done too; an item inside it has
	// its own state.
	testing.expect_value(t, more.done, true)
	testing.expect_value(t, more.marker, Marker.None)
	testing.expect_value(t, inside.marker, Marker.Task_Open)
	testing.expect_value(t, line_of_task(&doc, 4), 7)
	testing.expect_value(t, inside.done, false)
	testing.expect_value(t, plain.done, false)
	testing.expect_value(t, line_of_task(&doc, 5), 0)
	testing.expect_value(t, after.done, false)
}

@(test)
test_task_lines_count_each_kind_of_line_ending :: proc(t: ^testing.T) {
	// CR alone, then CR LF, then LF: each ends one line.
	doc := parse("- [ ] one\r- [ ] two\r\n- [x] three\n- [ ] four\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 4)
	for i in 0 ..< doc.count {
		testing.expect_value(t, line_of_task(&doc, i), i + 1)
	}
}

@(test)
test_a_task_set_in_place_is_the_document_of_the_changed_source :: proc(t: ^testing.T) {
	// Line 1 has a later paragraph, a list inside, and a paragraph after
	// that list; line 4 is an item inside; line 8 is in a quote.
	Case :: struct {
		line:   int,
		done:   bool,
		source: string,
	}
	BEFORE :: "- [ ] one\n\n  more of one\n  - [x] inside\n\n  last of one\n- [ ] two\n> - [x] quoted\n\nafter\n"
	cases := []Case {
		{1, true, "- [x] one\n\n  more of one\n  - [x] inside\n\n  last of one\n- [ ] two\n> - [x] quoted\n\nafter\n"},
		{4, false, "- [ ] one\n\n  more of one\n  - [ ] inside\n\n  last of one\n- [ ] two\n> - [x] quoted\n\nafter\n"},
		{7, true, "- [ ] one\n\n  more of one\n  - [x] inside\n\n  last of one\n- [x] two\n> - [x] quoted\n\nafter\n"},
		{8, false, "- [ ] one\n\n  more of one\n  - [x] inside\n\n  last of one\n- [ ] two\n> - [ ] quoted\n\nafter\n"},
	}
	for c in cases {
		doc := parse(BEFORE)
		defer destroy(&doc)
		want := parse(c.source)
		defer destroy(&want)
		testing.expect(t, set_task_done(&doc, c.line, c.done))
		testing.expect_value(t, string(doc.source), c.source)
		testing.expect_value(t, doc.count, want.count)
		for i in 0 ..< want.count {
			testing.expect_value(t, block_at(&doc, i).marker, block_at(&want, i).marker)
			testing.expect_value(t, block_at(&doc, i).done, block_at(&want, i).done)
		}
	}
	{
		// An item with no block of its own, a list in it, then a later
		// block of it: that block is not in the task before it.
		doc := parse("- [ ] a\n- - b\n\n  tail\n")
		defer destroy(&doc)
		want := parse("- [x] a\n- - b\n\n  tail\n")
		defer destroy(&want)
		testing.expect(t, set_task_done(&doc, 1, true))
		for i in 0 ..< want.count {
			testing.expect_value(t, block_at(&doc, i).done, block_at(&want, i).done)
		}
	}
	// No task has its mark on these lines.
	doc := parse(BEFORE)
	defer destroy(&doc)
	testing.expect(t, !set_task_done(&doc, 3, true))
	testing.expect(t, !set_task_done(&doc, 0, true))
	testing.expect(t, !set_task_done(&doc, 99, true))
}

@(test)
test_the_blocks_of_a_long_document_are_in_parts :: proc(t: ^testing.T) {
	// One paragraph for each number, and a task near the end whose item
	// has a later block in the next part.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	COUNT :: 2 * PART_BLOCKS + PART_BLOCKS / 2
	for i in 0 ..< COUNT {
		fmt.sbprintf(&b, "p%d\n\n", i)
	}
	doc := parse(strings.to_string(b))
	defer destroy(&doc)
	testing.expect_value(t, doc.count, COUNT)
	testing.expect_value(t, len(doc.parts), 3)
	testing.expect_value(t, doc.parts[2].count, PART_BLOCKS / 2)
	for i in 0 ..< COUNT {
		part, slot := locate(&doc, i)
		testing.expect_value(t, part, i / PART_BLOCKS)
		testing.expect_value(t, slot, i % PART_BLOCKS)
		testing.expect_value(t, content(&block_at(&doc, i).text), fmt.tprintf("p%d", i))
	}
}

@(test)
test_a_task_item_that_goes_into_the_next_part_is_set_in_all_of_it :: proc(t: ^testing.T) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for i in 0 ..< PART_BLOCKS - 1 {
		fmt.sbprintf(&b, "p%d\n\n", i)
	}
	// The last block of the first part, and the first one of the next.
	strings.write_string(&b, "- [ ] task\n\n  later\n")
	doc := parse(strings.to_string(b))
	defer destroy(&doc)
	testing.expect_value(t, len(doc.parts), 2)
	testing.expect(t, set_task_done(&doc, 2 * PART_BLOCKS - 1, true))
	testing.expect_value(t, block_at(&doc, PART_BLOCKS - 1).marker, Marker.Task_Done)
	testing.expect(t, block_at(&doc, PART_BLOCKS).done)
}

@(private = "file")
between :: proc(doc: ^Document, from, to: Address) -> string {
	out: [dynamic]u8
	text_between(doc, from, to, &out)
	return string(out[:])
}

@(test)
test_the_text_between_two_addresses :: proc(t: ^testing.T) {
	// Block 0: a heading. 1: a paragraph. 2: a rule. 3: code with blank
	// lines, also at its end. 4: a table with an empty cell. 5: the end.
	doc := parse("# Title\n\nSome words.\n\n---\n\n```\none\n\ntwo\n\n```\n\n| a |  |\n| - | - |\n| 1 | 2 |\n\nEnd.\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 6)
	first, last, ok := text_ends(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, first, Address{0, 0, 0})
	testing.expect_value(t, last, Address{5, 0, 4})
	// Each text on a line of its own; a rule gives no line; the blank
	// lines of the code stay; the empty cell gives an empty line.
	all_text := between(&doc, first, last)
	defer delete(all_text)
	testing.expect_value(t, all_text, "Title\nSome words.\none\n\ntwo\n\na\n\n1\n2\nEnd.")
	// From the middle of one text to the middle of another.
	part := between(&doc, Address{1, 0, 5}, Address{3, 0, 2})
	defer delete(part)
	testing.expect_value(t, part, "words.\non")
	// In one text.
	one := between(&doc, Address{1, 0, 0}, Address{1, 0, 4})
	defer delete(one)
	testing.expect_value(t, one, "Some")
	// From one cell to another: the cells between them, each on a line.
	cells := between(&doc, Address{4, 0, 0}, Address{4, 3, 1})
	defer delete(cells)
	testing.expect_value(t, cells, "a\n\n1\n2")
	// Texts with nothing in the range at the two ends give no line.
	ends := between(&doc, Address{0, 0, 5}, Address{1, 0, 4})
	defer delete(ends)
	testing.expect_value(t, ends, "Some")
	// Nothing for a document with no text.
	rules := parse("***\n\n***\n")
	defer destroy(&rules)
	_, _, any := text_ends(&rules)
	testing.expect(t, !any)
}

@(test)
test_addresses_are_in_reading_order :: proc(t: ^testing.T) {
	testing.expect(t, before(Address{0, 0, 9}, Address{1, 0, 0}))
	testing.expect(t, before(Address{1, 0, 9}, Address{1, 1, 0}))
	testing.expect(t, before(Address{1, 1, 0}, Address{1, 1, 1}))
	testing.expect(t, !before(Address{1, 1, 1}, Address{1, 1, 1}))
	testing.expect(t, !before(Address{2, 0, 0}, Address{1, 5, 5}))
}

// Paragraphs, one for each number, with some other kinds between them.
@(private = "file")
numbered :: proc(count: int, changed := -1, extra := -1, without := -1) -> string {
	b := strings.builder_make()
	for i in 0 ..< count {
		if i == without {
			continue
		}
		if i == extra {
			strings.write_string(&b, "An extra paragraph.\n\n- with\n- a list\n\n")
		}
		switch {
		case i == changed:
			fmt.sbprintf(&b, "Paragraph %d with **other** words.\n\n", i)
		case i % 17 == 5:
			fmt.sbprintf(&b, "| a%d | b |\n| - | - |\n| 1 | [l](https://example.com/%d) |\n\n", i, i)
		case i % 17 == 9:
			fmt.sbprintf(&b, "- [ ] task %d\n\n", i)
		case i % 17 == 13:
			fmt.sbprintf(&b, "```\ncode %d\n```\n\n", i)
		case:
			fmt.sbprintf(&b, "Paragraph %d with a [link](https://example.com/%d).\n\n", i, i)
		}
	}
	return strings.to_string(b)
}

// Checks that a document is the one that a parse of `source` gives, and
// that its parts agree with each other.
@(private = "file")
expect_document :: proc(t: ^testing.T, doc: ^Document, source: string, loc := #caller_location) {
	want := parse(source)
	defer destroy(&want)
	testing.expect_value(t, doc.count, want.count, loc)
	testing.expect_value(t, len(doc.parts), len(doc.starts), loc)
	count := 0
	for part, p in doc.parts {
		testing.expect_value(t, doc.starts[p], count, loc)
		testing.expect(t, part.count > 0 && part.count <= PART_BLOCKS, loc = loc)
		count += part.count
	}
	testing.expect_value(t, count, doc.count, loc)
	testing.expect_value(t, string(doc.source), source, loc)
	for i in 0 ..< min(doc.count, want.count) {
		a, b := block_at(doc, i), block_at(&want, i)
		testing.expect(t, layout_equal(a, b), loc = loc)
		testing.expect_value(t, block_start(doc, i), block_start(&want, i), loc)
		testing.expect_value(t, line_of_task(doc, i), line_of_task(&want, i), loc)
		testing.expect_value(t, a.done, b.done, loc)
		// The same blocks are in one item; the number of the item is
		// not the same after an edit.
		if i > 0 {
			testing.expect_value(t, a.item == block_at(doc, i - 1).item, b.item == block_at(&want, i - 1).item, loc)
		}
		testing.expect_value(t, a.item == 0, b.item == 0, loc)
		for span, n in a.text.spans {
			testing.expect_value(t, target(doc, span), target(&want, b.text.spans[n]), loc)
		}
		for &cell, c in a.cells {
			for span, n in cell.spans {
				testing.expect_value(t, target(doc, span), target(&want, b.cells[c].spans[n]), loc)
			}
		}
	}
	// The definitions of links are where the source has them.
	testing.expect_value(t, len(doc.defs), len(want.defs), loc)
	testing.expect_value(t, doc.defs_marked, want.defs_marked, loc)
	for def, i in doc.defs[:min(len(doc.defs), len(want.defs))] {
		testing.expect_value(t, def, want.defs[i], loc)
	}
	// Each part says where it is.
	for part in doc.parts {
		testing.expect_value(t, part.blocks[0].source, 0, loc)
		testing.expect_value(t, part.line, count_lines(doc.source, 0, part.source), loc)
	}
}

@(test)
test_a_change_in_the_middle_keeps_the_other_blocks_in_place :: proc(t: ^testing.T) {
	COUNT :: 5 * PART_BLOCKS
	AT :: 2 * PART_BLOCKS + 7
	before, after := numbered(COUNT), numbered(COUNT, changed = AT)
	defer delete(before)
	defer delete(after)
	doc := parse(before)
	defer destroy(&doc)
	first, last := block_at(&doc, 3), block_at(&doc, COUNT - 3)
	changed, beside := block_at(&doc, AT), block_at(&doc, AT + 1)
	parts := [3]^Part{doc.parts[0], doc.parts[2], doc.parts[4]}
	change := change_to(&doc, after)
	testing.expect_value(t, change.first, AT)
	testing.expect_value(t, change.removed, 1)
	testing.expect_value(t, change.added, 1)
	// As many blocks as before: no part was made again. The block is at
	// the place of the one before it, and so is each other block.
	testing.expect_value(t, change.parts_removed, 0)
	testing.expect_value(t, change.parts_added, 0)
	testing.expect(t, doc.parts[0] == parts[0] && doc.parts[2] == parts[1] && doc.parts[4] == parts[2])
	testing.expect(t, block_at(&doc, 3) == first && block_at(&doc, COUNT - 3) == last)
	testing.expect(t, block_at(&doc, AT) == changed && block_at(&doc, AT + 1) == beside)
	expect_document(t, &doc, after)
	// The addresses before the block, in it, and after it.
	now, same := moved(change, Address{AT - 1, 0, 4})
	testing.expect(t, same && now == Address{AT - 1, 0, 4})
	// In the block that changed, "Paragraph 123 with a link." to
	// "Paragraph 123 with other words.": an address in the text that
	// is the same at the start stays, one in the text that is the same
	// at the end (the full stop) moves with it, and one in the text
	// that changed is at the start of the block.
	old_text, new_text := len("Paragraph 123 with a link."), len("Paragraph 123 with other words.")
	now, same = moved(change, Address{AT, 0, 9})
	testing.expect(t, same && now == Address{AT, 0, 9})
	now, same = moved(change, Address{AT, 0, old_text})
	testing.expect(t, same && now == Address{AT, 0, new_text})
	now, same = moved(change, Address{AT, 0, 22})
	testing.expect(t, !same && now == Address{AT, 0, 0})
	now, same = moved(change, Address{AT + 1, 2, 4})
	testing.expect(t, same && now == Address{AT + 1, 2, 4})
}

@(test)
test_blocks_that_come_and_go_move_the_numbers_after_them :: proc(t: ^testing.T) {
	COUNT :: 4 * PART_BLOCKS
	AT :: PART_BLOCKS + 20
	base := numbered(COUNT)
	defer delete(base)
	{
		// Three blocks more (a paragraph and a list of two items).
		after := numbered(COUNT, extra = AT)
		defer delete(after)
		doc := parse(base)
		defer destroy(&doc)
		last := block_at(&doc, COUNT - 1)
		change := change_to(&doc, after)
		testing.expect_value(t, change.first, AT)
		testing.expect_value(t, change.removed, 0)
		testing.expect_value(t, change.added, 3)
		expect_document(t, &doc, after)
		now, same := moved(change, Address{AT, 0, 2})
		testing.expect(t, same && now == Address{AT + 3, 0, 2})
		// The last part did not move; the block has another number.
		testing.expect(t, block_at(&doc, COUNT + 2) == last)
	}
	{
		// One block fewer.
		after := numbered(COUNT, without = AT)
		defer delete(after)
		doc := parse(base)
		defer destroy(&doc)
		change := change_to(&doc, after)
		testing.expect_value(t, change.first, AT)
		testing.expect_value(t, change.removed, 1)
		testing.expect_value(t, change.added, 0)
		// An address in the block that went is at the block that came
		// to its number.
		gone, same := moved(change, Address{AT, 0, 3})
		testing.expect(t, !same && gone == Address{AT, 0, 0})
		expect_document(t, &doc, after)
		now, kept := moved(change, Address{AT + 1, 0, 0})
		testing.expect(t, kept && now == Address{AT, 0, 0})
	}
}

@(test)
test_a_change_at_each_end_and_of_all_of_the_document :: proc(t: ^testing.T) {
	COUNT :: 3 * PART_BLOCKS
	base := numbered(COUNT)
	defer delete(base)
	cases := [?]string {
		numbered(COUNT, changed = 0),
		numbered(COUNT, changed = COUNT - 1),
		numbered(COUNT, extra = 0),
		numbered(COUNT + 40),
		numbered(PART_BLOCKS / 2),
		numbered(COUNT, without = 0),
		"# Another document\n\nWith two blocks.\n",
		"",
		base,
	}
	for after, i in cases {
		doc := parse(base)
		change := change_to(&doc, after)
		expect_document(t, &doc, after)
		testing.expect_value(t, change.count, doc.count)
		// An address of the old end is in the new document, or at its
		// first block when that has none.
		end, _ := moved(change, Address{3 * PART_BLOCKS - 1, 0, 0})
		testing.expect(t, end.block >= 0 && end.block < max(doc.count, 1))
		if after == base {
			// The same text: no block is another one, no part is made again.
			testing.expect_value(t, change.removed + change.added, 0)
			testing.expect_value(t, change.parts_removed + change.parts_added, 0)
		}
		// And back again, also from an empty document.
		change_to(&doc, base)
		expect_document(t, &doc, base)
		destroy(&doc)
		// The first six are made here; the others are constants and
		// the base.
		if i < 6 {
			delete(after)
		}
	}
}

@(test)
test_a_task_mark_and_a_link_number_change_no_block_for_a_layout :: proc(t: ^testing.T) {
	// A line more at the top moves the line of the task; a link more at
	// the top moves the number of the link after it. A checked mark is
	// another marker, so that block is another one.
	doc := parse("First.\n\n- [ ] task\n\nA [link](https://a.example).\n")
	defer destroy(&doc)
	task := block_at(&doc, 1)
	change := change_to(&doc, "First\nwith a [link](https://b.example).\n\n- [ ] task\n\nA [link](https://a.example).\n")
	testing.expect_value(t, change.first, 0)
	testing.expect_value(t, change.removed, 1)
	testing.expect_value(t, change.added, 1)
	testing.expect_value(t, line_of_task(&doc, 1), 4)
	testing.expect_value(t, target(&doc, block_at(&doc, 2).text.spans[1]), "https://a.example")
	testing.expect_value(t, target(&doc, block_at(&doc, 0).text.spans[1]), "https://b.example")
	_ = task
}

// The source of each block of a document, in order.
@(private = "file")
expect_sources :: proc(t: ^testing.T, source: string, want: []string, loc := #caller_location) {
	doc := parse(source)
	defer destroy(&doc)
	testing.expect_value(t, doc.count, len(want), loc)
	for i in 0 ..< min(doc.count, len(want)) {
		start, end := block_source(&doc, i)
		testing.expect_value(t, string(doc.source[start:end]), want[i], loc)
	}
}

@(test)
test_a_block_knows_its_lines_of_the_source :: proc(t: ^testing.T) {
	// A block has its first line with all marks before its text, and the
	// lines after it that are no block: empty lines, the line under a
	// heading, the end of a fence.
	expect_sources(
		t,
		"# Title\n\nOne\ntwo\n\nHead\n====\n***\n```odin\ncode\n```\n\n    more code\n\n| a |\n| - |\n| 1 |\n\nlast",
		{
			"# Title\n\n",
			"One\ntwo\n\n",
			"Head\n====\n",
			"***\n",
			"```odin\ncode\n```\n\n",
			"    more code\n\n",
			"| a |\n| - |\n| 1 |\n\n",
			"last",
		},
	)
	// Blocks in lists and quotes: each starts at the start of its line,
	// before the marks of what it is in.
	expect_sources(
		t,
		"- one\n- two\n\n  more\n  - [ ] in\n    ```\n    x\n    ```\n> quote\n> > # deep\n\n1. a\r\n2. b\r\n",
		{
			"- one\n",
			"- two\n\n",
			"  more\n",
			"  - [ ] in\n",
			"    ```\n    x\n    ```\n",
			"> quote\n",
			"> > # deep\n\n",
			"1. a\r\n",
			"2. b\r\n",
		},
	)
	// A block with no text of its own still has its line: an image with
	// no words, an item with nothing in it, an empty fence.
	expect_sources(
		t,
		"![](a.png)\n\n-\n- x\n-\n\n```\n```\ntext\n",
		{"![](a.png)\n\n", "-\n", "- x\n", "-\n\n", "```\n```\n", "text\n"},
	)
	// What is no block goes with the block before it; before the first
	// block, with that one.
	expect_sources(
		t,
		"\n<div>\nraw\n</div>\n\nfirst [a]\n\n[a]: https://example.com\n\n<!-- note -->\n\nsecond\n",
		{"\n<div>\nraw\n</div>\n\nfirst [a]\n\n[a]: https://example.com\n\n<!-- note -->\n\n", "second\n"},
	)
	// The first block of a list item or a quote has the line of their
	// mark, also when its text starts on a later line. An item with only
	// raw HTML in it has its line too.
	expect_sources(
		t,
		"x\n\n-\n  foo\n- [ ]\n  task\n\n> \n> quote\n\n- <b>\n\n  </b>\n- > <i>\n\nend\n",
		{"x\n\n", "-\n  foo\n", "- [ ]\n  task\n\n", "> \n> quote\n\n", "- <b>\n\n  </b>\n", "- > <i>\n\n", "end\n"},
	)
	// An item keeps its line when a quote with nothing in it ends
	// before the first block of the item.
	expect_sources(t, "intro\n\n- >\n\n  tail\n", {"intro\n\n", "- >\n\n  tail\n"})
	expect_sources(t, "> <div>\n\nnext\n- a\n  - > <i>\n\n  b\n", {"> <div>\n\nnext\n", "- a\n", "  - > <i>\n\n", "  b\n"})
	expect_sources(t, "# title\n\n-\n  > <div></div>\n\n  later\n", {"# title\n\n", "-\n  > <div></div>\n\n  later\n"})
	// A line under definitions of links only is a rule; the rest of the
	// paragraph comes after it.
	expect_sources(t, "intro\n\n[a]: /x\n---\nend\n", {"intro\n\n[a]: /x\n", "---\n", "end\n"})
	expect_sources(
		t,
		"# Before\n\n[a]: /u\n    ---\ntext\n\nAfter\n",
		{"# Before\n\n[a]: /u\n", "    ---\n", "text\n\n", "After\n"},
	)
	// A paragraph keeps the definitions that it starts with.
	expect_sources(t, "one\n\n[a]: /x\ntwo [a]\n", {"one\n\n", "[a]: /x\ntwo [a]\n"})
}

@(test)
test_the_sources_of_the_blocks_are_the_source :: proc(t: ^testing.T) {
	source := numbered(3 * PART_BLOCKS)
	defer delete(source)
	doc := parse(source)
	defer destroy(&doc)
	at := 0
	for i in 0 ..< doc.count {
		start, end := block_source(&doc, i)
		testing.expect_value(t, start, at)
		testing.expect(t, end > start)
		at = end
	}
	testing.expect_value(t, at, len(source))
}

@(test)
test_an_edit_is_what_two_sources_do_not_have_in_common :: proc(t: ^testing.T) {
	Case :: struct {
		before, after: string,
		start, end:    int,
		text:          string,
	}
	cases := []Case {
		{"one two three", "one 2 three", 4, 7, "2"},
		{"one two", "one two three", 7, 7, " three"},
		{"one two three", "two three", 0, 4, ""},
		{"", "new", 0, 0, "new"},
		{"old", "", 0, 3, ""},
		{"same", "same", 4, 4, ""},
		// The same bytes at the two ends count one time.
		{"aaa", "aa", 2, 3, ""},
		{"aa", "aaa", 2, 2, "a"},
	}
	for c in cases {
		e := edit_between(transmute([]u8)c.before, c.after)
		testing.expect_value(t, e.start, c.start)
		testing.expect_value(t, e.end, c.end)
		testing.expect_value(t, e.text, c.text)
		testing.expect_value(t, edit_is_empty(e), c.before == c.after)
		now := edited(transmute([]u8)c.before, e)
		defer delete(now)
		testing.expect_value(t, string(now), c.after)
	}
	// A range that reaches out of the source is cut to it.
	out := edited(transmute([]u8)string("abc"), {2, 99, "X"})
	defer delete(out)
	testing.expect_value(t, string(out), "abX")
	out2 := edited(transmute([]u8)string("abc"), {-5, 1, "X"})
	defer delete(out2)
	testing.expect_value(t, string(out2), "Xbc")
}

@(test)
test_an_edit_that_a_piece_is_not_right_for_gives_the_document_too :: proc(t: ^testing.T) {
	Case :: struct {
		before, after: string,
	}
	long_target := strings.repeat("a", 5000)
	defer delete(long_target)
	uses := strings.repeat("[img] ", 30)
	defer delete(uses)
	limit_before := strings.concatenate({"[img]: /", long_target, "\n\nfirst\n\nsecond\n\nthird\n\nfourth\n\nfifth\n"})
	defer delete(limit_before)
	limit_after := strings.concatenate({"[img]: /", long_target, "\n\nfirst\n\nsecond\n\nthird ", uses, "\n\nfourth\n\nfifth\n"})
	defer delete(limit_after)
	// A table of 30 columns and 3,000 rows of one cell asks for more
	// cells than a source of its size can have: the rows that it keeps
	// are of the size of all of the source, also of text far from it.
	table := strings.builder_make()
	defer strings.builder_destroy(&table)
	strings.write_string(&table, "|")
	for _ in 0 ..< 30 {strings.write_string(&table, "a|")}
	strings.write_string(&table, "\n|")
	for _ in 0 ..< 30 {strings.write_string(&table, "-|")}
	strings.write_string(&table, "\n")
	for _ in 0 ..< 3000 {strings.write_string(&table, "a|\n")}
	table_before := strings.concatenate({strings.to_string(table), "\none\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix\n"})
	defer delete(table_before)
	table_after := strings.concatenate({strings.to_string(table), "\none\n\ntwo\n\nthree\n\nfour\n\nfive\n\nsix and thirty characters more, far away\n"})
	defer delete(table_after)
	cases := []Case {
		{table_before, table_after},
		// A list that the edit makes goes on in the list after it, whose
		// first block is in a list inside: "e" is item 3 then.
		{"x\n\n1. - b\n   - c\n2. e\n", "1. a\n\n1. - b\n   - c\n2. e\n"},
		{"x\n\n> 1. - b\n>    - c\n> 2. e\n", "> 1. a\n\n> 1. - b\n>    - c\n> 2. e\n"},
		// The parser takes names as one that have other bytes: a wide
		// space for a space, the Kelvin sign for "k", a sharp s for "ss".
		{"[note 1]: /n\n\nfirst\n\nsecond\n\nthird\n\nfourth\n\nfifth\n", "[note 1]: /n\n\nfirst\n\nsecond\n\nthird [note\u30001]\n\nfourth\n\nfifth\n"},
		{"[k]: /a\n\n[K-x]: /b\n\nfirst\n\nsecond\n\nthird\n\nfourth\n\nfifth\n", "[k]: /a\n\n[K-x]: /b\n\nfirst\n\nsecond\n\nthird [\u212a]\n\nfourth\n\nfifth\n"},
		{"[ss]: /s\n\nfirst\n\nsecond\n\nthird\n\nfourth\n\nfifth\n", "[ss]: /s\n\nfirst\n\nsecond\n\nthird [\u00df]\n\nfourth\n\nfifth\n"},
		// A name that starts in the next line of a quote.
		{"[far name]: /f\n\nfirst\n\nsecond\n\n> third\n\nfourth\n\nfifth\n", "[far name]: /f\n\nfirst\n\nsecond\n\n> third [\n> far name]\n\nfourth\n\nfifth\n"},
		// More uses of a long definition than the limit of the parser
		// for a small text has room for.
		{limit_before, limit_after},
	}
	for c in cases {
		doc := parse(c.before)
		defer destroy(&doc)
		change_to(&doc, c.after)
		expect_document(t, &doc, c.after)
		// And back.
		change_to(&doc, c.before)
		expect_document(t, &doc, c.before)
	}
}

// A source with each kind of block, and blocks in lists and quotes.
@(private = "file")
mixed :: proc(sections: int) -> string {
	b := strings.builder_make()
	for i in 0 ..< sections {
		fmt.sbprintf(&b, "## Section %d\n\nA paragraph of section %d\nwith two lines, a [link](https://example.com/%d), [ref one] and [two][ref two].\n\n", i, i, i)
		if i % 3 == 1 {
			fmt.sbprintf(&b, "[ref one]: https://one.example/%d\n[Ref Two]: <https://two.example> \"Title\"\n\n", i)
		}
		fmt.sbprintf(&b, "- item %d\n- [ ] task\n\n  more of the task\n  1. inside\n  2. inside\n     ```\n     code in a list\n     ```\n- last\n\n", i)
		fmt.sbprintf(&b, "> quote %d\n> > deep\n>\n> - in a quote\n\n", i)
		fmt.sbprintf(&b, "Setext %d\n---\n\n***\n\n<div>\nraw %d\n</div>\n\n<!-- a\n\ncomment -->\n\n", i, i)
		fmt.sbprintf(&b, "| a%d | b |\n|:-|-:|\n| 1 | **2** |\n\n    indented %d\n\n```odin\nfenced\n\nlines\n```\n", i, i)
		fmt.sbprintf(&b, "Text right after a fence.\r\n\r\n")
	}
	return strings.to_string(b)
}

@(test)
test_a_document_after_edits_is_the_document_of_its_source :: proc(t: ^testing.T) {
	// Texts that change what the lines around them are.
	PIECES := []string {
		"x", " ", "\n", "\n\n", "\r\n", "# ", "- ", "  ", "    ", "\t", "> ", ">", "1. ", "- [ ] ", "- [x] ", "```\n", "~~~\n",
		"| a | b |\n| - | - |\n", "|", "---\n", "===\n", "<div>\n", "<pre>\n", "</pre>\n", "<!--", "-->", "*", "`", "[", "](u)",
		"\n\nA new paragraph.\n\n", "&amp;", "\\",
	}
	// With these, a source gets definitions of links and loses them: an
	// edit that changes one is a parse of all of the source.
	DEFINITIONS := []string{"[r]: /u\n", "[r] ", "]:", "[ref one]", "\n[ref one]: /changed\n", "\n> [q]:\n> /quoted\n", "[a\nb]: /lines\n"}
	Run :: struct {
		seed:        u64,
		definitions: bool,
		mixed:       bool,
	}
	runs := []Run {
		{0x2545f4914f6cdd1d, false, false},
		{0x9e3779b97f4a7c15, false, true},
		{0xd1b54a32d192ed03, false, true},
		{0x94d049bb133111eb, false, true},
		{0xbf58476d1ce4e5b9, true, true},
		{0x1234567890abcdef, true, false},
	}
	for run in runs {
		source := run.mixed ? mixed(12) : numbered(2 * PART_BLOCKS)
		defer delete(source)
		doc := parse(source)
		defer destroy(&doc)
		// The same numbers each run.
		state := rand.create(run.seed)
		context.random_generator = rand.default_random_generator(&state)
		piece :: proc(pieces, definitions: []string, with: bool) -> string {
			if with && rand.int_max(8) == 0 {
				return definitions[rand.int_max(len(definitions))]
			}
			return pieces[rand.int_max(len(pieces))]
		}
		pieces := 0
		EDITS :: 300
		for _ in 0 ..< EDITS {
			e: Edit
			e.start = rand.int_max(len(doc.source) + 1)
			e.end = e.start
			switch rand.int_max(3) {
			case 0:
				e.text = piece(PIECES, DEFINITIONS, run.definitions)
			case 1:
				e.end = min(e.start + rand.int_max(40), len(doc.source))
			case 2:
				e.end = min(e.start + rand.int_max(12), len(doc.source))
				e.text = piece(PIECES, DEFINITIONS, run.definitions)
			}
			p := prepare(&doc, e)
			pieces += p.all ? 0 : 1
			commit(&doc, &p)
			discard(&p)
			expect_document(t, &doc, string(doc.source))
		}
		// Most edits need a piece only, also in a source with
		// definitions of links.
		testing.expect(t, pieces > EDITS / 2, fmt.tprintf("%d of %d edits parsed a piece", pieces, EDITS))
	}
}
