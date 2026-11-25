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
		// At the end of a paragraph: an empty paragraph after it, also
		// with a block right after, and at the end of the source.
		{"ab\n\nnext\n", {0, 0, 2}, "ab\n\n\n\nnext\n", 4, 0},
		{"ab\nnext2\n\nz\n", {0, 0, 8}, "ab\nnext2\n\n\n\nz\n", 10, 0},
		{"ab\n```\nc\n```\n", {0, 0, 2}, "ab\n\n\n\n```\nc\n```\n", 4, 0},
		{"ab\n", {0, 0, 2}, "ab\n\n\n", 4, 0},
		{"ab", {0, 0, 2}, "ab\n\n", 4, 0},
		// After the marks that end the text, and after the line under
		// a heading.
		{"**ab**\n\nnext\n", {0, 0, 2}, "**ab**\n\n\n\nnext\n", 8, 0},
		{"Title\n=====\n\nnext\n", {0, 0, 5}, "Title\n=====\n\n\n\nnext\n", 13, 0},
		// In the text: the rest is a paragraph of its own.
		{"abcd\n", {0, 0, 2}, "ab\n\ncd\n", 4, 0},
		// In an empty paragraph: one more.
		{"ab\n\n\n\nnext\n", {0, 0, 3}, "ab\n\n\n\n\n\nnext\n", 6, 0},
		// A new line of code.
		{"```\nab\n```\n", {0, 0, 1}, "```\na\nb\n```\n", 6, 0},
		// A new item of a list, of the kind of the item.
		{"- one\n- two\n", {0, 0, 3}, "- one\n- \n- two\n", 8, 0},
		{"  * one\n", {0, 0, 3}, "  * one\n  * \n", 12, 0},
		{"1. one\n2. two\n", {1, 0, 3}, "1. one\n2. two\n3. \n", 17, 0},
		{"9) one\n", {0, 0, 3}, "9) one\n10) \n", 11, 0},
		{"- [x] done\n", {0, 0, 4}, "- [x] done\n- [ ] \n", 17, 0},
		// In an item with no text: the item goes, and an empty
		// paragraph is there, in a list and at its end.
		{"- one\n- \n- two\n", {1, 0, 0}, "- one\n- two\n", 5, 0},
		{"- one\n- \n", {1, 0, 0}, "- one\n\n\n", 7, 0},
		{"- one\n- \n\nz\n", {1, 0, 0}, "- one\n\n\n\nz\n", 7, 0},
		// Not in a quote: an empty paragraph after it.
		{"> - one\n", {0, 0, 3}, "> - one\n\n\n", 9, 0},
		// After the lists that are in the item.
		{"- a\n  - b\n", {0, 0, 1}, "- a\n  - b\n- \n", 12, 0},
		// With the line break of the source.
		{"ab\r\n\r\nnext\r\n", {0, 0, 2}, "ab\r\n\r\n\r\n\r\nnext\r\n", 6, 0},
		// In the text before a line break of the paragraph: that line
		// break is the empty line, in a quote too.
		{"ab\ncd\n", {0, 0, 2}, "ab\n\ncd\n", 4, 0},
		{"ab  \ncd\n", {0, 0, 2}, "ab\n\ncd\n", 4, 0},
		{"> ab\n> cd\n", {0, 0, 2}, "> ab\n\n> cd\n", 6, 8},
		// In an empty paragraph after code and after a table.
		{"```\nc\n```\n\n\n\nz\n", {0, 0, 2}, "```\nc\n```\n\n\n\n\n\nz\n", 13, 0},
		{"| a |\n| - |\n\n\n\nz\n", {0, 0, 2}, "| a |\n| - |\n\n\n\n\n\nz\n", 15, 0},
		// Code by its indent: the new line has the indent.
		{"    code\n    more\n", {0, 0, 2}, "    co\n    de\n    more\n", 11, 0},
		{"    code\n\nz\n", {0, 0, 4}, "    code\n\n\n\nz\n", 10, 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		places := block_map(&doc, c.at.block)
		defer delete(places)
		start, end, text, caret, ok := line_break(&doc, places[:], c.at)
		testing.expect(t, ok)
		apply(&doc, {start, end, text})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, caret, c.caret)
		// The caret is at a place of its own after it: an address that
		// is that offset again.
		landed := address_of(&doc, caret)
		back, placed := source_of(&doc, landed)
		testing.expect(t, placed)
		testing.expect_value(t, back, c.place > 0 ? c.place : caret)
	}
	// Nothing in a table yet.
	table := parse("| a |\n| - |\n")
	defer destroy(&table)
	places := block_map(&table, 0)
	defer delete(places)
	_, _, _, _, ok := line_break(&table, places[:], {0, 0, 1})
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
		{"ab\n\nnext\n", {0, 0, 2}, "", {}},
		{"ab\n", {0, 0, 2}, "", {}},
		{"ab", {0, 0, 2}, "ab\n", {}},
		{"ab\r\n\r\nnext\r\n", {0, 0, 2}, "", {}},
		{"**ab**\n\nnext\n", {0, 0, 2}, "", {}},
		{"Title\n=====\n\nnext\n", {0, 0, 5}, "", {}},
		{"ab\n```\nc\n```\n", {0, 0, 2}, "ab\n\n```\nc\n```\n", {}},
		{"- one\n- two\n", {0, 0, 3}, "", {}},
		{"- one\n- two\n", {1, 0, 3}, "", {}},
		{"1. one\n", {0, 0, 3}, "", {}},
		{"- [x] done\n\nz\n", {0, 0, 4}, "", {}},
		// The new item is after the list in the item: the text before
		// it is the last text of that list.
		{"- a\n  - b\n", {0, 0, 1}, "", {1, 0, 1}},
		{"- a\n  - b\n", {1, 0, 1}, "", {}},
		{"    code\n\nz\n", {0, 0, 4}, "", {}},
		{"| a |\n| - |\n\n\n\nz\n", {0, 0, 2}, "", {}},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		places := block_map(&doc, c.at.block)
		start, end, text, caret, ok := line_break(&doc, places[:], c.at)
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
