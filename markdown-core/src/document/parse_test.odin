package document

import "../base"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
content :: proc(t: ^Text) -> string {
	return string(t.bytes[:])
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
	testing.expect_value(t, open.task_line, 3)
	testing.expect_value(t, open.done, false)
	testing.expect_value(t, done.marker, Marker.Task_Done)
	testing.expect_value(t, done.task_line, 4)
	testing.expect_value(t, done.done, true)
	// A later block of the checked item is done too; an item inside it has
	// its own state.
	testing.expect_value(t, more.done, true)
	testing.expect_value(t, more.marker, Marker.None)
	testing.expect_value(t, inside.marker, Marker.Task_Open)
	testing.expect_value(t, inside.task_line, 7)
	testing.expect_value(t, inside.done, false)
	testing.expect_value(t, plain.done, false)
	testing.expect_value(t, plain.task_line, 0)
	testing.expect_value(t, after.done, false)
}

@(test)
test_task_lines_count_each_kind_of_line_ending :: proc(t: ^testing.T) {
	// CR alone, then CR LF, then LF: each ends one line.
	doc := parse("- [ ] one\r- [ ] two\r\n- [x] three\n- [ ] four\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 4)
	for i in 0 ..< doc.count {
		testing.expect_value(t, block_at(&doc, i).task_line, i + 1)
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
