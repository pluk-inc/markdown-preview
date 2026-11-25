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
		// Of code that goes on in a next line of a quote, the backticks
		// only.
		{"> `\n> x\n> `\n", 6, "`x`", "^ ^"},
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
	source := "x\n\na **bc** and `d` [e](https://e.com) f\n\n- item _g_\n"
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
	source := "x [a](https://a.com)\n\na **bc** and `d` [e](https://e.com) f [g](https://g.com)\n\n- item _g_\n\n| a | **b** |\n|---|---|\n| c | d |\n"
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
