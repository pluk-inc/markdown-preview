package document

import "core:testing"

@(test)
test_the_lines_that_return_makes_are_empty_paragraphs :: proc(t: ^testing.T) {
	Case :: struct {
		source:  string,
		empties: []int, // of each block
		offsets: []int, // of each empty paragraph, in the order of the source
	}
	cases := []Case {
		// One line ends a block; that is no paragraph.
		{"ab\n\nnext\n", {0, 0}, {}},
		{"ab\n", {0}, {}},
		{"ab", {0}, {}},
		// Return at the end of a paragraph, with a block after it and
		// with none; and Return two times.
		{"ab\n\n\n\nnext\n", {1, 0}, {4}},
		{"ab\n\n\n\n\n\nnext\n", {2, 0}, {4, 6}},
		{"ab\n\n", {1}, {4}},
		{"ab\n\n\n", {1}, {4}},
		{"ab\n\n\n\n\n", {2}, {4, 6}},
		// An even number of lines before a block: the last one is no
		// paragraph.
		{"ab\n\n\nnext\n", {0, 0}, {}},
		{"ab\n\n\n\n\nnext\n", {1, 0}, {4}},
		// Line breaks of two bytes, and lines with spaces in them.
		{"ab\r\n\r\n\r\n\r\nnext\r\n", {1, 0}, {6}},
		{"ab\n  \n\t\n \nnext\n", {1, 0}, {6}},
		// After each kind of block, and after a definition of a link.
		{"# T\n\n\n\n- a\n\n\n\n> q\n\n\n\n```\nc\n```\n\n\n\n| a |\n| - |\n\n\n\nz\n", {1, 1, 1, 1, 1, 0}, {5, 12, 19, 32, 47}},
		{"ab [r]\n\n[r]: /u\n\n\n\nnext\n", {1, 0}, {17}},
		// Lines at the start of the source are of no block, and the
		// lines at the end of code with no end mark are code.
		{"\n\n\nab\n", {0}, {}},
		{"```\nc\n\n\n", {0}, {}},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		testing.expect_value(t, doc.count, len(c.empties))
		found := 0
		for block in 0 ..< min(doc.count, len(c.empties)) {
			testing.expect_value(t, int(block_at(&doc, block).empties), c.empties[block])
			for n in 1 ..= int(block_at(&doc, block).empties) {
				if found < len(c.offsets) {
					testing.expect_value(t, empty_offset(&doc, block, n), c.offsets[found])
					// The address of the paragraph is that offset, and
					// the offset is that address.
					at, ok := empty_address(&doc, block, n)
					testing.expect(t, ok)
					offset, placed := source_of(&doc, at)
					testing.expect(t, placed)
					testing.expect_value(t, offset, c.offsets[found])
					testing.expect_value(t, address_of(&doc, offset), at)
				}
				found += 1
			}
		}
		testing.expect_value(t, found, len(c.offsets))
	}
}

@(test)
test_a_step_goes_through_each_empty_paragraph :: proc(t: ^testing.T) {
	// "ab", two empty paragraphs, "z".
	doc := parse("ab\n\n\n\n\n\nz\n")
	defer destroy(&doc)
	path := []Address{{0, 0, 1}, {0, 0, 2}, {0, 0, 3}, {0, 0, 4}, {1, 0, 0}, {1, 0, 1}}
	for at, i in path[:len(path) - 1] {
		next, ok := step(&doc, at, .Character, true)
		testing.expect(t, ok)
		testing.expect_value(t, next, path[i + 1])
		back, back_ok := step(&doc, path[i + 1], .Character, false)
		testing.expect(t, back_ok)
		testing.expect_value(t, back, at)
	}
	// A step of a word stops in each empty paragraph too. From the last
	// one it goes to the end of the first word after it, and from that
	// text back into the paragraph.
	word, _ := step(&doc, {0, 0, 2}, .Word, true)
	testing.expect_value(t, word, Address{0, 0, 3})
	word, _ = step(&doc, {0, 0, 4}, .Word, true)
	testing.expect_value(t, word, Address{1, 0, 1})
	word, _ = step(&doc, {1, 0, 0}, .Word, false)
	testing.expect_value(t, word, Address{0, 0, 4})
	word, _ = step(&doc, {0, 0, 3}, .Word, false)
	testing.expect_value(t, word, Address{0, 0, 2})
	_, last, _ := caret_ends(&doc)
	testing.expect_value(t, last, Address{1, 0, 1})
	// The end of a document that ends in an empty paragraph is in it.
	ends := parse("ab\n\n")
	defer destroy(&ends)
	_, last, _ = caret_ends(&ends)
	testing.expect_value(t, last, Address{0, 0, 3})
	// An offset in the line that ends the block is at the end of its
	// text; one in the line before the next block is in the paragraph.
	testing.expect_value(t, address_of(&doc, 3), Address{0, 0, 2})
	testing.expect_value(t, address_of(&doc, 5), Address{0, 0, 3})
	testing.expect_value(t, address_of(&doc, 7), Address{0, 0, 4})
}

@(test)
test_a_change_of_the_empty_lines_after_a_block_is_a_change_of_that_block :: proc(t: ^testing.T) {
	// Return at the end of a paragraph, and the line taken out again: a
	// layout must make the records of the block again each time.
	doc := parse("ab\n\nnext\n")
	defer destroy(&doc)
	change := apply(&doc, {2, 2, "\n\n"})
	testing.expect_value(t, int(block_at(&doc, 0).empties), 1)
	testing.expect(t, change.count > 0 && change.first == 0)
	back := apply(&doc, {3, 5, ""})
	testing.expect_value(t, int(block_at(&doc, 0).empties), 0)
	testing.expect(t, back.count > 0 && back.first == 0)
	check := parse("ab\n\nnext\n")
	defer destroy(&check)
	testing.expect(t, layout_equal(block_at(&doc, 0), block_at(&check, 0)))
}
