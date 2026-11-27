package document

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

// The cases that the footnotes of the app's web renderer are tested with
// too (footnote_cases.json, beside this file; a case with `web` false is
// a kind of footnote that only the core reads): the footnotes in the
// order of the source with their numbers, and the references in the
// order of the source with the number that they show.
@(test)
test_footnotes_of_the_shared_cases :: proc(t: ^testing.T) {
	Note :: struct {
		number: int,
		label:  string,
		inline: bool,
	}
	Reference :: struct {
		text:            string,
		number, ordinal: int,
	}
	Case :: struct {
		source:     string,
		notes:      []Note,
		references: []Reference,
		web:        bool,
	}
	cases: []Case
	if err := json.unmarshal(#load("footnote_cases.json"), &cases, allocator = context.temp_allocator); err != nil {
		testing.fail_now(t, fmt.tprint("the cases do not parse:", err))
	}
	for c in cases {
		want := strings.builder_make(context.temp_allocator)
		for n in c.notes {
			fmt.sbprintf(&want, "%d:%s:%v|", n.number, n.label, n.inline)
		}
		strings.write_string(&want, "#")
		for r in c.references {
			fmt.sbprintf(&want, "%s=%d.%d|", r.text, r.number, r.ordinal)
		}
		source := transmute([]u8)c.source
		found := footnotes(source, 0, context.temp_allocator)
		got := strings.builder_make(context.temp_allocator)
		// The definitions in the order of the source, with the inline
		// ones at the place of their text.
		for n in found.notes {
			fmt.sbprintf(&got, "%d:%s:%v|", n.number, n.label, n.inline)
		}
		strings.write_string(&got, "#")
		for r in found.references {
			fmt.sbprintf(&got, "%s=%d.%d|", string(source[r.start:r.end]), found.notes[r.note].number, r.ordinal)
		}
		testing.expectf(t, strings.to_string(got) == strings.to_string(want), "%q:\n %q, not\n %q", c.source, strings.to_string(got), strings.to_string(want))
	}
}

// The lines of a definition, and where its text starts.
@(test)
test_the_lines_of_a_footnote_definition :: proc(t: ^testing.T) {
	source := "Text[^a].\n\n[^a]: First.\n    Second.\n\n    Third.\n\nAfter[^b].\n[^b]:   B.\n"
	found := footnotes(transmute([]u8)source, 0, context.temp_allocator)
	if !testing.expect_value(t, len(found.notes), 2) {
		return
	}
	a, b := found.notes[0], found.notes[1]
	testing.expect_value(t, source[a.start:a.end], "[^a]: First.\n    Second.\n\n    Third.\n")
	testing.expect_value(t, source[a.content:a.content + 6], "First.")
	testing.expect_value(t, source[b.start:b.end], "[^b]:   B.\n")
	testing.expect_value(t, source[b.content:b.content + 2], "B.")
}

// What the document has for footnotes: a reference is the number of its
// footnote, one thing of the text; a definition is a block with that
// number as its mark, with the blocks of its other paragraphs after it,
// as the blocks of a list item.
@(test)
test_the_document_has_the_footnotes_as_numbers :: proc(t: ^testing.T) {
	show :: proc(doc: ^Document) -> string {
		out := strings.builder_make(context.temp_allocator)
		for i in 0 ..< doc.count {
			b := block_at(doc, i)
			#partial switch b.marker {
			case .Note:
				fmt.sbprintf(&out, "{{%d}}", b.number)
			case .Bullet:
				strings.write_string(&out, "*")
			case .None:
				strings.write_string(&out, b.spacing == .Continuation ? ">" : "")
			}
			for span in b.text.spans {
				piece := string(b.text.bytes[span.start:span.end])
				if .Note in span.style {
					fmt.sbprintf(&out, "<%s:%d>", piece, span.link)
				} else {
					strings.write_string(&out, piece)
				}
			}
			strings.write_string(&out, "|")
		}
		return strings.to_string(out)
	}
	Case :: struct {
		source, want: string,
	}
	cases := []Case {
		{"A note[^1].\n\n[^1]: The text.\n", "A note<1:1>.|{1}The text.|"},
		{"Named[^n] and second[^2].\n\n[^2]: Two.\n[^n]: Named.\n", "Named<1:1> and second<2:2>.|{2}Two.|{1}Named.|"},
		{"Twice[^a], again[^a].\n\n[^a]: A.\n", "Twice<1:1>, again<1:1>.|{1}A.|"},
		// More than one line, and more than one paragraph.
		{"T[^l].\n\n[^l]: First line.\n    Second line.\n\n    A second paragraph.\n\nAfter.\n", "T<1:1>.|{1}First line. Second line.|>A second paragraph.|After.|"},
		{"T[^l].\n\n[^l]: One.\n  Two spaces.\n", "T<1:1>.|{1}One. Two spaces.|"},
		// An inline footnote: its number.
		{"An inline one. ^[The text.] End.\n", "An inline one. <1:1> End.|"},
		// No definition: text. No reference: a definition with no number.
		{"None[^x].\n\n[^y]: Alone.\n", "None[^x].|{0}Alone.|"},
		// In code, and in bold text.
		{"`[^1]` and **bold[^1]**.\n\n[^1]: One.\n", "[^1] and bold<1:1>.|{1}One.|"},
		// In a code block that is indented: text, and no number is used.
		{"Code:\n\n    [^a] in code\n\nReal[^b].\n\n[^a]: A.\n[^b]: B.\n", "Code:|[^a] in code|Real<1:1>.|{0}A.|{1}B.|"},
		// An inline footnote with styles, an entity, and a "|" in it is
		// one number, with nothing of its source left in the text.
		{"A ^[a *bold* note] b ^[c &amp; d] e.\n", "A <1:1> b <2:2> e.|"},
		{"S ^[with `code` and **more**]!\n", "S <1:1>!|"},
		// A reference between the marks of a style, and after an "&".
		{"*[^1]* and &[^1];\n\n[^1]: One.\n", "<1:1> and &<1:1>;|{1}One.|"},
		// In code between backticks that goes over more than one line.
		{"`start\n[^a]\nend`\n\nReal[^b].\n\n[^a]: A.\n[^b]: B.\n", "start [^a] end|Real<1:1>.|{0}A.|{1}B.|"},
		// Two references next to each other are two numbers.
		{"T[^n][^n].\n\n[^n]: N.\n", "T<1:1><1:1>.|{1}N.|"},
		// A label with an entity or the mark of a style in it is no text.
		{"T[^a&amp;b] and[^c*d*].\n\n[^a&amp;b]: One.\n[^c*d*]: Two.\n", "T<1:1> and<2:2>.|{1}One.|{2}Two.|"},
		// After a backslash: text. After two: a reference.
		{"Literal \\[^a] and \\^[no]. Real[^b] and \\\\[^a].\n\n[^a]: A.\n[^b]: B.\n", "Literal [^a] and ^[no]. Real<1:1> and \\<2:2>.|{2}A.|{1}B.|"},
		// A definition in raw HTML, or after a tab (code), is none, and
		// the code is as it is in the source.
		{"T[^n].\n\n<div>\n[^n]: Hidden.\n</div>\n", "T[^n].|"},
		{"T[^n].\n\n\t[^n]: Code.\n", "T[^n].|[^n]: Code.|"},
		{"\t[^n]: Code.\n", "[^n]: Code.|"},
		// A fence line in raw HTML is no fence of code: the text after
		// it has its footnote.
		{"<div>\n~~~\n</div>\n\nT[^n].\n\n[^n]: Note.\n", "T<1:1>.|{1}Note.|"},
		// In a fenced code block: text, also a definition there, and the
		// text after the block has its footnotes.
		{"```\n[^a] and ^[x]\n[^a]: In code.\n```\n\nReal[^a].\n\n[^a]: A.\n", "[^a] and ^[x]\n[^a]: In code.|Real<1:1>.|{1}A.|"},
		// The last definition that is one has the references: a later
		// one in raw HTML is none.
		{"T[^n].\n\n[^n]: Visible.\n\n<div>\n[^n]: Hidden.\n</div>\n", "T<1:1>.|{1}Visible.|"},
		// A bracket after a backslash is no end of an inline footnote.
		{"A ^[a \\] b] c.\n", "A <1:1> c.|"},
		// In raw HTML: no reference.
		{"A <a href=\"[^1]\">link</a> and[^1].\n\n[^1]: One.\n", "A link and<1:1>.|{1}One.|"},
		// A definition right after a paragraph, and a list after it.
		{"Text[^1].\n[^1]: One.\n\n- item\n", "Text<1:1>.|{1}One.|*item|"},
		// Styles in the text of a definition.
		{"T[^1].\n\n[^1]: With **bold** text.\n", "T<1:1>.|{1}With bold text.|"},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		got := show(&doc)
		testing.expectf(t, got == c.want, "%q:\n %q, not\n %q", c.source, got, c.want)
	}
}

// A change in a block with a footnote, or of a footnote, gives the
// document that a parse of all of the new source gives.
@(test)
test_an_edit_at_a_footnote_is_a_parse_of_all :: proc(t: ^testing.T) {
	source := "First[^a] text.\n\nSecond[^b] text.\n\nPlain text.\n\n[^a]: A.\n[^b]: B.\n"
	edits := []Edit {
		{5, 9, ""}, // the first reference goes: the second footnote is number 1
		{0, 0, "New[^b] "}, // a reference before the others
		{43, 43, " more"}, // in a block with no footnote
		{len(source), len(source), "[^c]: C.\n"}, // a definition more
		{50, 51, "c"}, // the label of a definition
	}
	for edit in edits {
		doc := parse(source)
		defer destroy(&doc)
		pending := prepare(&doc, edit)
		commit(&doc, &pending)
		fresh := parse(string(doc.source))
		defer destroy(&fresh)
		if !testing.expect_value(t, doc.count, fresh.count) {
			continue
		}
		for i in 0 ..< doc.count {
			a, b := block_at(&doc, i), block_at(&fresh, i)
			testing.expectf(t, layout_equal(a, b) && a.number == b.number, "edit %v: block %d is %q, not %q", edit, i, string(a.text.bytes[:]), string(b.text.bytes[:]))
		}
	}
}

// With the caret in a reference, it shows as it is in the source, in the
// style of a mark; each other reference stays a number.
@(test)
test_a_reference_at_the_caret_shows_its_source :: proc(t: ^testing.T) {
	source := "One[^a] and two[^b].\n\n[^a]: A.\n[^b]: B.\n"
	for offset in ([]int{3, 5, 7}) {
		doc := parse_owned(slice.clone(transmute([]u8)source), offset)
		defer destroy(&doc)
		text := &block_at(&doc, 0).text
		testing.expect_value(t, string(text.bytes[:]), "One[^a] and two2.")
		testing.expect(t, .Mark in span_at(text, 4).style)
		testing.expect(t, .Note in span_at(text, 15).style)
		testing.expect(t, doc.reveal != nil)
	}
	// Beside it: the number.
	doc := parse_owned(slice.clone(transmute([]u8)source), 1)
	defer destroy(&doc)
	testing.expect_value(t, string(block_at(&doc, 0).text.bytes[:]), "One1 and two2.")
	// The map of the block has a pair for each reference, so a caret
	// that comes to one asks for its source.
	pairs: [dynamic]Pair
	defer delete(pairs)
	places := block_map(&doc, 0, &pairs)
	defer delete(places)
	testing.expect_value(t, len(pairs), 2)
	testing.expect_value(t, [2]int{pairs[0].from, pairs[0].to}, [2]int{3, 7})
	testing.expect_value(t, [2]int{pairs[1].from, pairs[1].to}, [2]int{15, 19})
}

// A block that gets the marks at the caret, and loses them, keeps the
// numbers of its footnotes: they are no links of the document.
@(test)
test_a_block_keeps_its_footnote_numbers_through_a_reveal :: proc(t: ^testing.T) {
	for source in ([]string{"One[^a] and two[^b].\n\n[^a]: A.\n[^b]: B.\n", "One[^a], [a link](https://a.com), two[^b].\n\n[^a]: A.\n[^b]: B.\n"}) {
		doc := parse(source)
		defer destroy(&doc)
		for reveal in ([]Maybe(int){5, nil, 1, nil}) {
			places, _ := reveal_block(&doc, 0, reveal)
			delete(places)
		}
		numbers := make([dynamic]int, context.temp_allocator)
		for span in block_at(&doc, 0).text.spans {
			if .Note in span.style {
				append(&numbers, span.link)
			}
		}
		testing.expect_value(t, len(numbers), 2)
		if len(numbers) == 2 {
			testing.expect_value(t, [2]int{numbers[0], numbers[1]}, [2]int{1, 2})
		}
		first, has_first := note_block(&doc, 1, 1)
		second, has_second := note_block(&doc, 2, 1)
		testing.expect(t, has_first && has_second && first == 0 && second == 0)
		testing.expect_value(t, links_in(block_at(&doc, 0)), len(doc.links))
	}
}

// The text of a footnote, plain: of all of the blocks of its definition,
// or of an inline footnote.
@(test)
test_the_text_of_a_footnote :: proc(t: ^testing.T) {
	doc := parse("A[^l], inline ^[The *inline* text.], B[^s].\n\n[^l]: First **bold** line.\n    Second line.\n\n    A second paragraph.\n[^s]: Short.\n\nAfter.\n")
	defer destroy(&doc)
	Case :: struct {
		number: int,
		want:   string,
		ok:     bool,
	}
	for c in ([]Case{{1, "First bold line. Second line.\n\nA second paragraph.", true}, {2, "The *inline* text.", true}, {3, "Short.", true}, {4, "", false}}) {
		out := make([dynamic]u8, context.temp_allocator)
		ok := note_text(&doc, c.number, &out)
		testing.expect_value(t, ok, c.ok)
		testing.expect_value(t, string(out[:]), c.want)
	}
}

// The footnotes as the Markdown of a numbered list, in the order of
// their numbers, each with the mark that goes back.
@(test)
test_the_list_of_the_footnotes :: proc(t: ^testing.T) {
	back := " [" + NOTE_BACK + "](#back)"
	doc := parse("B[^b], inline ^[In the text.], A[^a].\n\n[^a]: Text of a.\n[^b]: First line.\n  Second line.\n\n    A second paragraph.\n[^c]: No reference.\n\nAfter.\n")
	defer destroy(&doc)
	want := strings.concatenate({"1. First line.\n   Second line.", back, "\n\n     A second paragraph.\n\n2. In the text.", back, "\n\n3. Text of a.", back, "\n\n"}, context.temp_allocator)
	testing.expect_value(t, notes_source(&doc, context.temp_allocator), want)
	// The blocks of a definition, and no other block.
	testing.expect(t, !in_note(&doc, 0))
	for block in 1 ..= 4 {
		testing.expect(t, in_note(&doc, block))
	}
	testing.expect(t, !in_note(&doc, 5))
	none := parse("No footnotes.\n")
	defer destroy(&none)
	testing.expect_value(t, notes_source(&none, context.temp_allocator), "")
}

// The blocks of a definition are all of its item: a list in its text,
// and the text after that list. The block after the definition is none
// of them.
@(test)
test_a_list_in_a_definition_is_of_the_footnote :: proc(t: ^testing.T) {
	doc := parse("T[^n][^n].\n\n[^n]: Intro.\n\n    - Child.\n\n    Tail.\n\nAfter.\n")
	defer destroy(&doc)
	if !testing.expect_value(t, doc.count, 5) {
		return
	}
	for want, block in ([]bool{false, true, true, true, false}) {
		testing.expect_value(t, in_note(&doc, block), want)
	}
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, note_text(&doc, 1, &out))
	testing.expect_value(t, string(out[:]), "Intro.\n\nChild.\n\nTail.")
	// Each of the two references next to each other is found.
	_, first := note_block(&doc, 1, 1)
	_, second := note_block(&doc, 1, 2)
	_, third := note_block(&doc, 1, 3)
	testing.expect(t, first && second && !third)
}

// The list of the footnotes for texts that are not one paragraph: the
// mark that goes back is in no line of code, a line with no indent after
// a paragraph of a definition is of that paragraph, and the definitions
// of links come with the texts that use them.
@(test)
test_the_list_of_footnotes_with_other_blocks :: proc(t: ^testing.T) {
	BACK :: "[" + NOTE_BACK + "](" + NOTE_BACK_TARGET + ")"
	Case :: struct {
		source, want: string,
	}
	cases := []Case {
		{"T[^n].\n\n[^n]: ```swift\n  let x = 1\n  ```\n", "1. ```swift\n   let x = 1\n   ```\n\n   " + BACK + "\n\n"},
		{"T[^n].\n\n[^n]: Text\n    ```\n    code\n    ```\n", "1. Text " + BACK + "\n     ```\n     code\n     ```\n\n"},
		// A fence that nothing closes: closed before the mark.
		{"T[^n].\n\n[^n]: ```\n  x\n", "1. ```\n   x\n   ```\n\n   " + BACK + "\n\n"},
		// The indent of the text stays: six spaces are code in its place
		// (four more than the text of the item), and in the list too.
		{"T[^n].\n\n[^n]: Intro.\n\n      *literal*\n", "1. Intro. " + BACK + "\n\n       *literal*\n\n"},
		{"T[^n].\n\n[^n]: Note.\nAfter.\n\nBody.\n", "1. Note.\n   After. " + BACK + "\n\n"},
		{"T[^n].\n\n[^n]: Read [guide][g].\n\n[g]: https://example.com\n", "1. Read [guide][g]. " + BACK + "\n\n[g]: https://example.com\n"},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		got := notes_source(&doc, context.temp_allocator)
		testing.expectf(t, got == c.want, "%q:\n %q, not\n %q", c.source, got, c.want)
		// The list is Markdown with as many footnotes, and the mark that
		// goes back is a link of it.
		list := parse(got)
		defer destroy(&list)
		testing.expect(t, list.count > 0 && block_at(&list, 0).marker == .Number)
		has_back := false
		for link in list.links {
			has_back ||= link == NOTE_BACK_TARGET
		}
		testing.expectf(t, has_back, "%q: no link back in %q", c.source, got)
	}
	// The line with no indent is in no other place of a page that is read.
	doc := parse("T[^n].\n\n[^n]: Note.\nAfter.\n\nBody.\n")
	defer destroy(&doc)
	testing.expect_value(t, doc.count, 3)
	testing.expect_value(t, string(block_at(&doc, 1).text.bytes[:]), "Note. After.")
}

// A reference with the caret in it shows as its source and is still
// the reference that it was: the block of each reference is found.
@(test)
test_the_block_of_a_reference_with_the_caret_in_it :: proc(t: ^testing.T) {
	source := "One[^a].\n\nTwo[^a].\n\n[^a]: A.\n"
	doc := parse_owned(slice.clone(transmute([]u8)source), 5)
	defer destroy(&doc)
	testing.expect_value(t, string(block_at(&doc, 0).text.bytes[:]), "One[^a].")
	first, has_first := note_block(&doc, 1, 1)
	second, has_second := note_block(&doc, 1, 2)
	_, has_third := note_block(&doc, 1, 3)
	testing.expect(t, has_first && has_second && !has_third)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, second, 1)
}

// A line of many "[^" or "^[" with no "]" is read one time: the scan of
// a long one is done at once.
@(test)
test_a_line_of_marks_with_no_end_is_read_one_time :: proc(t: ^testing.T) {
	for opener in ([]string{"[^", "^[", "^[[", "[^a "}) {
		source := strings.repeat(opener, 200_000, context.temp_allocator)
		found := footnotes(transmute([]u8)source, 0, context.temp_allocator)
		testing.expect_value(t, len(found.references), 0)
	}
	// Brackets in an inline footnote are of its text.
	found := footnotes(transmute([]u8)string("A ^[one [two] three] b ^[x].\n"), 0, context.temp_allocator)
	testing.expect_value(t, len(found.references), 2)
	if len(found.references) == 2 {
		testing.expect_value(t, found.references[0].end - found.references[0].start, 18)
	}
}

// The document keeps the footnotes of a parse of all of its source, and
// reads them again after a change of a piece, which moves their offsets.
@(test)
test_the_footnotes_of_a_document_after_a_change_of_a_piece :: proc(t: ^testing.T) {
	// The change is some blocks before the first footnote, and not in
	// the first block: the piece of a change has blocks after it too
	// (`GUARD_BLOCKS`), and a change in the first block is a parse of all.
	doc := parse("Plain text.\n\nP2.\n\nP3.\n\nP4.\n\nP5.\n\nP6.\n\nOne[^a].\n\nTwo[^a].\n\n[^a]: A.\n")
	defer destroy(&doc)
	testing.expect(t, doc.notes_valid)
	testing.expect_value(t, len(doc.notes.references), 2)
	pending := prepare(&doc, Edit{19, 19, " more"})
	testing.expect(t, !pending.all)
	commit(&doc, &pending)
	testing.expect(t, !doc.notes_valid)
	first, has_first := note_block(&doc, 1, 1)
	second, has_second := note_block(&doc, 1, 2)
	testing.expect(t, has_first && has_second)
	testing.expect_value(t, first, 6)
	testing.expect_value(t, second, 7)
	// A change with a footnote in it is a parse of all: kept again.
	pending = prepare(&doc, Edit{0, 0, "New[^a] "})
	commit(&doc, &pending)
	testing.expect(t, doc.notes_valid)
	testing.expect_value(t, len(doc.notes.references), 3)
}
