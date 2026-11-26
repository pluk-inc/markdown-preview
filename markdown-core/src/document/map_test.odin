package document

import "core:math/rand"
import "core:strings"
import "core:testing"

// Where text goes that is put in at an address; -1 for no place.
@(private = "file")
put_at :: proc(doc: ^Document, at: Address) -> int {
	offset, ok := source_of(doc, at)
	return ok ? offset : -1
}

// The source of the character before an address; "" for none.
@(private = "file")
before :: proc(doc: ^Document, at: Address) -> string {
	places := block_map(doc, at.block)
	defer delete(places)
	start, end, ok := char_before(doc, places[:], at)
	return ok ? string(doc.source[start:end]) : ""
}

@(test)
test_the_text_of_a_block_knows_its_place_in_the_source :: proc(t: ^testing.T) {
	//        0         1         2         3         4
	//        0123456789012345678901234567890123456789012345
	SOURCE :: "# Title\n\nOne **two** three &amp; `four`  five\n"
	doc := parse(SOURCE)
	defer destroy(&doc)
	// The heading: its text is after the mark.
	testing.expect_value(t, put_at(&doc, {block = 0}), 2)
	testing.expect_value(t, put_at(&doc, {block = 0, byte = 5}), 7)
	// "One two three & four five": text that is put in at the end of
	// "two" is in the bold marks, and text at its start is before them.
	testing.expect_value(t, put_at(&doc, {block = 1}), 9)
	testing.expect_value(t, put_at(&doc, {block = 1, byte = 4}), 13)
	testing.expect_value(t, put_at(&doc, {block = 1, byte = 7}), 18)
	testing.expect_value(t, put_at(&doc, {block = 1, byte = 9}), 22)
	// The character before an address: its bytes, or all that the source
	// has for it: an entity, two spaces that are one space.
	testing.expect_value(t, before(&doc, {block = 1, byte = 5}), "t")
	testing.expect_value(t, before(&doc, {block = 1, byte = 15}), "&amp;")
	testing.expect_value(t, before(&doc, {block = 1, byte = 21}), "  ")
	testing.expect_value(t, before(&doc, {block = 1}), "")
	// And back: an offset in text is in that text, one in marks is at
	// the end of the text before it.
	testing.expect_value(t, address_of(&doc, 2), Address{block = 0})
	testing.expect_value(t, address_of(&doc, 16), Address{block = 1, byte = 5})
	testing.expect_value(t, address_of(&doc, 14), Address{block = 1, byte = 4})
	testing.expect_value(t, address_of(&doc, 19), Address{block = 1, byte = 7})
	testing.expect_value(t, address_of(&doc, len(SOURCE)), Address{block = 1, byte = 25})
}

@(test)
test_places_in_lists_quotes_code_and_tables :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		at:     Address,
		offset: int, // where text goes that is put in at the address
	}
	cases := []Case {
		{"- one\n- two\n", {block = 1}, 8},
		{"```\nfirst\n\nthird\n```\n", {block = 0, byte = 7}, 11}, // "first\n\nthird": before the "t"
		{"1. a\n   ```\n   code\n   ```\n", {block = 1}, 15},
		{"| a | bb |\n| - | - |\n| c | dd |\n", {block = 0, cell = 3, byte = 1}, 28}, // cell "dd": before its second "d"
		{"a [link](https://example.com) b\n", {block = 0, byte = 3}, 4},
		{"x\n\n[ref]: /u\n\nsee [ref] here\n", {block = 1, byte = 5}, 20},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		testing.expect_value(t, put_at(&doc, c.at), c.offset)
		testing.expect_value(t, address_of(&doc, c.offset), c.at)
	}
}

@(test)
test_text_that_the_parser_makes_has_the_source_between_its_neighbours :: proc(t: ^testing.T) {
	{
		// A line break in a quote shows as a space. It is the line break
		// and the mark of the next line: text at the start of "bar"
		// goes after the mark, and the space goes out with the mark.
		doc := parse("> foo\n> bar\n")
		defer destroy(&doc)
		testing.expect_value(t, put_at(&doc, {block = 0, byte = 4}), 8)
		testing.expect_value(t, before(&doc, {block = 0, byte = 4}), "\n> ")
		testing.expect_value(t, put_at(&doc, {block = 0, byte = 3}), 5)
	}
	{
		// The same in a list item, where the next line has an indent,
		// and for a break that the reader sees, made with a backslash.
		doc := parse("- foo\n  bar\n\none\\\ntwo\n")
		defer destroy(&doc)
		testing.expect_value(t, before(&doc, {block = 0, byte = 4}), "\n  ")
		testing.expect_value(t, before(&doc, {block = 1, byte = 4}), "\\\n")
		testing.expect_value(t, put_at(&doc, {block = 1, byte = 4}), 18)
	}
	{
		// An empty first line of a code block: text that is put in
		// there is after the fence, not before it.
		doc := parse("```\n\nx\n```\n")
		defer destroy(&doc)
		testing.expect_value(t, put_at(&doc, {block = 0}), 4)
		testing.expect_value(t, before(&doc, {block = 0, byte = 1}), "\n")
		testing.expect_value(t, put_at(&doc, {block = 0, byte = 1}), 5)
	}
	{
		// A code block of empty lines only: text goes into its lines,
		// after the fence.
		doc := parse("x\n\n```\n\n\n```\n")
		defer destroy(&doc)
		testing.expect_value(t, put_at(&doc, {block = 1}), 7)
		testing.expect_value(t, before(&doc, {block = 1, byte = 1}), "\n")
		testing.expect_value(t, put_at(&doc, {block = 1, byte = 1}), 8)
	}
	{
		// Code with a deeper indent: the two spaces that show are the
		// two before the text, after the indent that makes it code.
		doc := parse("      foo\n")
		defer destroy(&doc)
		testing.expect_value(t, put_at(&doc, {block = 0}), 4)
		testing.expect_value(t, put_at(&doc, {block = 0, byte = 2}), 6)
		testing.expect_value(t, before(&doc, {block = 0, byte = 1}), " ")
	}
	{
		// Empty lines in a code block in a list: each is its line.
		doc := parse("- a\n\n  ```\n  one\n\n\n  four\n  ```\n")
		defer destroy(&doc)
		// "one\n\n\nfour"
		testing.expect_value(t, before(&doc, {block = 1, byte = 4}), "\n")
		testing.expect_value(t, before(&doc, {block = 1, byte = 5}), "\n")
		testing.expect_value(t, before(&doc, {block = 1, byte = 6}), "\n  ")
	}
	{
		// An entity of two characters is one thing.
		doc := parse("a &NotEqualTilde; b\n")
		defer destroy(&doc)
		text := block_at(&doc, 0).text.bytes[:]
		testing.expect_value(t, before(&doc, {block = 0, byte = len(text) - 2}), "&NotEqualTilde;")
	}
	{
		// A definition of a link that the text of the block uses does
		// not move the places, when it is before the block.
		doc := parse("[i]: /u\n\nfirst\n\n```\n\narr[i]\n```\n")
		defer destroy(&doc)
		testing.expect_value(t, put_at(&doc, {block = 1}), 20)
	}
}

@(test)
test_a_character_goes_out_with_all_that_the_source_has_for_it :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		at:     Address, // after the character
		gone:   string,
	}
	cases := []Case {
		// A character with a backslash before it is the two bytes; a
		// backslash that is text (in code) is one.
		{"a\\*b\n", {block = 0, byte = 2}, "\\*"},
		{"a\\*b\n", {block = 0, byte = 3}, "b"},
		{"`a\\*`\n", {block = 0, byte = 2}, "\\"},
		// A line break in inline code shows as a space, also in a quote.
		{"> `foo\n> bar`\n", {block = 0, byte = 4}, "\n> "},
		// Marks of bold text beside a line break stay.
		{"**foo**\nbar\n", {block = 0, byte = 4}, "\n"},
		{"foo\n**bar**\n", {block = 0, byte = 4}, "\n"},
		{"> *foo*  \n> bar\n", {block = 0, byte = 4}, "  \n> "},
		// An entity is one thing, also when its characters have as
		// many bytes as its name.
		{"x &acE; y\n", {block = 0, byte = 7}, "&acE;"},
		// A NUL byte shows as one character of three bytes.
		{"a\x00\n", {block = 0, byte = 4}, "\x00"},
		{"a\x00b\n", {block = 0, byte = 4}, "\x00"},
		// And as the first character, with text after it.
		{"\x00a\n", {block = 0, byte = 3}, "\x00"},
		// Also when it is all of a paragraph, after a block before it.
		{"\x00\n", {block = 0, byte = 3}, "\x00"},
		{"x\n\n\x00\n", {block = 1, byte = 3}, "\x00"},
		// And as all of a code block that is code by its indent.
		{"    \x00\n", {block = 0, byte = 3}, "\x00"},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		testing.expect_value(t, before(&doc, c.at), c.gone)
	}
}

@(test)
test_a_nul_byte_of_a_later_block_does_not_move_the_place_of_one_before :: proc(t: ^testing.T) {
	// Two items of one list are parsed together. The NUL byte in the
	// code of the second one is no place of the first one.
	doc := parse("- \x00\n- ```\n  \x00x\n  ```\n")
	defer destroy(&doc)
	testing.expect_value(t, put_at(&doc, {block = 0, byte = 3}), 3)
	places := block_map(&doc, 0)
	defer delete(places)
	start, end, ok := char_before(&doc, places[:], {block = 0, byte = 3})
	testing.expect(t, ok)
	testing.expect_value(t, start, 2)
	testing.expect_value(t, end, 3)
}

@(test)
test_the_spaces_that_a_tab_shows_as_are_the_tab :: proc(t: ^testing.T) {
	// A fence with an indent of two takes two columns of each line of
	// its code: a tab shows as the two spaces that are left of it.
	for source in ([]string{"  ~~~\n\tfoo\n  ~~~\n", "  ~~~\nx\n\tfoo\n  ~~~\n"}) {
		doc := parse(source)
		defer destroy(&doc)
		tab := strings.index_byte(source, '\t')
		text := string(block_at(&doc, 0).text.bytes[:])
		spaces := strings.index(text, "  foo")
		testing.expect(t, spaces >= 0)
		// Text before the spaces goes before the tab, and a delete
		// after them takes the tab.
		testing.expect_value(t, put_at(&doc, {block = 0, byte = spaces}), tab)
		testing.expect_value(t, put_at(&doc, {block = 0, byte = spaces + 2}), tab + 1)
		testing.expect_value(t, before(&doc, {block = 0, byte = spaces + 2}), "\t")
	}
}

@(test)
test_a_space_typed_into_a_run_of_spaces_is_before_the_caret :: proc(t: ^testing.T) {
	// "a b", a space typed after "a": the source has two spaces that show
	// as one, and the caret is after it, so the next delete takes the
	// spaces and not the "a".
	doc := parse("a  b\n")
	defer destroy(&doc)
	testing.expect_value(t, address_of(&doc, 2), Address{block = 0, byte = 2})
	testing.expect_value(t, address_of(&doc, 1), Address{block = 0, byte = 1})
	testing.expect_value(t, before(&doc, {block = 0, byte = 2}), "  ")
}

@(test)
test_the_places_are_of_the_text_that_the_document_has :: proc(t: ^testing.T) {
	// Many uses of a long definition in one paragraph, and a long
	// paragraph far from it: the parser has room for all uses in a parse
	// of all of the source, and not in a parse of the lines of the
	// paragraph alone. The places are of the text with the links.
	target := strings.repeat("a", 1000)
	defer delete(target)
	uses := strings.repeat("[r] ", 40)
	defer delete(uses)
	filler := strings.repeat("word ", 1600)
	defer delete(filler)
	source := strings.concatenate({"[r]: /", target, "\n\n", uses, "end\n\n", filler, "\n"})
	defer delete(source)
	doc := parse(source)
	defer destroy(&doc)
	text := string(block_at(&doc, 0).text.bytes[:])
	testing.expect(t, strings.has_prefix(text, "r r r "))
	testing.expect(t, strings.has_suffix(text, " end"))
	offset, ok := source_of(&doc, {block = 0, byte = len(text)})
	testing.expect(t, ok)
	testing.expect_value(t, string(doc.source[offset - 3:offset]), "end")
	testing.expect_value(t, address_of(&doc, offset), Address{block = 0, byte = len(text)})
}

@(test)
test_text_with_no_room_in_the_source_has_no_place :: proc(t: ^testing.T) {
	// A table cell with no text, also one that the source does not have
	// (a row with fewer cells): text there needs a change to the row.
	doc := parse("| a | b |\n|-|-|\n| c | |\n| d\n")
	defer destroy(&doc)
	testing.expect_value(t, put_at(&doc, {block = 0, cell = 2}), 18)
	testing.expect_value(t, put_at(&doc, {block = 0, cell = 3}), -1)
	testing.expect_value(t, put_at(&doc, {block = 0, cell = 5}), -1)
	// A block with no text has a place when its line ends with the
	// space after its mark. A list item that is only its mark has its
	// place after the mark: text there is a mark that is being typed.
	items := parse("- \n- x\n\n-\n\n#\n")
	defer destroy(&items)
	testing.expect_value(t, put_at(&items, {block = 0}), 2)
	testing.expect_value(t, put_at(&items, {block = 2}), 9)
	testing.expect_value(t, put_at(&items, {block = 3}), -1)
}

@(test)
test_text_put_in_at_an_address_is_in_the_text_there :: proc(t: ^testing.T) {
	// For each block of a document with all kinds of them, and some
	// addresses in its text: a letter put into the source at the place
	// of the address is in the text of that block at that address, and
	// the address of the offset after it is one byte on.
	source := mixed_text()
	defer delete(source)
	state := rand.create(0x51ed270b6f1c4d3b)
	context.random_generator = rand.default_random_generator(&state)
	checked := 0
	for _ in 0 ..< 400 {
		doc := parse(source)
		defer destroy(&doc)
		block := rand.int_max(doc.count)
		b := block_at(&doc, block)
		texts := block_texts(b)
		if len(texts) == 0 {
			continue
		}
		cell := rand.int_max(len(texts))
		bytes := texts[cell].bytes[:]
		byte := rand.int_max(len(bytes) + 1)
		// Not in a character, and not in text that the source has in
		// another form (a letter in an entity is no letter).
		for byte < len(bytes) && bytes[byte] & 0xc0 == 0x80 {
			byte += 1
		}
		at := Address{block = block, cell = cell, byte = byte}
		offset, ok := source_of(&doc, at)
		if !ok {
			continue
		}
		before := strings.clone(string(bytes))
		defer delete(before)
		kind := b.kind
		apply(&doc, {offset, offset, "Q"})
		if block >= doc.count || block_at(&doc, block).kind != kind {
			continue
		}
		now := block_texts(block_at(&doc, block))
		if cell >= len(now) || len(now[cell].bytes) != len(before) + 1 {
			// The letter changed what the text around it is (it is in a
			// mark now, or it ended one).
			continue
		}
		after := string(now[cell].bytes[:])
		testing.expect_value(t, after[:byte], before[:byte])
		testing.expect_value(t, after[byte], 'Q')
		testing.expect_value(t, after[byte + 1:], before[byte:])
		testing.expect_value(t, address_of(&doc, offset + 1), Address{block = block, cell = cell, byte = byte + 1})
		checked += 1
	}
	testing.expect(t, checked > 250)
}

@(private = "file")
mixed_text :: proc() -> string {
	b := strings.builder_make()
	strings.write_string(&b, "# A heading with *marks*\n\nA paragraph with **bold**, `code`, a [link](https://example.com), &amp; an entity,\nand a second line with ~~struck~~ text.\n\n")
	strings.write_string(&b, "- item one\n- [ ] a task\n\n  more of the task\n  1. inside\n     ```\n     code in a list\n\n     more code\n     ```\n- last *item*\n\n")
	strings.write_string(&b, "> a quote\n> on two lines\n>\n> - in a quote\n\nSetext\n---\n\n| a | **b** |\n|:-|-:|\n| one | two |\n\n    indented code\n\n```odin\nfenced\n\tcode\n```\n\n[ref]: https://ref.example\n\nA last one with [ref] and é.\n")
	return strings.to_string(b)
}

@(test)
test_spaces_at_the_end_of_a_text_are_before_the_caret :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		offset: int,
		spaces: int,
	}
	cases := []Case {
		// A space typed at the end of a paragraph, and two, and a tab.
		{"ab \n\nnext\n", 3, 1},
		{"ab  \n", 4, 2},
		{"ab \t", 4, 2},
		// At the end of the text, before the spaces: none before it.
		{"ab  \n", 2, 0},
		{"ab  \n", 3, 1},
		// After the marks that end the text, and in a heading and a
		// list item.
		{"**ab** \n", 7, 1},
		{"# T \n", 4, 1},
		{"T \n===\n", 2, 1},
		// The end of a text before a line of a quote with only its mark.
		{"> a \n>\n> b\n", 4, 1},
		{"> > a  \n> >\n> > b\n", 7, 2},
		{"- a  \n  >\n", 5, 2},
		// Before raw HTML right after the text, which is no block.
		{"ab \n<!-- hidden -->\n", 3, 1},
		// After the marks that close the text on a later line.
		{"[ab](\n/u\n) \n", 11, 1},
		{"ab  \n<div>\nx\n</div>\n\nz\n", 4, 2},
		{"T\n=== \n", 7, 0},
		{"- one \n- two\n", 6, 1},
		// Not before more text of the line, not in code, and not in a
		// text with nothing in it.
		{"ab cd\n", 3, 0},
		{"```\nab \n```\n", 7, 0},
		{"-  \n", 3, 0},
		// Not after the marks of a later line with nothing in it.
		{"> ab\n> ", 7, 0},
		{"- ab\n  ", 7, 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		at := address_of(&doc, c.offset)
		testing.expect_value(t, at.spaces, c.spaces)
		// And back: the offset of a place after spaces is the one after
		// them.
		if at.spaces > 0 {
			offset, ok := source_of(&doc, at)
			testing.expect(t, ok)
			testing.expect_value(t, offset, c.offset)
		}
	}
}
