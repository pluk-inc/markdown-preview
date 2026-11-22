package document

import "../base"
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
	testing.expect_value(t, len(doc.blocks), 2)
	testing.expect_value(t, doc.blocks[0].kind, Block_Kind.Heading)
	testing.expect_value(t, doc.blocks[0].level, 1)
	testing.expect_value(t, content(&doc.blocks[0].text), "Title")
	body := &doc.blocks[1].text
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
	text := &doc.blocks[0].text
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
	testing.expect_value(t, len(doc.blocks), 8)
	one, two, nested := doc.blocks[1], doc.blocks[2], doc.blocks[3]
	testing.expect_value(t, one.marker, Marker.Bullet)
	testing.expect_value(t, one.spacing, Spacing.List_Start)
	testing.expect_value(t, two.spacing, Spacing.Item)
	testing.expect_value(t, nested.list_depth, 2)
	testing.expect_value(t, nested.spacing, Spacing.Item)
	testing.expect_value(t, doc.blocks[4].marker, Marker.Number)
	testing.expect_value(t, doc.blocks[4].number, 3)
	testing.expect_value(t, doc.blocks[5].number, 4)
	testing.expect_value(t, doc.blocks[6].marker, Marker.Task_Open)
	testing.expect_value(t, doc.blocks[7].marker, Marker.Task_Done)
	testing.expect_value(t, content(&doc.blocks[7].text), "done")
}

@(test)
test_loose_item_continuation :: proc(t: ^testing.T) {
	doc := parse("- first\n\n  second\n")
	defer destroy(&doc)
	testing.expect_value(t, len(doc.blocks), 2)
	testing.expect_value(t, doc.blocks[0].marker, Marker.Bullet)
	testing.expect_value(t, doc.blocks[1].marker, Marker.None)
	testing.expect_value(t, doc.blocks[1].spacing, Spacing.Continuation)
}

@(test)
test_code_block :: proc(t: ^testing.T) {
	doc := parse("````odin\na | b\n```\n--- | ---\n\nlast\n````\n\n> quoted\n")
	defer destroy(&doc)
	testing.expect_value(t, len(doc.blocks), 2)
	code := &doc.blocks[0]
	testing.expect_value(t, code.kind, Block_Kind.Code)
	testing.expect_value(t, code.language, "odin")
	testing.expect_value(t, content(&code.text), "a | b\n```\n--- | ---\n\nlast")
	testing.expect_value(t, doc.blocks[1].quote_depth, 1)
}

@(test)
test_table :: proc(t: ^testing.T) {
	doc := parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | **2** |\n\n```inline``` text\n\n| x | y |\n|---|---|\n| 1 | 2 |\n")
	defer destroy(&doc)
	testing.expect_value(t, len(doc.blocks), 3)
	table := &doc.blocks[0]
	testing.expect_value(t, table.kind, Block_Kind.Table)
	testing.expect_value(t, table.columns, 3)
	testing.expect_value(t, len(table.cells), 6) // the short row gets an empty cell
	testing.expect_value(t, table.aligns[1], base.Align.Center)
	testing.expect_value(t, table.aligns[2], base.Align.Right)
	testing.expect_value(t, content(&table.cells[4]), "2")
	testing.expect_value(t, content(&table.cells[5]), "")
	// A line of inline code is not a code fence: the next table is a table.
	testing.expect_value(t, doc.blocks[2].kind, Block_Kind.Table)
}

@(test)
test_table_cell_limit :: proc(t: ^testing.T) {
	// 100 columns and 2,000 rows of one cell: 200,000 cells from 6 KB.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "|")
	for _ in 0 ..< 100 {strings.write_string(&b, "a|")}
	strings.write_string(&b, "\n|")
	for _ in 0 ..< 100 {strings.write_string(&b, "-|")}
	strings.write_string(&b, "\n")
	for _ in 0 ..< 2000 {strings.write_string(&b, "a|\n")}
	strings.write_string(&b, "\nafter\n")
	source := strings.to_string(b)
	doc := parse(source)
	defer destroy(&doc)
	testing.expect_value(t, len(doc.blocks), 2)
	testing.expect(t, len(doc.blocks[0].cells) <= MIN_TABLE_CELLS + len(source))
	testing.expect_value(t, len(doc.blocks[0].cells) % 100, 0)
	testing.expect_value(t, content(&doc.blocks[1].text), "after")
}

@(test)
test_entities_and_breaks :: proc(t: ^testing.T) {
	doc := parse("a &amp; b &#65; &#x1F600; &nope;\nsoft  \nhard\n")
	defer destroy(&doc)
	testing.expect_value(t, content(&doc.blocks[0].text), "a & b A \U0001F600 &nope; soft\nhard")
}

@(test)
test_white_space_collapses :: proc(t: ^testing.T) {
	doc := parse("a    b\tc `x  y`\n\n    code  stays\n")
	defer destroy(&doc)
	testing.expect_value(t, content(&doc.blocks[0].text), "a b c x  y")
	testing.expect_value(t, content(&doc.blocks[1].text), "code  stays")
}

@(test)
test_raw_html_is_dropped :: proc(t: ^testing.T) {
	doc := parse("<div>\nblock\n</div>\n\ntext <b>bold</b> end\n")
	defer destroy(&doc)
	testing.expect_value(t, len(doc.blocks), 1)
	testing.expect_value(t, content(&doc.blocks[0].text), "text bold end")
}

@(test)
test_empty_and_rule :: proc(t: ^testing.T) {
	empty := parse("")
	defer destroy(&empty)
	testing.expect_value(t, len(empty.blocks), 0)
	rule := parse("---\n")
	defer destroy(&rule)
	testing.expect_value(t, len(rule.blocks), 1)
	testing.expect_value(t, rule.blocks[0].kind, Block_Kind.Rule)
}
