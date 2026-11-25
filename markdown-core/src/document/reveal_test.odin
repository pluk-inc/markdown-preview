package document

import "core:fmt"
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
		{"> ## T\n", 5, "## T", "^^^ "},
		{"- # T\n", 5, "# T", "^^ "},
		{"## \n\ntext\n", 1, "## ", "^^^"},
		{"#\n\ntext\n", 0, "#", "^"},
		// With raw HTML or a NUL byte at the start of the text.
		{"# <b>x</b>\n", 6, "# x", "^^ "},
		{"# \x00b\n", 4, "# \uFFFDb", "^^    "},
		// Not the line under a heading.
		{"Title\n=====\n", 2, "Title", "     "},
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
	source := "# Head *h*\n\nx\n\na **bc** and `d` [e](https://e.com) f\n\n- item _g_\n\n### Last\n"
	for at in 0 ..= len(source) {
		doc := parse_owned(transmute([]u8)fmt.aprintf("%s", source), at)
		defer destroy(&doc)
		for block in 0 ..< doc.count {
			places := block_map(&doc, block)
			defer delete(places)
			text := block_at(&doc, block).text.bytes[:]
			for byte in 0 ..= len(text) {
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
				want := block_texts(block_at(&all, block))[cell].spans[i]
				if !same {
					break
				}
				testing.expectf(t, (span.link == 0) == (want.link == 0) && (span.link == 0 || doc.links[span.link - 1] == all.links[want.link - 1]), "reveal %d: a span of block %d has another link", at, block)
			}
		}
		places, _ = reveal_block(&doc, block, nil)
		delete(places)
		testing.expectf(t, layout_equal(block_at(&doc, block), block_at(&plain, block)), "reveal %d: block %d with no marks again is %q", at, block, block_at(&doc, block).text.bytes[:])
		testing.expect(t, doc.reveal == nil)
	}
}
