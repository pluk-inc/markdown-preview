package document

import "core:testing"

@(test)
test_return_puts_in_what_the_block_of_the_caret_needs :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		at:     Address,
		after:  string,
		caret:  int, // in `after`
	}
	cases := []Case {
		// At the end of a paragraph: an empty paragraph after it, also
		// with a block right after, and at the end of the source.
		{"ab\n\nnext\n", {0, 0, 2}, "ab\n\n\n\nnext\n", 4},
		{"ab\nnext2\n\nz\n", {0, 0, 8}, "ab\nnext2\n\n\n\nz\n", 10},
		{"ab\n```\nc\n```\n", {0, 0, 2}, "ab\n\n\n\n```\nc\n```\n", 4},
		{"ab\n", {0, 0, 2}, "ab\n\n\n", 4},
		{"ab", {0, 0, 2}, "ab\n\n", 4},
		// After the marks that end the text, and after the line under
		// a heading.
		{"**ab**\n\nnext\n", {0, 0, 2}, "**ab**\n\n\n\nnext\n", 8},
		{"Title\n=====\n\nnext\n", {0, 0, 5}, "Title\n=====\n\n\n\nnext\n", 13},
		// In the text: the rest is a paragraph of its own.
		{"abcd\n", {0, 0, 2}, "ab\n\ncd\n", 4},
		// In an empty paragraph: one more.
		{"ab\n\n\n\nnext\n", {0, 0, 3}, "ab\n\n\n\n\n\nnext\n", 6},
		// A new line of code.
		{"```\nab\n```\n", {0, 0, 1}, "```\na\nb\n```\n", 6},
		// A new item of a list, of the kind of the item.
		{"- one\n- two\n", {0, 0, 3}, "- one\n- \n- two\n", 8},
		{"  * one\n", {0, 0, 3}, "  * one\n  * \n", 12},
		{"1. one\n2. two\n", {1, 0, 3}, "1. one\n2. two\n3. \n", 17},
		{"9) one\n", {0, 0, 3}, "9) one\n10) \n", 11},
		{"- [x] done\n", {0, 0, 4}, "- [x] done\n- [ ] \n", 17},
		// Not for an item that goes on in a second block, and not in a
		// quote: an empty paragraph there.
		{"- one\n\n  more\n\nz\n", {0, 0, 3}, "- one\n\n\n\n  more\n\nz\n", 7},
		{"> - one\n", {0, 0, 3}, "> - one\n\n\n", 9},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		places := block_map(&doc, c.at.block)
		defer delete(places)
		offset, text, caret, ok := line_break(&doc, places[:], c.at)
		testing.expect(t, ok)
		apply(&doc, {offset, offset, text})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, caret, c.caret)
		// The caret is at a place of its own after it: an address that
		// is that offset again.
		landed := address_of(&doc, caret)
		back, placed := source_of(&doc, landed)
		testing.expect(t, placed)
		testing.expect_value(t, back, caret)
	}
	// Nothing in a table yet.
	table := parse("| a |\n| - |\n")
	defer destroy(&table)
	places := block_map(&table, 0)
	defer delete(places)
	_, _, _, ok := line_break(&table, places[:], {0, 0, 1})
	testing.expect(t, !ok)
}
