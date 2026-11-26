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

// Code in a fence with no line of code has a place for a caret, and
// text there is a line of the code of its block: with the indent of a
// list item and the mark of a quote.
@(test)
test_code_with_no_line_takes_text :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		block:  int,
		place:  int, // -1 for none
		after:  string, // with "x" typed at the place
		caret:  int,
	}
	cases := []Case {
		{"```\n```\n", 0, 4, "```\nx\n```\n", 5},
		{"x\r\n\r\n~~~js\r\n~~~\r\n", 1, 12, "x\r\n\r\n~~~js\r\nx\r\n~~~\r\n", 13},
		// The fence is not closed: the end of the source.
		{"```\n", 0, 4, "```\nx\n", 5},
		// An empty line of code is the place.
		{"```\n\n```\n", 0, 4, "```\nx\n```\n", 5},
		// In a list item and in a quote.
		{"- item\n\n  ```\n  ```\n", 1, 14, "- item\n\n  ```\n  x\n  ```\n", 17},
		{"- ```\n- b\n", 0, 6, "- ```\n  x\n- b\n", 9},
		{"> ```\n> ```\n", 0, 6, "> ```\n> x\n> ```\n", 9},
		{"> ```\n>\n> ```\n", 0, 7, "> ```\n>x\n> ```\n", 8},
		// No line break after the fence: no line for code yet.
		{"```", 0, -1, "", 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		at := Address{block = c.block}
		testing.expect_value(t, block_at(&doc, c.block).kind, Block_Kind.Code)
		offset, placed := source_of(&doc, at)
		testing.expect_value(t, placed, c.place >= 0)
		if !placed {
			continue
		}
		testing.expect_value(t, offset, c.place)
		text, caret := "x", 1
		own, own_caret, first := code_first_line(&doc, at, offset, "x")
		defer delete(own)
		if first {
			text, caret = own, own_caret
		}
		apply(&doc, {offset, offset, text})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, offset + caret, c.caret)
	}
}

// Return in the line of a fence that was typed starts the first line of
// the code, and closes code that has no closing fence.
@(test)
test_return_in_the_line_of_a_fence :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		block:  int,
		offset: int,
		after:  string,
		caret:  int,
	}
	cases := []Case {
		{"```\n", 0, 3, "```\n\n```\n", 4},
		{"```js", 0, 5, "```js\n\n```", 6},
		{"a\n\n```\n\nmore\n", 1, 6, "a\n\n```\n\n```\n\nmore\n", 7},
		{"- ```\n", 0, 5, "- ```\n  \n  ```\n", 8},
		{"> ```\n", 0, 5, "> ```\n> \n> ```\n", 8},
		// Code with a closing fence gets a line only.
		{"```\n```\n", 0, 3, "```\n\n```\n", 4},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		text, caret, ok := fence_return(&doc, {block = c.block}, c.offset)
		defer delete(text)
		if !testing.expect(t, ok) {
			continue
		}
		apply(&doc, {c.offset, c.offset, text})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, c.offset + caret, c.caret)
		// The caret is in the code, at a place of its own.
		landed := address_of(&doc, c.offset + caret)
		back, placed := source_of(&doc, landed)
		testing.expect(t, placed)
		testing.expect_value(t, back, c.offset + caret)
	}
	// Not in the code, and not in another block.
	doc := parse("```\nab\n```\n\ntext\n")
	defer destroy(&doc)
	_, _, in_code := fence_return(&doc, {block = 0, byte = 1}, 5)
	_, _, in_text := fence_return(&doc, {block = 1}, 13)
	testing.expect(t, !in_code && !in_text)
}

// Text that was typed made a fence: a new fence gets its closing fence,
// a closing fence before the one that was there goes, and a closing
// fence in the middle of closed code is no end of it.
@(test)
test_a_typed_fence :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		before: Code_Before,
		offset: int,
		kind:   Typed_Fence,
		after:  string, // with the edit of the rule
	}
	cases := []Case {
		// A new fence: closed at once, also before other code.
		{"a\n\n```\n\nmore\n", {}, 6, .Opened, "a\n\n```\n```\n\nmore\n"},
		{"```\n```\nx\n```\n", {}, 3, .Opened, "```\n```\n```\nx\n```\n"},
		{"- ```\n", {}, 5, .Opened, "- ```\n  ```\n"},
		{"> ~~~js", {}, 7, .Opened, "> ~~~js\n> ~~~"},
		// One more character of a fence that was typed, and of its
		// closing fence.
		{"````\n```\n", {true, true, true}, 4, .Opened, "````\n````\n"},
		{"`````\n```\n", {true, true, true}, 5, .Opened, "`````\n`````\n"},
		// The closing fence of other code is not its own.
		{"````\nx\n```\n", {true, false, false}, 4, .None, ""},
		// The word after a fence that is there: nothing.
		{"```js\n```\n", {true, true, false}, 5, .None, ""},
		// A closing fence before the one of the code: it goes.
		{"```\nx\n```\n```\n\nmore\n", {true, true, false}, 9, .Closed_Twice, "```\nx\n```\n\nmore\n"},
		// In the middle of closed code: nothing.
		{"```\nx\n```\ny\n```\n", {true, true, false}, 9, .None, ""},
		// Code with no closing fence gets one.
		{"```\nx\n```\n", {true, false, false}, 9, .Closed, ""},
		// The line of a typed fence is no fence any more: its closing
		// fence goes.
		{"```x`\n```\n\nmore\n", {true, true, true}, 5, .Unopened, "```x`\n\nmore\n"},
		{"a\n\n\n```\n\nmore\n", {true, true, true}, 3, .Unopened, "a\n\n\n\nmore\n"},
		// The word after it only changed: nothing.
		{"```js\n```\n", {true, true, true}, 5, .None, ""},
		// The space after the ">" of a quote is of the quote.
		{">```\n> x\n>    ```\n", {true, false, false}, 17, .Closed, ""},
		{">```\n> x\n>     ```\n", {true, false, false}, 18, .None, ""},
		// An edit before the line of a typed fence: its closing fence
		// stays.
		{"ext\n\n```\n```\n\nMore\n", {true, true, true}, 8, .None, ""},
		// A fence after four spaces is a line of code, no closing fence.
		{"```\nx\n    ```\n", {true, false, false}, 13, .None, ""},
		{"- ```\n  x\n     ```\n", {true, false, false}, 18, .Closed, ""},
		// A line of code that ends with a fence is no closing fence.
		{"```\necho ```\n", {true, false, false}, 12, .None, ""},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		kind, start, end, text := typed_fence(&doc, c.before, address_of(&doc, c.offset), c.offset)
		defer delete(text)
		testing.expect_value(t, kind, c.kind)
		if kind == c.kind && (kind == .Opened || kind == .Closed_Twice || kind == .Unopened) {
			apply(&doc, {start, end, text})
			testing.expect_value(t, string(doc.source), c.after)
		}
	}
}

// A caret in the line of the closing fence of its code goes to an empty
// paragraph after the code. With none there, one is made; where none can
// be (the next block is in a list or in a quote with the code), the
// caret does not leave.
@(test)
test_the_caret_leaves_a_closing_fence :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		offset: int,
		leaves: bool,
		after:  string,
		caret:  int,
	}
	cases := []Case {
		{"```\nx\n```\n", 9, true, "```\nx\n```\n\n", 10},
		{"```\nx\n```", 9, true, "```\nx\n```\n\n", 10},
		// One empty line is what is between two blocks: one more.
		{"```\nx\n```\n\nmore\n", 9, true, "```\nx\n```\n\n\nmore\n", 10},
		// An empty paragraph is there.
		{"```\nx\n```\n\n\nmore\n", 9, true, "```\nx\n```\n\n\nmore\n", 10},
		{"```\r\nx\r\n```\r\n", 11, true, "```\r\nx\r\n```\r\n\r\n", 13},
		// Not out of a list and not out of a quote that go on.
		{"- a\n- ```\n  x\n  ```\n- b\n", 20, false, "", 0},
		{"> ~~~\n> x\n> ~~~\n> more\n", 14, false, "", 0},
		// Not for a caret in the code.
		{"```\nx\n```\n", 5, false, "", 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		at, text, caret, ok := code_exit(&doc, address_of(&doc, c.offset), c.offset)
		defer delete(text)
		testing.expect_value(t, ok, c.leaves)
		if !ok || !c.leaves {
			continue
		}
		apply(&doc, {at, at, text})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, caret, c.caret)
		// The caret is in an empty paragraph, at that offset again.
		landed := address_of(&doc, caret)
		testing.expect(t, empty_of(&doc, landed) > 0)
		back, placed := source_of(&doc, landed)
		testing.expect(t, placed)
		testing.expect_value(t, back, caret)
	}
}

// A text with line breaks that is put into code with no line (a paste):
// each of its lines is a line of the code of its block.
@(test)
test_pasted_lines_are_lines_of_the_code :: proc(t: ^testing.T) {
	Case :: struct {
		source, text, after: string,
		place, caret:        int,
	}
	cases := []Case {
		{"> ```\n> ```\n", "a\nb", "> ```\n> a\n> b\n> ```\n", 6, 13},
		{"- ```\n  ```\n", "a\nb\n", "- ```\n  a\n  b\n  \n  ```\n", 6, 16},
		{"```\r\n```\r\n", "a\r\nb", "```\r\na\r\nb\r\n```\r\n", 5, 9},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		own, caret, ok := code_first_line(&doc, {block = 0}, c.place, c.text)
		defer delete(own)
		if !testing.expect(t, ok) {
			continue
		}
		apply(&doc, {c.place, c.place, own})
		testing.expect_value(t, string(doc.source), c.after)
		testing.expect_value(t, c.place + caret, c.caret)
	}
}
