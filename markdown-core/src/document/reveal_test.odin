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
