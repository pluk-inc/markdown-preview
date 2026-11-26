package document

import "core:fmt"
import "core:strings"
import "core:testing"

// The text of the first block of a source with the marks of an offset
// as text, and the bytes of it that are such marks, as "^".
@(private = "file")
revealed :: proc(source: string, at: int) -> (text, marks: string) {
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", source), at)
	defer destroy(&doc)
	t := &block_at(&doc, 0).text
	shape := make([]u8, len(t.bytes), context.temp_allocator)
	for span in t.spans {
		for i in span.start ..< span.end {
			shape[i] = .Mark in span.style ? '^' : ' '
		}
	}
	return fmt.tprintf("%s", t.bytes[:]), string(shape)
}

@(test)
test_the_marks_of_the_element_of_an_offset_are_text :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		at:     int,
		text:   string,
		marks:  string,
	}
	cases := []Case {
		// Not in the element: the text of a reader.
		{"a **bc** d\n", 0, "a bc d", "      "},
		{"a **bc** d\n", 9, "a bc d", "      "},
		// At an end of it and in it: its two marks.
		{"a **bc** d\n", 2, "a **bc** d", "  ^^  ^^  "},
		{"a **bc** d\n", 5, "a **bc** d", "  ^^  ^^  "},
		{"a **bc** d\n", 8, "a **bc** d", "  ^^  ^^  "},
		// Only the elements that have the offset: the inner one of two
		// with it, and the outer one alone.
		{"**a _b_ c**\n", 5, "**a _b_ c**", "^^  ^ ^  ^^"},
		{"**a _b_ c**\n", 2, "**a b c**", "^^     ^^"},
		{"***b***\n", 3, "***b***", "^^^ ^^^"},
		// Code, struck text, and a link with its target.
		{"a `b` c\n", 3, "a `b` c", "  ^ ^  "},
		{"a ~~b~~ c\n", 4, "a ~~b~~ c", "  ^^ ^^  "},
		{"a [b](https://e.com) c\n", 3, "a [b](https://e.com) c", "  ^ ^^^^^^^^^^^^^^^^  "},
		// The "#" of a heading, for an offset in its line, with the
		// marks of an element of the line only for an offset in it.
		{"## Title **b**\n\ntext\n", 0, "## Title b", "^^^       "},
		{"## Title **b**\n\ntext\n", 5, "## Title b", "^^^       "},
		{"## Title **b**\n\ntext\n", 12, "## Title **b**", "^^^      ^^ ^^"},
		{"## Title **b**\n\ntext\n", 17, "Title b", "       "},
		{"# **b** c\n", 3, "# **b** c", "^^^^ ^^  "},
		// With text that starts with a character with a backslash, in
		// a quote and a list item, and with no text at all.
		{"# \\#x\n", 4, "# #x", "^^  "},
		{"> ## T\n", 5, "> ## T", "^^^^^ "},
		{"- # T\n", 5, "# T", "^^ "},
		{"## \n\ntext\n", 1, "## ", "^^^"},
		{"#\n\ntext\n", 0, "#", "^"},
		// With raw HTML or a NUL byte at the start of the text.
		{"# <b>x</b>\n", 6, "# x", "^^ "},
		{"# \x00b\n", 4, "# \uFFFDb", "^^    "},
		// The mark of a list item and of a quote, for an offset in the
		// block: the "-", the number, the ">", and the marks of a block
		// that is in more than one. Not for an offset in another block.
		{"- one\n- two\n", 3, "one", "   "},
		{"- one\n- two\n", 5, "one", "   "},
		{"- one\n- two\n", 6, "one", "   "},
		{"12. one\n", 5, "one", "   "},
		{"> quote\n", 4, "> quote", "^^     "},
		{"> - a\n", 4, "a", " "},
		// The first line only: a later line of a quote keeps its mark
		// out of the text.
		{"> one\n> two\n", 9, "> one two", "^^       "},
		{"- a\n\n> one\n> two\n", 0, "a", " "},
		// The check box of a task is its mark: no text for it.
		{"- [ ] task\n", 8, "task", "    "},
		{"- [x] task\n", 8, "task", "    "},
		{"- [ ] \n", 3, "", ""},
		// An item with nothing in it and nothing after its mark: the mark
		// is plain text that is being typed (no bullet, no check box)
		// until a space comes after it.
		{"-\n", 1, "-", " "},
		{"12.\n", 2, "12.", "   "},
		{"- [ ]\n", 3, "- [ ]", "     "},
		{"> -\n", 3, "> -", "   "},
		// With the space, a list item: its bullet, also at the caret.
		{"* \n", 1, "", ""},
		// A later block of an item has only its indent, which is no mark.
		{"plain\n", 2, "plain", "     "},
		// Not the line under a heading.
		{"Title\n=====\n", 2, "Title", "     "},
		// Of code that goes on in a next line of a quote, the backticks
		// only.
		{"> `\n> x\n> `\n", 6, "> `x`", "^^^ ^"},
		// The target of a link in a next line of a quote: no line break
		// and no mark of the quote in the text.
		{"> [x](\n> /a)\n", 3, "> [x](/a)", "^^^ ^^^^^"},
		// Not the "<" and ">" of an address.
		{"a <https://e.com> c\n", 5, "a https://e.com c", "                 "},
	}
	for c in cases {
		text, marks := revealed(c.source, c.at)
		testing.expectf(t, text == c.text && marks == c.marks, "%q at %d: %q %q, not %q %q", c.source, c.at, text, marks, c.text, c.marks)
	}
}

// With marks as text, each byte of the text of a block has its place in
// the source and comes back from it, and an edit gives what a parse of
// all of the new source gives.
@(test)
test_a_block_with_marks_as_text_has_its_places :: proc(t: ^testing.T) {
	source := "# Head *h*\n\nx\n\na **bc** and `d` [e](https://e.com) f\n\n- item _g_\n\n  more of it\n- [ ] task\n\n> quote\n> two\n\n1. n\n\n### Last\n"
	for at in 0 ..= len(source) {
		doc := parse_owned(transmute([]u8)fmt.aprintf("%s", source), at)
		defer destroy(&doc)
		for block in 0 ..< doc.count {
			places := block_map(&doc, block)
			defer delete(places)
			text := block_at(&doc, block).text.bytes[:]
			for byte in 0 ..= len(text) {
				// A byte in a thing that the source has in another form
				// (the mark of a task, which has its check box) is no
				// place of its own: the thing is one piece.
				inside := false
				for place in places {
					inside ||= place.whole && byte > place.text && byte < place.text + place.text_len
				}
				if inside {
					continue
				}
				offset, ok := place_of(&doc, places[:], {block = block, byte = byte})
				testing.expectf(t, ok, "reveal %d: no place for byte %d of block %d", at, byte, block)
				back := address_for(&doc, places[:], block, offset)
				// The end of a thing that the source has in another form
				// comes back as that end.
				testing.expectf(t, back.byte == byte || !ok, "reveal %d: byte %d of block %d (%q) is offset %d and comes back as %d", at, byte, block, text, offset, back.byte)
			}
		}
		// A character typed at the offset, with the marks of the place
		// after it.
		pending := prepare(&doc, {at, at, "q"}, at + 1)
		commit(&doc, &pending)
		discard(&pending)
		all := parse_owned(transmute([]u8)fmt.aprintf("%s", doc.source), at + 1)
		defer destroy(&all)
		testing.expectf(t, doc.count == all.count, "reveal %d: %d blocks after a typed character, not %d", at, doc.count, all.count)
		for block in 0 ..< min(doc.count, all.count) {
			testing.expectf(t, layout_equal(block_at(&doc, block), block_at(&all, block)), "reveal %d: block %d after a typed character is %q, not %q", at, block, block_at(&doc, block).text.bytes[:], block_at(&all, block).text.bytes[:])
		}
	}
}

// The text of one block made again with the marks of an offset, and
// with none again: what a parse of all of the source gives each time,
// with the links of the text as they were.
@(test)
test_one_block_gets_its_marks_and_loses_them :: proc(t: ^testing.T) {
	source := "## T [t](https://t.com)\n\nx [a](https://a.com)\n\na **bc** and `d` [e](https://e.com) f [g](https://g.com)\n\n- item _g_\n\n| a | **b** |\n|---|---|\n| c | d |\n"
	plain := parse(source)
	defer destroy(&plain)
	for at in 0 ..= len(source) {
		doc := parse(source)
		defer destroy(&doc)
		block := block_at_offset(&doc, at)
		places, change := reveal_block(&doc, block, at)
		delete(places)
		testing.expect_value(t, change.first, block)
		all := parse_owned(transmute([]u8)fmt.aprintf("%s", source), at)
		defer destroy(&all)
		same := layout_equal(block_at(&doc, block), block_at(&all, block))
		testing.expectf(t, same, "reveal %d: block %d is %q, not %q", at, block, block_at(&doc, block).text.bytes[:], block_at(&all, block).text.bytes[:])
		testing.expect_value(t, doc.reveal != nil, all.reveal != nil)
		for &text, cell in block_texts(block_at(&doc, block)) {
			for span, i in text.spans {
				if !same {
					break
				}
				want := block_texts(block_at(&all, block))[cell].spans[i]
				testing.expectf(t, (span.link == 0) == (want.link == 0) && (span.link == 0 || doc.links[span.link - 1] == all.links[want.link - 1]), "reveal %d: a span of block %d has another link", at, block)
			}
		}
		places, _ = reveal_block(&doc, block, nil)
		delete(places)
		testing.expectf(t, layout_equal(block_at(&doc, block), block_at(&plain, block)), "reveal %d: block %d with no marks again is %q", at, block, block_at(&doc, block).text.bytes[:])
		testing.expect(t, doc.reveal == nil)
	}
}

// Many uses of a long definition in one paragraph, and a long paragraph
// far from it: a parse of the lines of the paragraph alone has no room
// for all of the links that a parse of all of the source has. The
// paragraph keeps each link when its marks show.
@(test)
test_marks_that_show_keep_the_links_of_a_block :: proc(t: ^testing.T) {
	target := strings.repeat("a", 1000)
	defer delete(target)
	uses := strings.repeat("[r] ", 40)
	defer delete(uses)
	filler := strings.repeat("word ", 1600)
	defer delete(filler)
	source := strings.concatenate({"[r]: /", target, "\n\n**b** ", uses, "end\n\n", filler, "\n"})
	defer delete(source)
	doc := parse(source)
	defer destroy(&doc)
	at := strings.index(source, "**b**") + 3
	places, _ := reveal_block(&doc, 0, at)
	delete(places)
	text := string(block_at(&doc, 0).text.bytes[:])
	testing.expect(t, strings.has_prefix(text, "**b** r r r "))
	testing.expect(t, !strings.contains(text, "[r]"))
	testing.expect_value(t, links_in(block_at(&doc, 0)), 40)
}

// The two styles of "***b***" are one mark of the parser: the two show
// for the same offsets, and a delete of the marks that show takes what
// shows and no mark more.
@(test)
test_two_styles_of_one_mark_show_for_the_same_offsets :: proc(t: ^testing.T) {
	doc := parse("x ***b*** y\n")
	defer destroy(&doc)
	pairs: [dynamic]Pair
	defer delete(pairs)
	places := block_map(&doc, 0, &pairs)
	delete(places)
	testing.expect_value(t, len(pairs), 2)
	for pair in pairs {
		testing.expect_value(t, pair.from, 2)
		testing.expect_value(t, pair.to, 9)
	}
}

// One character at a mark that goes on in a next line of a quote: the
// bytes of the character, with the line break and the mark of the quote
// between the two pieces of the mark left as they are.
@(test)
test_a_character_of_a_mark_over_two_lines_is_its_bytes :: proc(t: ^testing.T) {
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", "> [x](\n> /a)\n"), 3)
	defer destroy(&doc)
	places := block_map(&doc, 0)
	defer delete(places)
	text := string(block_at(&doc, 0).text.bytes[:])
	testing.expect_value(t, text, "> [x](/a)")
	// The "/" is the seventh character.
	first, last, ok := char_before(&doc, places[:], {block = 0, byte = 7})
	testing.expect(t, ok)
	testing.expect_value(t, string(doc.source[first:last]), "/")
}

@(test)
test_the_source_of_a_character_of_some_code_points :: proc(t: ^testing.T) {
	// A letter with a mark of its own, and an emoji of three parts.
	for source in ([]string{"aéb\n", "a\U0001F469‍\U0001F4BBb\n"}) {
		doc := parse(source)
		defer destroy(&doc)
		places := block_map(&doc, 0)
		defer delete(places)
		text := block_at(&doc, 0).text.bytes[:]
		to := char_step(text, 1, true)
		first, last, ok := char_source(&doc, places[:], {block = 0}, 1, to)
		testing.expect(t, ok)
		testing.expect_value(t, first, 1)
		testing.expect_value(t, last, len(source) - 2)
	}
}

// The marks of a block that has more than one line are one mark, of its
// first line, also with the caret in another block; and a parse that
// notes marks makes the blocks that a parse with none makes.
@(test)
test_a_block_has_one_line_mark :: proc(t: ^testing.T) {
	doc := parse("> one\n> two\n> three\n\n- a\n- <b></b>\n- c\n")
	defer destroy(&doc)
	pairs: [dynamic]Pair
	defer delete(pairs)
	places := block_map(&doc, 0, &pairs)
	delete(places)
	testing.expect_value(t, len(pairs), 1)
	// An item with only raw HTML has no block, with marks noted too.
	for at in 0 ..= len(doc.source) {
		all := parse_owned(transmute([]u8)fmt.aprintf("%s", doc.source), at)
		testing.expect_value(t, all.count, doc.count)
		destroy(&all)
	}
}

// An item of a list whose first paragraph has no text that shows (raw
// HTML, an image with no text): a parse that notes marks makes the
// blocks that a parse with none makes, and the block after it has its
// places and gets its marks. (Not an image with no text: an offset in
// it shows its marks, which are text of a block then; no caret is at
// such an offset, because the image has no place for one.)
@(test)
test_marks_make_no_block_for_an_item_with_no_text :: proc(t: ^testing.T) {
	for source in ([]string{"- a\n- <b></b>\n  - y\n", "1. <b></b>\n   1. y\n", "> - <i></i>\n>   - y\n", "- <b></b>\n  # hh\n", "- [ ] <b></b>\n  - y\n"}) {
		doc := parse(source)
		defer destroy(&doc)
		last := doc.count - 1
		for at in 0 ..= len(source) {
			all := parse_owned(transmute([]u8)fmt.aprintf("%s", source), at)
			testing.expectf(t, all.count == doc.count, "%q with the marks of %d: %d blocks, not %d", source, at, all.count, doc.count)
			destroy(&all)
		}
		places := block_map(&doc, last)
		testing.expectf(t, len(places) > 0, "%q: no places for its last block", source)
		delete(places)
		before := fmt.tprintf("%s", block_at(&doc, last).text.bytes[:])
		places, _ = reveal_block(&doc, last, len(source) - 1)
		delete(places)
		testing.expectf(t, len(block_at(&doc, last).text.bytes) >= len(before), "%q: the last block lost its text with marks", source)
		places, _ = reveal_block(&doc, last, nil)
		delete(places)
		testing.expect_value(t, fmt.tprintf("%s", block_at(&doc, last).text.bytes[:]), before)
	}
}

// Text that is typed before the first letter of a task at the caret
// goes after its check box: the text starts there, and an offset in the
// check box is the start of the text.
@(test)
test_the_text_of_a_task_starts_after_its_check_box :: proc(t: ^testing.T) {
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", "12. [x] task\n"), 9)
	defer destroy(&doc)
	testing.expect_value(t, fmt.tprintf("%s", block_at(&doc, 0).text.bytes[:]), "task")
	testing.expect(t, !block_at(&doc, 0).mark_shown)
	offset, ok := source_of(&doc, {block = 0, byte = 0})
	testing.expect(t, ok)
	testing.expect_value(t, offset, 8)
	testing.expect_value(t, address_of(&doc, 5), Address{block = 0, byte = 0})
}

// The mark of an item with nothing in it shows as its text at the caret,
// and the item draws no bullet then; text that is typed goes after it.
// An empty task with nothing after its "]" draws no check box.
@(test)
test_an_empty_item_shows_its_mark_at_the_caret :: proc(t: ^testing.T) {
	task := parse_owned(transmute([]u8)fmt.aprintf("%s", "- [ ]\n"), 5)
	defer destroy(&task)
	testing.expect(t, block_at(&task, 0).marker == .Bullet && block_at(&task, 0).mark_shown)
	spaced := parse_owned(transmute([]u8)fmt.aprintf("%s", "- [ ] \n"), 5)
	defer destroy(&spaced)
	testing.expect(t, block_at(&spaced, 0).marker == .Task_Open)
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", "-\n"), 1)
	defer destroy(&doc)
	testing.expect_value(t, fmt.tprintf("%s", block_at(&doc, 0).text.bytes[:]), "-")
	testing.expect(t, block_at(&doc, 0).mark_shown)
	offset, ok := source_of(&doc, {block = 0, byte = 1})
	testing.expect(t, ok)
	testing.expect_value(t, offset, 1)
	// A second item with nothing in it, after one with text.
	second := parse_owned(transmute([]u8)fmt.aprintf("%s", "- a\n-\n"), 5)
	defer destroy(&second)
	testing.expect_value(t, fmt.tprintf("%s", block_at(&second, 1).text.bytes[:]), "-")
	testing.expect_value(t, fmt.tprintf("%s", block_at(&second, 0).text.bytes[:]), "a")
	// With no caret there, the bullet.
	plain := parse("-\n")
	defer destroy(&plain)
	testing.expect_value(t, len(block_at(&plain, 0).text.bytes), 0)
	testing.expect(t, !block_at(&plain, 0).mark_shown)
}
