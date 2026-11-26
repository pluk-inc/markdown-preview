package document

import "core:fmt"
import "core:testing"

@(test)
test_return_puts_in_what_the_block_of_the_caret_needs :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		at:     Address,
		after:  string,
		caret:  int, // in `after`
		place:  int, // where text typed at the caret goes, when that is not `caret`
	}
	cases := []Case {
		// At the end of a paragraph: an empty line after it, also with
		// a block right after, and at the end of the source.
		{"ab\n\nnext\n", {block = 0, byte = 2}, "ab\n\n\nnext\n", 3, 0},
		{"ab\nnext2\n\nz\n", {block = 0, byte = 8}, "ab\nnext2\n\n\nz\n", 9, 0},
		{"ab\n```\nc\n```\n", {block = 0, byte = 2}, "ab\n\n\n```\nc\n```\n", 3, 0},
		{"ab\n", {block = 0, byte = 2}, "ab\n\n", 3, 0},
		{"ab", {block = 0, byte = 2}, "ab\n\n", 3, 0},
		// After the marks that end the text, and after the line under
		// a heading.
		{"**ab**\n\nnext\n", {block = 0, byte = 2}, "**ab**\n\n\nnext\n", 7, 0},
		{"Title\n=====\n\nnext\n", {block = 0, byte = 5}, "Title\n=====\n\n\nnext\n", 12, 0},
		// In the text: the rest is a paragraph of its own.
		{"abcd\n", {block = 0, byte = 2}, "ab\n\ncd\n", 4, 0},
		// In an empty line: one more.
		{"ab\n\n\nnext\n", {block = 0, byte = 2, empty = 1}, "ab\n\n\n\nnext\n", 4, 0},
		// A new line of code, with what the line starts with: in a
		// list item and in a quote it is a line of that code.
		{"```\nab\n```\n", {block = 0, byte = 1}, "```\na\nb\n```\n", 6, 0},
		{"- a\n\n  ```\n  ab\n  ```\n", {block = 1, byte = 1}, "- a\n\n  ```\n  a\n  b\n  ```\n", 17, 0},
		{"> ```\n> ab\n> ```\n", {block = 0, byte = 1}, "> ```\n> a\n> b\n> ```\n", 12, 0},
		{"```\n> ab\n```\n", {block = 0, byte = 3}, "```\n> a\nb\n```\n", 8, 0},
		{"> ```\n> > ab\n> ```\n", {block = 0, byte = 3}, "> ```\n> > a\n> b\n> ```\n", 14, 0},
		// A new item of a list, of the kind of the item.
		{"- one\n- two\n", {block = 0, byte = 3}, "- one\n- \n- two\n", 8, 0},
		{"  * one\n", {block = 0, byte = 3}, "  * one\n  * \n", 12, 0},
		{"1. one\n2. two\n", {block = 1, byte = 3}, "1. one\n2. two\n3. \n", 17, 0},
		{"9) one\n", {block = 0, byte = 3}, "9) one\n10) \n", 11, 0},
		{"- [x] done\n", {block = 0, byte = 4}, "- [x] done\n- [ ] \n", 17, 0},
		// In an item with no text: the item goes, and an empty line is
		// there. Between two items, the item only goes.
		{"- one\n- \n- two\n", {block = 1}, "- one\n- two\n", 5, 0},
		{"- one\n- \n", {block = 1}, "- one\n\n", 6, 0},
		{"- one\n- \n\nz\n", {block = 1}, "- one\n\n\nz\n", 6, 0},
		// The first block of the source: its line goes.
		{"- \n- two\n", {block = 0}, "- two\n", 0, 2},
		{"- \n\nz\n", {block = 0}, "\nz\n", 0, 1},
		// Not in a quote: an empty line after it.
		{"> - one\n", {block = 0, byte = 3}, "> - one\n\n", 8, 0},
		// After the lists that are in the item.
		{"- a\n  - b\n", {block = 0, byte = 1}, "- a\n  - b\n- \n", 12, 0},
		// With the line break of the source.
		{"ab\r\n\r\nnext\r\n", {block = 0, byte = 2}, "ab\r\n\r\n\r\nnext\r\n", 4, 0},
		// In the text before a line break of the paragraph: that line
		// break is the empty line, in a quote too.
		{"ab\ncd\n", {block = 0, byte = 2}, "ab\n\ncd\n", 4, 0},
		{"ab  \ncd\n", {block = 0, byte = 2}, "ab\n\ncd\n", 4, 0},
		{"ab\\\ncd\n", {block = 0, byte = 2}, "ab\n\ncd\n", 4, 0},
		{"ab \\\r\ncd\r\n", {block = 0, byte = 2}, "ab\r\n\r\ncd\r\n", 6, 0},
		{"> ab\n> cd\n", {block = 0, byte = 2}, "> ab\n\n> cd\n", 6, 8},
		// In an empty line after code and after a table.
		{"```\nc\n```\n\n\nz\n", {block = 0, byte = 1, empty = 1}, "```\nc\n```\n\n\n\nz\n", 11, 0},
		{"| a |\n| - |\n\n\nz\n", {block = 0, byte = 1, empty = 1}, "| a |\n| - |\n\n\n\nz\n", 13, 0},
		// Code by its indent: the new line has the indent. At its end,
		// an empty line after the code.
		{"    code\n    more\n", {block = 0, byte = 2}, "    co\n    de\n    more\n", 11, 0},
		{"    code\n\nz\n", {block = 0, byte = 4}, "    code\n\n\nz\n", 9, 0},
		{"    ```\n    x\n\nz\n", {block = 0, byte = 5}, "    ```\n    x\n\n\nz\n", 14, 0},
		// Code in a fence with no line of code: two lines of code, so
		// the caret is not in the line of the closing fence.
		{"```\n```\n", {block = 0}, "```\n\n\n```\n", 5, 0},
		{"x\n\n```js\n```\n", {block = 1}, "x\n\n```js\n\n\n```\n", 10, 0},
		// An item with no text that is all of the source.
		{"- \n", {block = 0}, "", 0, 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		places := block_map(&doc, c.at.block)
		defer delete(places)
		start, end, text, caret, ok := line_break(&doc, places[:], c.at)
		defer delete(text)
		testing.expect(t, ok)
		apply(&doc, {start, end, text})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, caret, c.caret)
		// A document with no block has no address for a caret.
		if doc.count == 0 {
			continue
		}
		// The caret is at a place of its own after it: an address that
		// is that offset again.
		landed := address_of(&doc, caret)
		back, placed := source_of(&doc, landed)
		testing.expect(t, placed)
		testing.expect_value(t, back, c.place > 0 ? c.place : caret)
	}
	// Nothing at the end of an item that has a block of its own after
	// a list in it: a new item there would take that block.
	more := parse("- a\n  - b\n\n  more\n")
	defer destroy(&more)
	more_places := block_map(&more, 0)
	defer delete(more_places)
	_, _, _, _, refused := line_break(&more, more_places[:], {block = 0, byte = 1})
	testing.expect(t, !refused)
	// Nothing in a table yet.
	table := parse("| a |\n| - |\n")
	defer destroy(&table)
	places := block_map(&table, 0)
	defer delete(places)
	_, _, _, _, ok := line_break(&table, places[:], {block = 0, byte = 1})
	testing.expect(t, !ok)
}

@(test)
test_a_delete_takes_out_what_return_made :: proc(t: ^testing.T) {
	// Return at the end of a text and then a delete give the source of
	// before. For a paragraph with a block right after it, one empty
	// line stays between the two, and a source with no line break at
	// its end gets one: the same text for a reader.
	Case :: struct {
		source: string,
		at:     Address,
		after:  string, // "" for the source of before
		back:   Address, // where the caret is then, when not at `at`
	}
	cases := []Case {
		{"ab\n\nnext\n", {block = 0, byte = 2}, "", {}},
		{"ab\n", {block = 0, byte = 2}, "", {}},
		{"ab", {block = 0, byte = 2}, "ab\n", {}},
		{"ab\r\n\r\nnext\r\n", {block = 0, byte = 2}, "", {}},
		{"**ab**\n\nnext\n", {block = 0, byte = 2}, "", {}},
		{"Title\n=====\n\nnext\n", {block = 0, byte = 5}, "", {}},
		{"ab\n```\nc\n```\n", {block = 0, byte = 2}, "ab\n\n```\nc\n```\n", {}},
		{"- one\n- two\n", {block = 0, byte = 3}, "", {}},
		{"- one\n- two\n", {block = 1, byte = 3}, "", {}},
		{"1. one\n", {block = 0, byte = 3}, "", {}},
		{"- [x] done\n\nz\n", {block = 0, byte = 4}, "", {}},
		// The new item is after the list in the item: the text before
		// it is the last text of that list.
		{"- a\n  - b\n", {block = 0, byte = 1}, "", {block = 1, byte = 1}},
		{"- a\n  - b\n", {block = 1, byte = 1}, "", {}},
		{"    code\n\nz\n", {block = 0, byte = 4}, "", {}},
		{"| a |\n| - |\n\n\nz\n", {block = 0, byte = 1, empty = 1}, "", {}},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		places := block_map(&doc, c.at.block)
		start, end, text, caret, ok := line_break(&doc, places[:], c.at)
		defer delete(text)
		delete(places)
		testing.expect(t, ok)
		apply(&doc, {start, end, text})
		at := address_of(&doc, caret)
		places = block_map(&doc, at.block)
		from, to, back, found := delete_back(&doc, places[:], at)
		delete(places)
		testing.expect(t, found)
		apply(&doc, {from, to, ""})
		testing.expect_value(t, string(doc.source), c.after == "" ? c.source : c.after)
		// The caret is where it was: at the end of the text.
		testing.expect_value(t, address_of(&doc, back), c.back != {} ? c.back : c.at)
	}
}

@(test)
test_the_line_of_a_paragraph_stays_when_its_only_character_goes :: proc(t: ^testing.T) {
	// A character typed in an empty line, and a delete: the source of
	// before, with the caret in that line again. For each empty line.
	for source in ([]string{"ab\n\n\nnext\n", "ab\n\n\n\n\nnext\n", "ab\n\n", "# T\r\n\r\n\r\n\r\nz\r\n"}) {
		doc := parse(source)
		empties := int(block_at(&doc, 0).empties)
		destroy(&doc)
		for n in 1 ..= empties {
			doc = parse(source)
			defer destroy(&doc)
			line, _ := empty_address(&doc, 0, n)
			offset := empty_offset(&doc, 0, n)
			text := empty_text(&doc, "x")
			defer delete(text)
			apply(&doc, {offset, offset, text})
			at := address_of(&doc, offset + len(text))
			testing.expect_value(t, at, Address{block = 1, byte = 1})
			from, _ := source_of(&doc, {block = 1})
			to, _ := source_of(&doc, at)
			edit, caret, ok := replace_range(&doc, from, to, "", allocator = context.temp_allocator)
			testing.expect(t, ok)
			apply(&doc, edit)
			testing.expect_value(t, string(doc.source), source)
			testing.expect_value(t, address_of(&doc, caret), line)
		}
	}
	// Not for a paragraph with more text, for an item of a list, and for
	// the first block: the character goes as each other one does. With
	// marks around the character, they go too, and the line is empty.
	Case :: struct {
		source, after: string,
	}
	for c in ([]Case{{"ab\n\nxy\n", "ab\n\nx\n"}, {"ab\n\n**x**\n", "ab\n\n"}, {"ab\n\n- x\n", "ab\n\n- \n"}, {"x\n", "\n"}}) {
		doc := parse(c.source)
		defer destroy(&doc)
		block := doc.count - 1
		size := len(block_at(&doc, block).text.bytes)
		from, _ := source_of(&doc, {block = block, byte = size - 1})
		to, _ := source_of(&doc, {block = block, byte = size})
		edit, _, ok := replace_range(&doc, from, to, "", allocator = context.temp_allocator)
		testing.expect(t, ok)
		apply(&doc, edit)
		testing.expect_value(t, string(doc.source), c.after)
	}
}

// Return after a mark with nothing after it that is being typed at the
// caret ("-"): no list yet, so no new item, as at the end of a paragraph.
@(test)
test_return_after_a_typed_mark_makes_no_item :: proc(t: ^testing.T) {
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", "-\n"), 1)
	defer destroy(&doc)
	testing.expect(t, block_at(&doc, 0).typed)
	places := block_map(&doc, 0)
	defer delete(places)
	start, end, text, caret, ok := line_break(&doc, places[:], {block = 0, byte = 1})
	defer delete(text)
	testing.expect(t, ok)
	// "-\n\n": an empty paragraph after it, with the caret there.
	testing.expect_value(t, text, "\n")
	testing.expect_value(t, [3]int{start, end, caret}, [3]int{1, 1, 2})
}

// A list item that joins the list above it across empty lines gets the
// other mark, which makes a list of its own; with no empty line, or with
// a paragraph between, nothing changes.
@(test)
test_a_list_after_empty_lines_gets_another_mark :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		at:     int,
		mark:   u8,
	}
	cases := []Case {
		{"- a\n\n\n- b\n", 6, '*'},
		{"* a\n\n\n* b\n", 6, '-'},
		// One empty line keeps a loose list.
		{"- a\n\n- b\n", -1, 0},
		{"- a\n\n  b\n\n- c\n", -1, 0},
		{"1. a\n\n\n1. b\n", 8, ')'},
		{"- [ ] a\n\n\n- [ ] b\n", 10, '*'},
		{"> - a\n>\n>\n> - b\n", 12, '*'},
		{"- a\n- b\n", -1, 0},
		{"- a\n\nb\n\n- c\n", -1, 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		at, mark := new_list_mark(&doc, doc.count - 1)
		testing.expectf(t, at == c.at && mark == c.mark, "%q: %d %c, not %d %c", c.source, at, mark, c.at, c.mark)
	}
}

// The empty lines before a mark that is being typed below a list stay
// empty lines: the mark is no list yet, so it does not move up into the
// list above it.
@(test)
test_empty_lines_stay_before_a_typed_mark :: proc(t: ^testing.T) {
	source := "- a\n- b\n\n\n-\n"
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", source), len(source) - 1)
	defer destroy(&doc)
	testing.expect(t, block_at(&doc, doc.count - 1).typed)
	testing.expect_value(t, int(block_at(&doc, doc.count - 2).empties), 1)
	// Once it is a list item, its list has it with no empty paragraph.
	plain := parse(source)
	defer destroy(&plain)
	testing.expect_value(t, int(block_at(&plain, plain.count - 2).empties), 0)
}

// Code in a fence with no line of code has a place for a caret: where
// its first line starts. Text there needs a line break of its own when
// the next line is the closing fence.
@(test)
test_code_with_no_line_has_a_place_for_a_caret :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		block:  int,
		place:  int, // -1 for none
		needs:  bool,
	}
	cases := []Case {
		{"```\n```\n", 0, 4, true},
		{"x\n\n~~~js\r\n~~~\r\n", 1, 10, true},
		// The fence is not closed: the place is the end of the source,
		// or an empty line of the code.
		{"```\n", 0, 4, false},
		// No line break after the fence: no line for code yet.
		{"```", 0, -1, false},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		at := Address{block = c.block}
		testing.expect_value(t, block_at(&doc, c.block).kind, Block_Kind.Code)
		offset, placed := source_of(&doc, at)
		testing.expect_value(t, placed, c.place >= 0)
		if placed {
			testing.expect_value(t, offset, c.place)
			testing.expect_value(t, code_needs_line(&doc, at, offset), c.needs)
		}
		// Each place in the line of the fence is in that line, and the
		// first line of the code is not.
		start := block_start(&doc, c.block)
		end, content := fence_line(doc.source, start)
		testing.expect(t, in_fence_line(&doc, at, start) && in_fence_line(&doc, at, end))
		testing.expect(t, content == end || !in_fence_line(&doc, at, content))
	}
	// Code with a line, and other blocks, have no such place.
	doc := parse("```\nab\n```\n\ntext\n")
	defer destroy(&doc)
	testing.expect(t, !code_needs_line(&doc, {block = 0}, 4))
	testing.expect(t, !in_fence_line(&doc, {block = 1}, 13))
}
