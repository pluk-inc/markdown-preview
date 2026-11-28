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
			// The number that the reference shows, which is the one of
			// its footnote.
			fmt.sbprintf(&got, "%s=%d.%d|", string(source[r.start:r.end]), r.number, r.ordinal)
			testing.expect_value(t, r.number, found.notes[r.note].number)
		}
		testing.expectf(t, strings.to_string(got) == strings.to_string(want), "%q:\n %q, not\n %q", c.source, strings.to_string(got), strings.to_string(want))
	}
}

// The lines of a definition, and where its text starts.
@(test)
test_the_lines_of_a_footnote_definition :: proc(t: ^testing.T) {
	source := "Text[^a].\n\n[^a]: First.\n    Second.\n\n    Third.\n\nAfter[^b].\n[^b]:   B.\n"
	// The lines are of the scan; what a document keeps has no end of a
	// definition (the blocks have it).
	scan := footnote_scan(transmute([]u8)source, 0, len(source), nil, 0, {0, len(source)})
	if !testing.expect_value(t, len(scan.possible), 2) {
		return
	}
	a, b := scan.possible[0], scan.possible[1]
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
		// One that starts or ends in code between backticks is none, and
		// the one after it has the first number.
		{"Code `^[literal` tail].\n", "Code ^[literal tail].|"},
		{"Use `^[` literally]. Next ^[real].\n", "Use ^[ literally]. Next <1:1>.|"},
		// Code in the text of an inline footnote is of the footnote.
		{"A ^[with `code` in it] b.\n", "A <1:1> b.|"},
		// A "[^" with no definition is text, and what is after it is read.
		{"Typo [^missing; real ^[works].\n\n[^a]: A.\n", "Typo [^missing; real <1:1>.|{0}A.|"},
		// A label of only spaces is none (the line is the definition of
		// a link for the parser, which shows nothing).
		{"T[^ ].\n\n[^ ]: Body.\n", "T[^ ].|"},
		// A definition that is indented: a line goes on in it when it is
		// as far in as the text of the definition.
		{"T[^n].\n\n   [^n]: Intro.\n\n  Tail.\n", "T<1:1>.|{1}Intro.|Tail.|"},
		{"T[^n].\n\n   [^n]: Intro.\n\n     Tail.\n", "T<1:1>.|{1}Intro.|>Tail.|"},
		// A reference with ":" after it in a quote is no definition of a
		// link for the parser: the inline footnote with a backtick
		// before a reference is a footnote, with or without it.
		{"^[`][^b]\n\ni\n>[^b]:d\n[^b]:", "<1:1><2:2>|i|<2:2>:d|{2}|"},
		// In the target of a link: none, and the link is a link.
		{"A [guide](/docs/^[draft]) and ^[real].\n", "A guide and <1:1>.|"},
		{"A [guide](/docs/(v1)/^[draft]) and ^[real].\n", "A guide and <1:1>.|"},
		// In an address that is a link as it is: none.
		{"See <https://example.com/^[draft]> and ^[real].\n", "See https://example.com/^[draft] and <1:1>.|"},
		// In the text of a link: one.
		{"A [see ^[note] here](/docs) b.\n", "A see <1:1> here b.|"},
		// A line with no indent that goes on in the paragraph of a
		// definition is text of the definition: no footnote in it.
		{"T[^a].\n\n[^a]: Intro.\nTail ^[inner].\n\nAfter ^[real].\n", "T<1:1>.|{1}Intro. Tail ^[inner].|After <2:2>.|"},
		// A line that has the form of a definition in raw HTML is as it is
		// in the source, so the HTML ends where it ends.
		{"<script>\n[^</script>]: Hidden.\nAfter.\n", "After.|"},
		{"<!--\n[^-->]: Hidden.\n\nAfter.\n", "After.|"},
		{"<!--\n^[-->]\n\nAfter.\n", "After.|"},
		// A label with a backtick in it: its reference is a footnote,
		// also in the line before its definition.
		{"Text[^x`y].\n[^x`y]: Note.\n", "Text<1:1>.|{1}Note.|"},
		{"Text[^x`y>].\n[^x`y>]: Note.\n", "Text<1:1>.|{1}Note.|"},
		// A label with a ">" in it, in no raw HTML, is a label.
		{"Text[^a>b].\n\n[^a>b]: Note.\n", "Text<1:1>.|{1}Note.|"},
		// A label with a "[" in it is no label: the line is text.
		{"T.\n\n[^a[b]: Keep this text.\n", "T.|[^a[b]: Keep this text.|"},
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
		discard(&pending)
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
	if !testing.expect_value(t, len(pairs), 2) {
		return
	}
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

// The blocks of a definition, and no other block.
@(test)
test_the_blocks_of_a_definition :: proc(t: ^testing.T) {
	doc := parse("B[^b], inline ^[In the text.], A[^a].\n\n[^a]: Text of a.\n[^b]: First line.\n  Second line.\n\n    A second paragraph.\n[^c]: No reference.\n\nAfter.\n")
	defer destroy(&doc)
	testing.expect(t, !in_note(&doc, 0))
	for block in 1 ..= 4 {
		testing.expect(t, in_note(&doc, block))
	}
	testing.expect(t, !in_note(&doc, 5))
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
	closed := strings.concatenate({strings.repeat("[^", 200_000, context.temp_allocator), "]"}, context.temp_allocator)
	testing.expect_value(t, len(footnotes(transmute([]u8)closed, 0, context.temp_allocator).references), 0)
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
// a change of a piece moves their offsets.
@(test)
test_the_footnotes_of_a_document_after_a_change_of_a_piece :: proc(t: ^testing.T) {
	// The change is some blocks before the first footnote, and not in
	// the first block: the piece of a change has blocks after it too
	// (`GUARD_BLOCKS`), and a change in the first block is a parse of all.
	doc := parse("Plain text.\n\nP2.\n\nP3.\n\nP4.\n\nP5.\n\nP6.\n\nOne[^a].\n\nTwo[^a].\n\n[^a]: A.\n")
	defer destroy(&doc)
	testing.expect_value(t, len(doc.notes.references), 2)
	pending := prepare(&doc, Edit{19, 19, " more"})
	testing.expect(t, !pending.all)
	commit(&doc, &pending)
	discard(&pending)
	// A parse of the piece: the footnotes are kept, five bytes later.
	testing.expect_value(t, doc.notes.references[0].start, strings.index(string(doc.source), "[^a]"))
	first, has_first := note_block(&doc, 1, 1)
	second, has_second := note_block(&doc, 1, 2)
	testing.expect(t, has_first && has_second)
	testing.expect_value(t, first, 6)
	testing.expect_value(t, second, 7)
	// A change with a footnote in it is a parse of all: kept again.
	pending = prepare(&doc, Edit{0, 0, "New[^a] "})
	commit(&doc, &pending)
	discard(&pending)
	testing.expect_value(t, len(doc.notes.references), 3)
}

// A change in a piece with footnotes is a parse of the piece when the
// piece has the footnotes that it had, and a parse of all when it has
// others. In each case the document is the one that a parse of all of
// the new source gives, with the same footnotes at the same offsets.
@(test)
test_a_change_in_a_piece_with_footnotes :: proc(t: ^testing.T) {
	source := "Intro.\n\nP2.\n\nP3.\n\nFirst[^a] text and ^[an inline one] more.\n\nSecond[^b] text, again[^a].\n\nPlain text.\n\nP7.\n\nP8.\n\n[^a]: The text of A.\n    More of A.\n[^b]: B.\n\nEnd.\n"
	same :: proc(t: ^testing.T, doc: ^Document, what: string) {
		fresh := parse(string(doc.source))
		defer destroy(&fresh)
		if !testing.expectf(t, doc.count == fresh.count, "%s: %d blocks, not %d", what, doc.count, fresh.count) {
			return
		}
		for i in 0 ..< doc.count {
			a, b := block_at(doc, i), block_at(&fresh, i)
			testing.expectf(t, layout_equal(a, b) && a.number == b.number, "%s: block %d is %q, not %q", what, i, string(a.text.bytes[:]), string(b.text.bytes[:]))
		}
		got, want := doc.notes, fresh.notes
		if !testing.expectf(t, len(got.notes) == len(want.notes) && len(got.references) == len(want.references), "%s: %d notes and %d references, not %d and %d", what, len(got.notes), len(got.references), len(want.notes), len(want.references)) {
			return
		}
		for note, n in want.notes {
			have := got.notes[n]
			testing.expectf(t, have == note, "%s: note %d is %v, not %v", what, n, have, note)
		}
		testing.expectf(t, got.bullet_lines == want.bullet_lines && got.bullet_free == want.bullet_free, "%s: lines of list marks %v, not %v", what, got.bullet_lines, want.bullet_lines)
		testing.expectf(t, slice.equal(got.dead, want.dead) && got.bullet == want.bullet, "%s: lines that are no definition at %v with %c, not %v with %c", what, got.dead, got.bullet, want.dead, want.bullet)
		for reference, r in want.references {
			testing.expectf(t, got.references[r] == reference, "%s: reference %d is %v, not %v", what, r, got.references[r], reference)
		}
	}
	Case :: struct {
		find, text: string, // the text goes in before `find`
		remove:     int, // bytes that go out from there
		alone:      bool, // a parse of the piece
	}
	cases := []Case {
		{" text and", "X", 0, true}, // a letter in a paragraph with two footnotes
		{"an inline", "Y", 0, true}, // in the text of an inline footnote
		{"again[^a]", "", 1, true}, // a letter goes out before a reference
		{"The text of A", "Z", 0, true}, // in the text of a definition
		{"More of A", "W", 0, true}, // in a later line of it
		{"Plain text", "Q", 0, true}, // near the footnotes, in none
		{"[^a] text", "", 4, false}, // a reference goes out: other numbers
		{"First[^a]", "New[^b] ", 0, false}, // a reference before the others
		{"a]: The", "", 1, false}, // the label of a definition
		{"^[an inline", "", 1, false}, // an inline footnote is none any more
		{"P7.", "[^c]: C.\n\n", 0, false}, // a definition more
		{"Second[^b]", "\\", 6, false}, // a backslash before a reference
	}
	for c in cases {
		doc := parse(source)
		defer destroy(&doc)
		at := strings.index(source, c.find)
		if !testing.expectf(t, at >= 0, "no %q in the source", c.find) {
			continue
		}
		pending := prepare(&doc, Edit{at, at + c.remove, c.text})
		testing.expectf(t, pending.all != c.alone, "%q before %q: a parse of all is %v", c.text, c.find, pending.all)
		commit(&doc, &pending)
	discard(&pending)
		discard(&pending)
		same(t, &doc, c.find)
		// And a second change after it, at the offsets that the first
		// one left.
		again := strings.index(string(doc.source), "End.")
		pending = prepare(&doc, Edit{again, again, "The "})
		commit(&doc, &pending)
	discard(&pending)
		discard(&pending)
		same(t, &doc, "after it")
		first := strings.index(string(doc.source), "Intro")
		pending = prepare(&doc, Edit{first + 15, first + 15, "!"})
		commit(&doc, &pending)
	discard(&pending)
		discard(&pending)
		same(t, &doc, "and before it")
	}
	// Many changes, one after the other, of one byte in or out at a
	// place that a seed gives.
	doc := parse(source)
	defer destroy(&doc)
	state := u64(12345)
	alone := 0
	for step in 0 ..< 300 {
		state = state * 6364136223846793005 + 1442695040888963407
		at := int(state >> 33) % (len(doc.source) + 1)
		edit := Edit{at, at, "x"}
		if step % 3 == 0 && at < len(doc.source) && doc.source[at] < 0x80 && (at + 1 == len(doc.source) || doc.source[at + 1] < 0x80) {
			edit = Edit{at, at + 1, ""}
		}
		pending := prepare(&doc, edit)
		alone += int(!pending.all)
		commit(&doc, &pending)
	discard(&pending)
		discard(&pending)
		same(t, &doc, fmt.tprintf("step %d at %d", step, at))
	}
	testing.expect(t, alone > 100)
	// The same with text that is hard for the scan: marks of footnotes,
	// backticks, fences, quotes, raw HTML, and line breaks go in at
	// places that a seed gives, in sources with a label that is in a
	// code block, front matter, and line breaks of two bytes. (A
	// reviewer found faults with this that the cases above did not.)
	sources := []string {
		"Intro.\n\nP2 [^a] and ^[x [y] z] t.\n\nP3 [^b] `c [^a]` [^B].\n\n- item [^a]\n- item2\n\n> quote [^b]\n\nPlain.\n\n[^a]: A [^b] text\n  more\n\n  second para\n[^b]: B\n\n[^a]: dup\n\nEnd.\n",
		"Intro.\n\n[^x`y] `q [^a] q\n\nMid ^[i].\n\n[^a]: A\n\n~~~\n[^x`y]: dead\n~~~\n\nEnd.\n",
		"---\nt: 1\n---\nA [^1] b [^2].\n\n[^1]: one\n\n\tcode?\n\n[^2]: two\nlazy\n\nEnd [^1].\n",
		"Intro.\r\n\r\nP [^a] q.\r\n\r\n[^a]: A\r\n  more\r\n\r\nEnd [^a].\r\n",
	}
	alphabet := []string{"[", "]", "^", ":", " ", "`", "\n", "\t", "a", "b", "x", "~", ">", "-", "+", "(", ")", "  ", "\n\n", "[^a]", "^[", "[^b]: ", "<div>", "```"}
	for hard, which in sources {
		doc := parse(hard)
		defer destroy(&doc)
		state := u64(777 + which)
		for step in 0 ..< 700 {
			state = state * 6364136223846793005 + 1442695040888963407
			at := int(state >> 33) % (len(doc.source) + 1)
			state = state * 6364136223846793005 + 1442695040888963407
			pick := int(state >> 33) % (len(alphabet) + 3)
			edit := Edit{at, at, ""}
			if pick >= len(alphabet) {
				edit.end = at + min(pick - len(alphabet) + 1, len(doc.source) - at)
			} else {
				edit.text = alphabet[pick]
			}
			pending := prepare(&doc, edit)
			commit(&doc, &pending)
			discard(&pending)
			same(t, &doc, fmt.tprintf("source %d, step %d at %d", which, step, at))
		}
	}
}

// A label with a backtick in it that is also the label of a line in a
// code block (no definition): the pass that says what is a footnote and
// the parse get the same bytes, so they pair the backticks the same
// way, and a change of the piece is a parse of all.
@(test)
test_a_label_of_a_line_that_is_no_definition :: proc(t: ^testing.T) {
	Case :: struct {
		source, find, text: string,
		remove:             int,
	}
	cases := []Case {
		{"Intro.\n\n[^x`y] `q [^a] q\n\nMid.\n\n[^a]: A\n\n~~~\n[^x`y]: dead\n~~~\n\nEnd.\n", " q\n\nMid", " q`", 2},
		{"Intro.\n\n[^x`y] `q [^a] q` [^a] `\n\nMid.\n\n[^a]: A\n\n~~~\n[^x`y]: dead\n~~~\n\nEnd.\n", "Mid", "X", 0},
		{"Intro.\n\nP2.\n\nText [^a] here.\n\n[^a]: A\n\n  second\n\nEnd.\n", "P2", "X", 0},
	}
	for c in cases {
		doc := parse(c.source)
		defer destroy(&doc)
		at := strings.index(c.source, c.find)
		pending := prepare(&doc, Edit{at, at + c.remove, c.text})
		commit(&doc, &pending)
		discard(&pending)
		fresh := parse(string(doc.source))
		defer destroy(&fresh)
		if !testing.expect_value(t, doc.count, fresh.count) {
			continue
		}
		for i in 0 ..< doc.count {
			a, b := block_at(&doc, i), block_at(&fresh, i)
			testing.expectf(t, layout_equal(a, b) && a.number == b.number, "%q: block %d is %q, not %q", c.source, i, string(a.text.bytes[:]), string(b.text.bytes[:]))
		}
		testing.expect_value(t, len(doc.notes.references), len(fresh.notes.references))
		for reference, r in fresh.notes.references {
			if r < len(doc.notes.references) {
				testing.expect_value(t, doc.notes.references[r], reference)
			}
		}
		// The block with the caret in each place of it is the block of a
		// parse of all with the caret there.
		for offset in 8 ..< 30 {
			block := block_at_offset(&doc, offset)
			places, _ := reveal_block(&doc, block, offset)
			delete(places)
			all := parse_owned(slice.clone(doc.source), offset)
			testing.expectf(t, layout_equal(block_at(&doc, block), block_at(&all, block)), "%q, the caret at %d: %q, not %q", c.source, offset, string(block_at(&doc, block).text.bytes[:]), string(block_at(&all, block).text.bytes[:]))
			destroy(&all)
			places, _ = reveal_block(&doc, block, nil)
			delete(places)
		}
	}
}

// A definition is no item of a list of the source that has "+" as its
// mark, before it or after it.
@(test)
test_a_definition_is_no_item_of_a_list_of_the_source :: proc(t: ^testing.T) {
	doc := parse("Text [^a].\n\n+ one\n+ two\n\n[^a]: A\n\n+ next\n+ more\n")
	defer destroy(&doc)
	if !testing.expect_value(t, doc.count, 6) {
		return
	}
	testing.expect_value(t, block_at(&doc, 1).spacing, Spacing.List_Start)
	testing.expect_value(t, block_at(&doc, 3).marker, Marker.Note)
	testing.expect_value(t, block_at(&doc, 3).spacing, Spacing.List_Start)
	testing.expect_value(t, block_at(&doc, 4).spacing, Spacing.List_Start)
	testing.expect_value(t, block_at(&doc, 4).marker, Marker.Bullet)
	testing.expect(t, !block_at(&doc, 4).noted && !block_at(&doc, 2).noted)
}

// A definition in an item of a list of the source: its blocks are of
// the footnote, and the items of that list are not.
@(test)
test_a_definition_in_an_item_of_a_list :: proc(t: ^testing.T) {
	doc := parse("T[^n].\n\n- Parent.\n\n  [^n]: Child note.\n\n      More of it.\n\n  Parent again.\n\n- Next.\n\nAfter.\n")
	defer destroy(&doc)
	want := []bool{false, false, true, true, false, false, false}
	if !testing.expect_value(t, doc.count, len(want)) {
		return
	}
	for noted, block in want {
		testing.expectf(t, in_note(&doc, block) == noted, "block %d (%q): of a footnote is %v", block, string(block_at(&doc, block).text.bytes[:]), !noted)
	}
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, note_text(&doc, 1, &out))
	testing.expect_value(t, string(out[:]), "Child note.\n\nMore of it.")
}

// The mark of the list that the definitions are for the parser is one
// that no line of the source starts with. A change of the lists that
// makes another mark the free one gives the document of a parse of all.
@(test)
test_the_list_mark_of_definitions_after_a_change_of_the_lists :: proc(t: ^testing.T) {
	source := "+ plus\n\nP.\n\n- minus\n\nP.\n\n* star\n\nP.\n\nP.\n\nP.\n\nText[^a].\n\n+ one\n\n[^a]: A\n\n+ next\n"
	doc := parse(source)
	defer destroy(&doc)
	// A list mark in a line of a definition counts in a parse and in a
	// change in the same way.
	{
		inside := "+ plus\n\nP.\n\n- minus\n\nP.\n\n* star\n\nP.\n\nP.\n\nP.\n\nText[^a].\n\n[^a]: A\n\n    - child\n"
		noted := parse(inside)
		defer destroy(&noted)
		at := strings.index(inside, "- minus")
		pending := prepare(&noted, Edit{at, at + 2, ""})
		commit(&noted, &pending)
		discard(&pending)
		fresh := parse(string(noted.source))
		defer destroy(&fresh)
		testing.expect_value(t, noted.notes.bullet, fresh.notes.bullet)
		testing.expect_value(t, noted.notes.bullet_lines, fresh.notes.bullet_lines)
	}
	testing.expect_value(t, doc.notes.bullet, u8('+'))
	testing.expect(t, !doc.notes.bullet_free)
	// The only "-" list goes: "-" is free, and the definition is no item
	// of the "+" lists around it any more.
	at := strings.index(source, "- minus")
	pending := prepare(&doc, Edit{at, at + 2, ""})
	testing.expect(t, pending.all)
	commit(&doc, &pending)
	discard(&pending)
	fresh := parse(string(doc.source))
	defer destroy(&fresh)
	testing.expect_value(t, doc.notes.bullet, fresh.notes.bullet)
	testing.expect_value(t, doc.notes.bullet, u8('-'))
	if testing.expect_value(t, doc.count, fresh.count) {
		for i in 0 ..< doc.count {
			testing.expectf(t, layout_equal(block_at(&doc, i), block_at(&fresh, i)), "block %d", i)
		}
	}
	// A change that keeps the mark is a parse of the piece.
	at = strings.index(string(doc.source), "star") + len("star\n\nP")
	pending = prepare(&doc, Edit{at, at, "x"})
	testing.expect(t, !pending.all)
	commit(&doc, &pending)
	discard(&pending)
	again := parse(string(doc.source))
	defer destroy(&again)
	testing.expect_value(t, doc.notes.bullet_lines, again.notes.bullet_lines)
}
