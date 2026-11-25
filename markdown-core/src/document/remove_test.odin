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
		{"abcd\n", {0, 0, 1}, {0, 0, 3}, "", "ad\n"},
		{"abcd\n", {0, 0, 1}, {0, 0, 3}, "X", "aXd\n"},
		// All of the text of a style: its marks go too, also from the
		// start of the text, and two styles at one text.
		{"x **bc** d\n", {0, 0, 2}, {0, 0, 4}, "", "x  d\n"},
		{"**bc** d\n", {0, 0, 0}, {0, 0, 2}, "", " d\n"},
		{"x **_bc_** d\n", {0, 0, 2}, {0, 0, 4}, "", "x  d\n"},
		{"x ***bc*** d\n", {0, 0, 2}, {0, 0, 4}, "Y", "x Y d\n"},
		{"x [bc](https://e.com) d\n", {0, 0, 2}, {0, 0, 4}, "", "x  d\n"},
		{"x `bc` d\n", {0, 0, 2}, {0, 0, 4}, "", "x  d\n"},
		// A part of it: the mark that is in the range stays.
		{"a **bc** d\n", {0, 0, 3}, {0, 0, 6}, "", "a **b**\n"},
		{"a **bc** d\n", {0, 0, 1}, {0, 0, 3}, "", "a**c** d\n"},
		{"a **bc** d\n", {0, 0, 3}, {0, 0, 6}, "X", "a **bX**\n"},
		{"**ab** x _cd_\n", {0, 0, 1}, {0, 0, 5}, "", "**a**_cd_\n"},
		{"[abcd](https://e.com) x\n", {0, 0, 2}, {0, 0, 6}, "", "[ab](https://e.com)\n"},
		// In it: no mark changes.
		{"a **bcd** e\n", {0, 0, 3}, {0, 0, 4}, "", "a **bd** e\n"},
		// Spaces that would be inside of a mark go outside of it.
		{"**bold both** x\n", {0, 0, 0}, {0, 0, 4}, "", " **both** x\n"},
		{"a **bold both** x\n", {0, 0, 2}, {0, 0, 6}, "", "a  **both** x\n"},
		{"**ab cd** e\n", {0, 0, 3}, {0, 0, 5}, "", "**ab**  e\n"},
		{"a **b c** d\n", {0, 0, 1}, {0, 0, 3}, "", "a **c** d\n"},
		{"`ab cd` e\n", {0, 0, 3}, {0, 0, 5}, "", "`ab ` e\n"},
		// A line break as well, with the mark of a quote.
		{"a **b\nc** d\n", {0, 0, 2}, {0, 0, 3}, "", "a \n**c** d\n"},
		{"> a **b\n> c** d\n", {0, 0, 2}, {0, 0, 3}, "", "> a \n> **c** d\n"},
		{"**a\nb** c\n", {0, 0, 2}, {0, 0, 3}, "", "**a**\n c\n"},
		// Two texts of one style with nothing between them now are one.
		{"`a` `b`\n", {0, 0, 1}, {0, 0, 2}, "", "`ab`\n"},
		{"**a** **b** c\n", {0, 0, 1}, {0, 0, 2}, "", "**ab** c\n"},
		{"**a** _b_\n", {0, 0, 1}, {0, 0, 2}, "", "**a**_b_\n"},
		// The "<" and ">" of an address are not kept as marks.
		{"x <https://e.com> y\n", {0, 0, 0}, {0, 0, 6}, "", "s://e.com> y\n"},
		// A definition of a link in the range stays, before the block.
		{"ab\n\n[d]: https://e.com\n\ncd [z][d]\n", {0, 0, 1}, {1, 0, 1}, "", "[d]: https://e.com\n\nad [z][d]\n"},
		{"[d]: https://e.com\n\n```\ncd\n```\n\nab\n\n[z][d]\n", {0, 0, 0}, {1, 0, 2}, "", "[d]: https://e.com\n\n[z][d]\n"},
		{"```\ncd\n```\n\nab\n\n[d]: https://e.com\n\n[z][d]\n", {0, 0, 0}, {1, 0, 2}, "", "[d]: https://e.com\n\n[z][d]\n"},
		// A line break of a paragraph with the mark of its next line.
		{"> ab\n> cd\n", {0, 0, 1}, {0, 0, 4}, "", "> ad\n"},
		// Two blocks: the first one keeps its kind, and the blocks
		// between them go.
		{"ab\n\ncd\n", {0, 0, 1}, {1, 0, 1}, "", "ad\n"},
		{"# ab\n\n- cd\n", {0, 0, 1}, {1, 0, 1}, "", "# ad\n"},
		{"ab\n\n# mid\n\n> cd\n", {0, 0, 2}, {2, 0, 0}, "", "abcd\n"},
		{"**ab**\n\n_cd_\n", {0, 0, 1}, {1, 0, 1}, "", "**a**_d_\n"},
		// All of the text of a block: its marks stay, for text to come.
		{"# ab\n", {0, 0, 0}, {0, 0, 2}, "", "# \n"},
		{"- ab\n- cd\n", {0, 0, 0}, {0, 0, 2}, "", "- \n- cd\n"},
		// In code, lines with their indent.
		{"```\nab\ncd\n```\n", {0, 0, 1}, {0, 0, 4}, "", "```\nad\n```\n"},
		{"- x\n\n  ```\n  ab\n  cd\n  ```\n", {1, 0, 1}, {1, 0, 4}, "", "- x\n\n  ```\n  ad\n  ```\n"},
		// From code into another block: not yet. With all of the text
		// of the blocks, their lines go.
		{"ab\n\n```\ncd\n```\n", {0, 0, 1}, {1, 0, 1}, "", "refused"},
		{"ab\n\n```\ncd\n```\n\nz\n", {0, 0, 0}, {1, 0, 2}, "", "z\n"},
		{"ab\n\n```\ncd\n```\n\nz\n", {0, 0, 0}, {1, 0, 2}, "X", "X\n\nz\n"},
		{"| a | b |\n|-|-|\n| c | d |\n", {0, 0, 0}, {0, 1, 1}, "", "refused"},
		{"| ab | b |\n|-|-|\n| c | d |\n", {0, 0, 0}, {0, 0, 1}, "", "| b | b |\n|-|-|\n| c | d |\n"},
		// An empty paragraph: the text after it comes to its line.
		{"ab\n\n\n\ncd\n", {0, 0, 4}, {1, 0, 0}, "", "ab\n\n\ncd\n"},
		{"ab\n\n\n\ncd\n", {0, 0, 3}, {1, 0, 0}, "", "ab\n\ncd\n"},
		{"ab\n\n\n\ncd\n", {0, 0, 3}, {0, 0, 4}, "", "ab\n\n\ncd\n"},
		{"ab\n\n\n\ncd\n", {0, 0, 3}, {1, 0, 1}, "X", "ab\n\nXd\n"},
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
				a, _ := source_of(&doc, {block, 0, from})
				b, _ := source_of(&doc, {block, 0, to})
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
