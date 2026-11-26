package document

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
			places := block_map(&doc, at.block)
			start, end, caret, ok := delete_back(&doc, places[:], at)
			delete(places)
			testing.expect(t, ok)
			apply(&doc, {start, end, ""})
			testing.expect_value(t, string(doc.source), source)
			testing.expect_value(t, address_of(&doc, caret), line)
		}
	}
	// Not for a paragraph with more text, or with marks around its
	// character: the character goes as each other one does.
	for source in ([]string{"ab\n\nxy\n", "ab\n\n**x**\n", "ab\n\n- x\n", "x\n"}) {
		doc := parse(source)
		defer destroy(&doc)
		block := doc.count - 1
		at := Address{block = block, byte = len(block_at(&doc, block).text.bytes)}
		places := block_map(&doc, block)
		defer delete(places)
		_, _, _, ok := delete_back(&doc, places[:], at)
		testing.expect(t, !ok)
	}
}
