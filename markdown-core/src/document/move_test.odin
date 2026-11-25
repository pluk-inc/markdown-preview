package document

import "core:testing"

@(test)
test_a_step_is_one_character_as_a_reader_sees_it :: proc(t: ^testing.T) {
	// "e" with an accent that is a mark of its own, a family of four
	// people, a flag, and a line break.
	text := transmute([]u8)string("aéb\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466\U0001F1EB\U0001F1F7\nz")
	stops := []int{0, 1, 4, 5, 30, 38, 39, 40}
	for stop, i in stops[:len(stops) - 1] {
		testing.expect_value(t, char_step(text, stop, true), stops[i + 1])
		testing.expect_value(t, char_step(text, stops[i + 1], false), stop)
	}
	testing.expect_value(t, char_step(text, 40, true), 40)
	testing.expect_value(t, char_step(text, 0, false), 0)
	// From inside a character: to its end, and to its start.
	testing.expect_value(t, char_step(text, 2, true), 4)
	testing.expect_value(t, char_step(text, 2, false), 1)
}

@(test)
test_a_step_of_a_word_stops_at_its_end_and_at_its_start :: proc(t: ^testing.T) {
	text := transmute([]u8)string("one, two_2  café!\nnext")
	//                             0123456789012345  67 89
	forward := []int{0, 3, 10, 17, 23}
	for stop, i in forward[:len(forward) - 1] {
		testing.expect_value(t, word_step(text, stop, true), forward[i + 1])
	}
	testing.expect_value(t, word_step(text, 23, true), 23)
	back := []int{23, 19, 12, 5, 0}
	for stop, i in back[:len(back) - 1] {
		testing.expect_value(t, word_step(text, stop, false), back[i + 1])
	}
	testing.expect_value(t, word_step(text, 0, false), 0)
}

@(test)
test_a_step_at_the_end_of_a_text_goes_to_the_text_beside_it :: proc(t: ^testing.T) {
	// A paragraph, a rule (no text), a table of two columns, a paragraph.
	doc := parse("ab\n\n---\n\n| c | d |\n| - | - |\n| e |  |\n\nz\n")
	defer destroy(&doc)
	path := []Address{{0, 0, 0}, {0, 0, 1}, {0, 0, 2}, {2, 0, 0}, {2, 0, 1}, {2, 1, 0}, {2, 1, 1}, {2, 2, 0}, {2, 2, 1}, {2, 3, 0}, {3, 0, 0}, {3, 0, 1}}
	for at, i in path[:len(path) - 1] {
		next, ok := step(&doc, at, .Character, true)
		testing.expect(t, ok)
		testing.expect_value(t, next, path[i + 1])
		back, back_ok := step(&doc, path[i + 1], .Character, false)
		testing.expect(t, back_ok)
		testing.expect_value(t, back, at)
	}
	// The step of a word from the end of a text is to the end of the
	// first word of the next text, and back to the start of the last
	// word of the text before: of a cell with no text, its start.
	word, found := step(&doc, {0, 0, 2}, .Word, true)
	testing.expect(t, found)
	testing.expect_value(t, word, Address{2, 0, 1})
	word, found = step(&doc, {3, 0, 0}, .Word, false)
	testing.expect(t, found)
	testing.expect_value(t, word, Address{2, 3, 0})
	word, found = step(&doc, {2, 0, 0}, .Word, false)
	testing.expect(t, found)
	testing.expect_value(t, word, Address{0, 0, 0})
	_, ok := step(&doc, {3, 0, 1}, .Character, true)
	testing.expect(t, !ok)
	_, ok = step(&doc, {0, 0, 0}, .Character, false)
	testing.expect(t, !ok)
}

@(test)
test_a_step_does_not_end_in_bytes_that_are_no_text :: proc(t: ^testing.T) {
	// A character that is cut, and bytes that start none: each step
	// ends where a character can start, and the steps reach the two
	// ends of the text.
	text := transmute([]u8)string("a\xffb\xc3\n\xe2\x82z")
	for forward in ([]bool{true, false}) {
		at := forward ? 0 : len(text)
		for _ in 0 ..< len(text) {
			next := char_step(text, at, forward)
			if next == at {
				break
			}
			testing.expect(t, forward ? next > at : next < at)
			testing.expect(t, next == len(text) || text[next] & 0xc0 != 0x80)
			at = next
		}
		testing.expect_value(t, at, forward ? len(text) : 0)
	}
}

@(test)
test_the_ends_of_a_document_for_a_caret_are_of_each_text :: proc(t: ^testing.T) {
	// A text with nothing in it is a place for a caret; a rule is not.
	doc := parse("# \n\nz\n\n- \n\n---\n")
	defer destroy(&doc)
	first, last, ok := caret_ends(&doc)
	testing.expect(t, ok)
	testing.expect_value(t, first, Address{0, 0, 0})
	testing.expect_value(t, last, Address{2, 0, 0})
	rule := parse("---\n")
	defer destroy(&rule)
	_, _, ok = caret_ends(&rule)
	testing.expect(t, !ok)
}
