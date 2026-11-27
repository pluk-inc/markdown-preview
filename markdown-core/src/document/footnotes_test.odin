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
	want := strings.concatenate({"1. First line.\n   Second line.", back, "\n\n   A second paragraph.\n\n2. In the text.", back, "\n\n3. Text of a.", back, "\n\n"}, context.temp_allocator)
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
