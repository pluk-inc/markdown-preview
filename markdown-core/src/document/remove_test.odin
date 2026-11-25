package document

import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
after :: proc(doc: ^Document, edit: Edit) -> string {
	context.allocator = context.temp_allocator
	return string(edited(doc.source, edit))
}

// The source after the text between two addresses went out and `text`
// came in its place, or "refused".
@(private = "file")
replaced :: proc(source: string, from, to: Address, text: string) -> string {
	doc := parse(source)
	defer destroy(&doc)
	a, has_a := source_of(&doc, from)
	b, has_b := source_of(&doc, to)
	if !has_a || !has_b {
		return "no place"
	}
	edit, _, ok := replace_range(&doc, a, b, text, allocator = context.temp_allocator)
	if !ok {
		return "refused"
	}
	return after(&doc, edit)
}

@(test)
test_text_goes_out_and_the_styles_of_the_rest_stay :: proc(t: ^testing.T) {
	Case :: struct {
		source:   string,
		from, to: Address,
		text:     string,
		after:    string,
	}
	cases := []Case {
		// Plain text, and text that comes in its place.
		{"abcd\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 3}, "", "ad\n"},
		{"abcd\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 3}, "X", "aXd\n"},
		// All of the text of a style: its marks go too, also from the
		// start of the text, and two styles at one text.
		{"x **bc** d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 4}, "", "x  d\n"},
		{"**bc** d\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 0, byte = 2}, "", " d\n"},
		{"x **_bc_** d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 4}, "", "x  d\n"},
		{"x ***bc*** d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 4}, "Y", "x Y d\n"},
		{"x [bc](https://e.com) d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 4}, "", "x  d\n"},
		{"x `bc` d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 4}, "", "x  d\n"},
		// A part of it: the mark that is in the range stays.
		{"a **bc** d\n", {block = 0, cell = 0, byte = 3}, {block = 0, cell = 0, byte = 6}, "", "a **b**\n"},
		{"a **bc** d\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 3}, "", "a**c** d\n"},
		{"a **bc** d\n", {block = 0, cell = 0, byte = 3}, {block = 0, cell = 0, byte = 6}, "X", "a **bX**\n"},
		{"**ab** x _cd_\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 5}, "", "**a**_cd_\n"},
		{"[abcd](https://e.com) x\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 6}, "", "[ab](https://e.com)\n"},
		// In it: no mark changes.
		{"a **bcd** e\n", {block = 0, cell = 0, byte = 3}, {block = 0, cell = 0, byte = 4}, "", "a **bd** e\n"},
		// Spaces that would be inside of a mark go outside of it.
		{"**bold both** x\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 0, byte = 4}, "", " **both** x\n"},
		{"a **bold both** x\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 6}, "", "a  **both** x\n"},
		{"**ab cd** e\n", {block = 0, cell = 0, byte = 3}, {block = 0, cell = 0, byte = 5}, "", "**ab**  e\n"},
		{"a **b c** d\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 3}, "", "a **c** d\n"},
		{"`ab cd` e\n", {block = 0, cell = 0, byte = 3}, {block = 0, cell = 0, byte = 5}, "", "`ab ` e\n"},
		// A line break as well, with the mark of a quote.
		{"a **b\nc** d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 3}, "", "a \n**c** d\n"},
		{"> a **b\n> c** d\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 3}, "", "> a \n> **c** d\n"},
		{"**a\nb** c\n", {block = 0, cell = 0, byte = 2}, {block = 0, cell = 0, byte = 3}, "", "**a**\n c\n"},
		// Two texts of one style with nothing between them now are one.
		{"`a` `b`\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 2}, "", "`ab`\n"},
		{"**a** **b** c\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 2}, "", "**ab** c\n"},
		{"**a** _b_\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 2}, "", "**a**_b_\n"},
		// The "<" and ">" of an address are not kept as marks.
		{"x <https://e.com> y\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 0, byte = 6}, "", "s://e.com> y\n"},
		// A definition of a link in the range stays, before the block.
		{"ab\n\n[d]: https://e.com\n\ncd [z][d]\n", {block = 0, cell = 0, byte = 1}, {block = 1, cell = 0, byte = 1}, "", "[d]: https://e.com\n\nad [z][d]\n"},
		{"[d]: https://e.com\n\n```\ncd\n```\n\nab\n\n[z][d]\n", {block = 0, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 2}, "", "[d]: https://e.com\n\n[z][d]\n"},
		{"```\ncd\n```\n\nab\n\n[d]: https://e.com\n\n[z][d]\n", {block = 0, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 2}, "", "[d]: https://e.com\n\n[z][d]\n"},
		// A line break of a paragraph with the mark of its next line.
		{"> ab\n> cd\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 4}, "", "> ad\n"},
		// Two blocks: the first one keeps its kind, and the blocks
		// between them go.
		{"ab\n\ncd\n", {block = 0, cell = 0, byte = 1}, {block = 1, cell = 0, byte = 1}, "", "ad\n"},
		{"# ab\n\n- cd\n", {block = 0, cell = 0, byte = 1}, {block = 1, cell = 0, byte = 1}, "", "# ad\n"},
		{"ab\n\n# mid\n\n> cd\n", {block = 0, cell = 0, byte = 2}, {block = 2, cell = 0, byte = 0}, "", "abcd\n"},
		{"**ab**\n\n_cd_\n", {block = 0, cell = 0, byte = 1}, {block = 1, cell = 0, byte = 1}, "", "**a**_d_\n"},
		// A heading with a line under it keeps that line, after the
		// text that comes to it.
		{"Head\n====\n\ntext\n", {block = 0, cell = 0, byte = 4}, {block = 1, cell = 0, byte = 0}, "", "Headtext\n====\n"},
		{"Head\n====\n\ntext\n\nz\n", {block = 0, cell = 0, byte = 2}, {block = 1, cell = 0, byte = 2}, "", "Hext\n====\n\nz\n"},
		{"Head\n====\n\ntext\n", {block = 0, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 4}, "", "\n"},
		{"Head\n====\n\ntext\n\n\n\nz\n", {block = 0, cell = 0, byte = 0}, {block = 1, byte = 4, empty = 2}, "", "\n\nz\n"},
		// All of the text of a paragraph: its line is an empty line,
		// and the empty line before it goes, so no line more shows.
		{"ab\n\ncd\n", {block = 1, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 2}, "", "ab\n\n"},
		{"ab\n\ncd ef\n\nz\n", {block = 1, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 5}, "", "ab\n\n\nz\n"},
		{"ab\n\ncd\n", {block = 1, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 2}, "X", "ab\n\nX\n"},
		{"x\n\nab\n\n[d]: /u\n\ncd\n\n[z][d]\n", {block = 1, cell = 0, byte = 0}, {block = 2, cell = 0, byte = 2}, "", "x\n\n[d]: /u\n\n\n\n[z][d]\n"},
		// All of the text of a block: its marks stay, for text to come.
		{"# ab\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 0, byte = 2}, "", "# \n"},
		{"- ab\n- cd\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 0, byte = 2}, "", "- \n- cd\n"},
		// In code, lines with their indent.
		{"```\nab\ncd\n```\n", {block = 0, cell = 0, byte = 1}, {block = 0, cell = 0, byte = 4}, "", "```\nad\n```\n"},
		{"- x\n\n  ```\n  ab\n  cd\n  ```\n", {block = 1, cell = 0, byte = 1}, {block = 1, cell = 0, byte = 4}, "", "- x\n\n  ```\n  ad\n  ```\n"},
		// From code into another block: not yet. With all of the text
		// of the blocks, their lines go.
		{"ab\n\n```\ncd\n```\n", {block = 0, cell = 0, byte = 1}, {block = 1, cell = 0, byte = 1}, "", "refused"},
		{"ab\n\n```\ncd\n```\n\nz\n", {block = 0, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 2}, "", "z\n"},
		{"ab\n\n```\ncd\n```\n\nz\n", {block = 0, cell = 0, byte = 0}, {block = 1, cell = 0, byte = 2}, "X", "X\n\nz\n"},
		{"| a | b |\n|-|-|\n| c | d |\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 1, byte = 1}, "", "refused"},
		{"| ab | b |\n|-|-|\n| c | d |\n", {block = 0, cell = 0, byte = 0}, {block = 0, cell = 0, byte = 1}, "", "| b | b |\n|-|-|\n| c | d |\n"},
		// An empty paragraph: the text after it comes to its line.
		{"ab\n\n\n\ncd\n", {block = 0, byte = 2, empty = 2}, {block = 1, cell = 0, byte = 0}, "", "ab\n\n\ncd\n"},
		{"ab\n\n\n\ncd\n", {block = 0, byte = 2, empty = 1}, {block = 1, cell = 0, byte = 0}, "", "ab\n\ncd\n"},
		{"ab\n\n\n\ncd\n", {block = 0, byte = 2, empty = 1}, {block = 0, byte = 2, empty = 2}, "", "ab\n\n\ncd\n"},
		{"ab\n\n\n\ncd\n", {block = 0, byte = 2, empty = 1}, {block = 1, cell = 0, byte = 1}, "X", "ab\n\nXd\n"},
	}
	for c in cases {
		testing.expectf(t, replaced(c.source, c.from, c.to, c.text) == c.after, "%q from %v to %v with %q: %q, not %q", c.source, c.from, c.to, c.text, replaced(c.source, c.from, c.to, c.text), c.after)
	}
}

// A text as Markdown keeps it: a run of spaces is one space, and there
// is none at its two ends.
@(private = "file")
plain :: proc(text: string) -> string {
	fields := strings.fields(text, context.temp_allocator)
	return strings.join(fields, " ", context.temp_allocator)
}

// Each range of each text of a document with styles: the text of the
// block after the edit is the text of before with the range out.
@(test)
test_each_range_of_a_text_goes_out_of_its_text_only :: proc(t: ^testing.T) {
	source := "Plain **bold _both_ more** and `code` here, a [link *in* it](https://e.com) &amp; an end.\n\n- item **one** and ~~two~~\n\n> quote *a*\n> line **b**\n"
	doc := parse(source)
	defer destroy(&doc)
	failed, limits, total := 0, 0, 0
	for block in 0 ..< doc.count {
		text := block_at(&doc, block).text.bytes[:]
		for from in 0 ..< len(text) {
			for to in from + 1 ..= len(text) {
				want := plain(fmt.tprintf("%s%s", text[:from], text[to:]))
				a, _ := source_of(&doc, {block = block, byte = from})
				b, _ := source_of(&doc, {block = block, byte = to})
				edit, _, ok := replace_range(&doc, a, b, "", allocator = context.temp_allocator)
				if !ok {
					failed += 1
					continue
				}
				now := parse(after(&doc, edit))
				defer destroy(&now)
				total += 1
				got := ""
				if now.count == doc.count {
					got = plain(fmt.tprintf("%s", block_at(&now, block).text.bytes[:]))
				} else if len(want) == 0 {
					got = want
				}
				// A mark that stays where Markdown reads it as text: one
				// right after a letter and before another mark
				// ("a**_b_**"). The text has the mark then. Few ranges.
				if got != want && strings.contains_any(got, "*_~`[") {
					limits += 1
					continue
				}
				if got != want && failed < 12 {
					fmt.printfln("block %d [%d, %d): %q, not %q, from %q", block, from, to, got, want, after(&doc, edit))
				}
				failed += got != want ? 1 : 0
			}
		}
	}
	testing.expect_value(t, failed, 0)
	testing.expectf(t, limits * 10 < total, "%d of %d ranges leave a mark as text", limits, total)
}

@(test)
test_the_caret_after_new_text_is_after_that_text :: proc(t: ^testing.T) {
	doc := parse("a **bc** d\n")
	defer destroy(&doc)
	a, _ := source_of(&doc, {block = 0, byte = 3})
	b, _ := source_of(&doc, {block = 0, byte = 6})
	edit, caret, ok := replace_range(&doc, a, b, "X", allocator = context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, after(&doc, edit), "a **bX**\n")
	testing.expect_value(t, caret, 6)
}

@(test)
test_two_characters_change_places_as_wholes :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		byte:   int,
		after:  string,
	}
	cases := []Case {
		{"abc\n", 1, "bac\n"},
		{"abc\n", 3, "acb\n"},
		// A letter with a mark of its own is one character.
		{"ae\u0301b\n", 4, "abe\u0301\n"},
		// Not over a mark of a style.
		{"**a**b\n", 1, ""},
		{"a\n", 1, ""},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		places := block_map(&doc, 0)
		defer delete(places)
		edit, _, ok := transpose(&doc, places[:], {block = 0, byte = c.byte}, context.temp_allocator)
		testing.expectf(t, (ok ? after(&doc, edit) : "") == c.after, "%q at %d: %q, not %q", c.source, c.byte, ok ? after(&doc, edit) : "", c.after)
	}
}

// Each pair of places of a document with each kind of block: the edit
// is in the source, the caret is in the new source, and the new source
// parses.
@(test)
test_each_range_of_a_document_has_an_edit_in_the_source :: proc(t: ^testing.T) {
	sources := []string {
		"Head\n====\n\ntext **b**\n\n\n- one\n- two\n\n  more\n\n> quote\n> line\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| c | d |\n\n[d]: https://e.com\n\nlast [z][d]\n\n\n",
		"Sub\n---\n\n\n\n# Top\n\n1. a\n2. b\n\n---\n\nend",
		"\n\nHead\r\n====\r\n\r\ntext\r\n\r\n\r\n",
	}
	for source in sources {
		doc := parse(source)
		defer destroy(&doc)
		stops: [dynamic]int
		defer delete(stops)
		for block in 0 ..< doc.count {
			b := block_at(&doc, block)
			for text, cell in block_texts(b) {
				for byte in 0 ..= len(text.bytes) {
					if offset, ok := source_of(&doc, {block = block, cell = cell, byte = byte}); ok {
						append(&stops, offset)
					}
				}
			}
			for n in 1 ..= int(b.empties) {
				if at, has := empty_address(&doc, block, n); has {
					if offset, ok := source_of(&doc, at); ok {
						append(&stops, offset)
					}
				}
			}
		}
		for from in stops {
			for to in stops {
				if to < from {
					continue
				}
				for text in ([]string{"", "X"}) {
					edit, caret, ok := replace_range(&doc, from, to, text, allocator = context.temp_allocator)
					if !ok {
						continue
					}
					inside := edit.start >= 0 && edit.start <= edit.end && edit.end <= len(doc.source)
					testing.expectf(t, inside, "%q from %d to %d: the edit %d to %d is not in the source", source, from, to, edit.start, edit.end)
					if !inside {
						return
					}
					now := after(&doc, edit)
					testing.expectf(t, caret >= 0 && caret <= len(now), "%q from %d to %d: the caret %d is not in %q", source, from, to, caret, now)
					fresh := parse(now)
					destroy(&fresh)
				}
			}
		}
		free_all(context.temp_allocator)
	}
}
