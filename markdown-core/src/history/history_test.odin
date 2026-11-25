package history

import "core:testing"
import "core:time"

// A source that the steps of a history are made on, as the owner does.
@(private = "file")
Text :: struct {
	h:     History,
	bytes: [dynamic]u8,
	caret: int,
}

// A time `s` seconds after a start.
@(private = "file")
at :: proc(s: f64) -> time.Tick {
	return time.tick_add({}, time.Duration(s * f64(time.Second)))
}

// One change in one command of its own.
@(private = "file")
edit :: proc(t: ^Text, start, stop: int, came: string, s: f64, kind := Kind.Other, anchor := -1) {
	begin(&t.h, kind, t.caret, anchor)
	change(t, start, stop, came, s)
	end(&t.h, t.caret)
}

// One change in the command in progress.
@(private = "file")
change :: proc(t: ^Text, start, end: int, came: string, s: f64) {
	record(&t.h, start, t.bytes[start:end], came, at(s))
	remove_range(&t.bytes, start, end)
	inject_at(&t.bytes, start, ..transmute([]u8)came)
	t.caret = start + len(came)
}

@(private = "file")
type :: proc(t: ^Text, s: string, sec: f64) {
	edit(t, t.caret, t.caret, s, sec, .Typing)
}

@(private = "file")
back :: proc(t: ^Text, s: f64) {
	edit(t, t.caret - 1, t.caret, "", s, .Back)
}

@(private = "file")
take_back :: proc(t: ^Text) -> bool {
	steps, group := undo(&t.h) or_return
	#reverse for step in steps {
		remove_range(&t.bytes, step.start, step.start + len(came_of(&t.h, step)))
		inject_at(&t.bytes, step.start, ..gone_of(&t.h, step))
	}
	t.caret = group.caret_before
	return true
}

@(private = "file")
make_again :: proc(t: ^Text) -> bool {
	steps, group := redo(&t.h) or_return
	for step in steps {
		remove_range(&t.bytes, step.start, step.start + len(gone_of(&t.h, step)))
		inject_at(&t.bytes, step.start, ..came_of(&t.h, step))
	}
	t.caret = group.caret_after
	return true
}

@(private = "file")
free_text :: proc(t: ^Text) {
	destroy(&t.h)
	delete(t.bytes)
}

@(test)
test_letters_typed_in_a_row_are_one_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "a", 0)
	type(&x, "b", 0.1)
	type(&x, "c", 0.3)
	testing.expect_value(t, len(x.h.groups), 1)
	// One step: Undo is one change of the source.
	testing.expect_value(t, len(x.h.steps), 1)
	testing.expect(t, take_back(&x))
	testing.expect_value(t, string(x.bytes[:]), "")
	testing.expect_value(t, x.caret, 0)
	testing.expect(t, !take_back(&x))
	testing.expect(t, make_again(&x))
	testing.expect_value(t, string(x.bytes[:]), "abc")
	testing.expect_value(t, x.caret, 3)
	testing.expect(t, !make_again(&x))
}

@(test)
test_a_wait_starts_a_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "a", 0)
	type(&x, "b", 0.1)
	type(&x, "c", 0.1 + GAP + 0.01)
	testing.expect_value(t, len(x.h.groups), 2)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "ab")
}

@(test)
test_a_caret_that_went_away_starts_a_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "ab", 0)
	// The caret went to another place and came back.
	seal(&x.h)
	type(&x, "c", 0.1)
	testing.expect_value(t, len(x.h.groups), 2)
	// Or it is at another offset.
	x.caret = 0
	type(&x, "d", 0.2)
	testing.expect_value(t, len(x.h.groups), 3)
	testing.expect_value(t, string(x.bytes[:]), "dabc")
	take_back(&x)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "ab")
}

@(test)
test_a_line_break_and_a_delete_are_groups_of_their_own :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "ab", 0)
	type(&x, "\n", 0.1)
	type(&x, "c", 0.2)
	testing.expect_value(t, len(x.h.groups), 2)
	back(&x, 0.3)
	back(&x, 0.5)
	testing.expect_value(t, len(x.h.groups), 3)
	testing.expect_value(t, len(x.h.steps), 3)
	testing.expect_value(t, string(x.bytes[:]), "ab")
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "ab\nc")
	testing.expect_value(t, x.caret, 4)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "ab")
}

@(test)
test_the_steps_of_a_command_are_one_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "abcd", 0)
	// Return over a selection: the text goes, then the line break comes.
	begin(&x.h, .Other, 3, 1)
	change(&x, 1, 3, "", 5)
	change(&x, 1, 1, "\n", 5)
	// The command moved the caret after its last change.
	x.caret = 2
	end(&x.h, x.caret)
	testing.expect_value(t, string(x.bytes[:]), "a\nd")
	testing.expect_value(t, len(x.h.groups), 2)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "abcd")
	testing.expect_value(t, x.caret, 3)
	testing.expect_value(t, x.h.groups[1].anchor_before, 1)
	make_again(&x)
	testing.expect_value(t, string(x.bytes[:]), "a\nd")
	testing.expect_value(t, x.caret, 2)
	// A command of its own after it, at the same time.
	edit(&x, 0, 1, "", 5)
	testing.expect_value(t, len(x.h.groups), 3)
}

@(test)
test_the_forms_of_the_text_of_an_input_method_are_one_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "n", 0)
	edit(&x, 0, 1, "ni", 3, .Replace)
	edit(&x, 0, 2, "你", 9, .Replace)
	testing.expect_value(t, len(x.h.groups), 1)
	// Text that takes the place of other text is a group of its own.
	type(&x, "a", 20)
	edit(&x, 0, 4, "b", 21, .Replace)
	testing.expect_value(t, len(x.h.groups), 3)
	take_back(&x)
	take_back(&x)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "")
}

// An input method that starts over text that is selected: its first
// form takes the place of the selection, and its later forms go on in
// that group, so one Undo gives the selected text back.
@(test)
test_an_input_method_over_a_selection_is_one_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	append(&x.bytes, "a hello")
	x.caret = 7
	edit(&x, 2, 7, "n", 30, .Other, anchor = 2)
	edit(&x, 2, 3, "ni", 31, .Replace)
	edit(&x, 2, 4, "你", 40, .Replace)
	testing.expect_value(t, string(x.bytes[:]), "a 你")
	testing.expect_value(t, len(x.h.groups), 1)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "a hello")
	testing.expect_value(t, x.caret, 7)
	// A paste after it is a group of its own, and so is typing after
	// the paste.
	edit(&x, 7, 7, "XY", 50)
	type(&x, "z", 50.1)
	testing.expect_value(t, len(x.h.groups), 2)
}

// In an empty line the first form came with a line break before it; the
// input method that is let go takes the line break back with the text.
@(test)
test_an_input_method_that_is_let_go_in_an_empty_line_is_one_group :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	append(&x.bytes, "a\n")
	x.caret = 2
	type(&x, "\nか", 0)
	edit(&x, 3, 6, "かな", 1, .Replace)
	edit(&x, 2, 9, "", 2, .Replace)
	testing.expect_value(t, string(x.bytes[:]), "a\n")
	testing.expect_value(t, len(x.h.groups), 1)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "a\n")
	testing.expect(t, !can_undo(&x.h))
}

// A change to the same bytes is no step, and a command with no step
// makes no group.
@(test)
test_a_change_to_the_same_bytes_is_none :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "abc", 0)
	edit(&x, 0, 3, "abc", 5)
	testing.expect_value(t, len(x.h.groups), 1)
	testing.expect_value(t, len(x.h.steps), 1)
}

@(test)
test_a_change_after_an_undo_ends_what_can_be_made_again :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	type(&x, "a", 0)
	type(&x, "b", 5)
	take_back(&x)
	testing.expect(t, can_redo(&x.h))
	type(&x, "c", 10)
	testing.expect(t, !can_redo(&x.h))
	testing.expect_value(t, string(x.bytes[:]), "ac")
	take_back(&x)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "")
	testing.expect(t, !can_undo(&x.h))
	make_again(&x)
	make_again(&x)
	testing.expect_value(t, string(x.bytes[:]), "ac")
}

@(test)
test_the_oldest_groups_go_at_the_limit :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	for i in 0 ..< 6 {
		type(&x, "0123456789", f64(i) * 10)
	}
	testing.expect_value(t, len(x.h.groups), 6)
	// Room for two groups of ten bytes and one step each.
	trim(&x.h, 2 * (10 + size_of(Step) + size_of(Group)) + 5)
	testing.expect_value(t, len(x.h.groups), 2)
	testing.expect_value(t, x.h.done, 2)
	testing.expect(t, take_back(&x))
	testing.expect(t, take_back(&x))
	testing.expect(t, !take_back(&x))
	testing.expect_value(t, string(x.bytes[:]), "0123456789012345678901234567890123456789")
	make_again(&x)
	make_again(&x)
	testing.expect_value(t, len(x.bytes), 60)
}

// Characters that go one after the other with the Delete key and with
// the forward delete are one step each way.
@(test)
test_deletes_in_a_row_are_one_step :: proc(t: ^testing.T) {
	x: Text
	defer free_text(&x)
	append(&x.bytes, "abcdef")
	x.caret = 4
	back(&x, 0)
	back(&x, 0.1)
	testing.expect_value(t, string(x.bytes[:]), "abef")
	edit(&x, 2, 3, "", 0.2, .Forward)
	edit(&x, 2, 3, "", 0.3, .Forward)
	testing.expect_value(t, string(x.bytes[:]), "ab")
	testing.expect_value(t, len(x.h.groups), 2)
	testing.expect_value(t, len(x.h.steps), 2)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "abef")
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "abcdef")
	testing.expect_value(t, x.caret, 4)
	make_again(&x)
	make_again(&x)
	testing.expect_value(t, string(x.bytes[:]), "ab")
}
