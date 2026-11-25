package history

import "core:testing"

// A source that the steps of a history are made on, as the owner does.
@(private = "file")
Text :: struct {
	h:     History,
	bytes: [dynamic]u8,
	caret: int,
}

@(private = "file")
edit :: proc(t: ^Text, start, end: int, came: string, now: f64, kind := Kind.Other) {
	record(&t.h, start, t.bytes[start:end], came, t.caret, now, kind)
	remove_range(&t.bytes, start, end)
	inject_at(&t.bytes, start, ..transmute([]u8)came)
	t.caret = start + len(came)
	set_caret_after(&t.h, t.caret)
}

@(private = "file")
type :: proc(t: ^Text, s: string, now: f64) {
	edit(t, t.caret, t.caret, s, now, .Typing)
}

@(private = "file")
back :: proc(t: ^Text, now: f64) {
	edit(t, t.caret - 1, t.caret, "", now, .Back)
}

@(private = "file")
take_back :: proc(t: ^Text) -> bool {
	steps := undo(&t.h) or_return
	#reverse for step in steps {
		remove_range(&t.bytes, step.start, step.start + len(came_of(&t.h, step)))
		inject_at(&t.bytes, step.start, ..gone_of(&t.h, step))
		t.caret = step.caret_before
	}
	return true
}

@(private = "file")
make_again :: proc(t: ^Text) -> bool {
	steps := redo(&t.h) or_return
	for step in steps {
		remove_range(&t.bytes, step.start, step.start + len(gone_of(&t.h, step)))
		inject_at(&t.bytes, step.start, ..came_of(&t.h, step))
		t.caret = step.caret_after
	}
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
	x.caret = 3
	edit(&x, 1, 3, "", 5)
	edit(&x, 1, 1, "\n", 5)
	end(&x.h)
	testing.expect_value(t, string(x.bytes[:]), "a\nd")
	testing.expect_value(t, len(x.h.groups), 2)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "abcd")
	testing.expect_value(t, x.caret, 3)
	testing.expect_value(t, steps_of(&x.h, 1)[0].anchor_before, 1)
	make_again(&x)
	testing.expect_value(t, string(x.bytes[:]), "a\nd")
	testing.expect_value(t, x.caret, 2)
	// A command of its own after it, at the same time.
	begin(&x.h, .Other, x.caret)
	edit(&x, 0, 1, "", 5)
	end(&x.h)
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
	edit(&x, 0, 3, "b", 21, .Replace)
	testing.expect_value(t, len(x.h.groups), 3)
	take_back(&x)
	take_back(&x)
	take_back(&x)
	testing.expect_value(t, string(x.bytes[:]), "")
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
	trim(&x.h, 25)
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
