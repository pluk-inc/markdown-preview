// The changes of the source that a reader made, in the order that they
// came, so that each can be taken back and made again.
//
// A step is one change of the source: the bytes that went and the bytes
// that came at an offset, and where the caret was before and after, with
// the other end of the text that was selected before. A
// group is the steps that one Undo takes back: the steps of one command
// (Return over a selection is two changes), and the steps that go on
// from the one before in a short time (letters that are typed one after
// the other, the text of an input method that takes the place of its
// own earlier form).
//
// This package knows no document. The owner gives it each change, and
// makes the changes of a group that `undo` or `redo` gives back.
package history

// What made a step: the steps of some kinds go on in the group before.
Kind :: enum u8 {
	// A change that is a group of its own: a paste, Return, a delete of
	// more than a character, a task that is set.
	Other,
	// Text that came at the caret.
	Typing,
	// The character before the caret went.
	Back,
	// The character after the caret went.
	Forward,
	// Text that the host put in the place of a range: it goes on in the
	// group whose last step put that range in, as the end of its text
	// (the text of an input method, which each new form of it replaces;
	// in an empty line a line break came before the first form).
	Replace,
}

Step :: struct {
	start:        int, // the offset in the source
	gone, came:   [2]int, // the bytes, as a range of `History.bytes`
	caret_before: int,
	// The other end of the text that was selected before the step; -1
	// for none. Undo selects that text again.
	anchor_before: int,
	caret_after:  int,
}

Group :: struct {
	first: int, // its first step; its last one is before the first of the next group
	bytes: int, // where the bytes of its steps start
	kind:  Kind,
	time:  f64, // of its last step, in seconds
}

History :: struct {
	steps:      [dynamic]Step,
	bytes:      [dynamic]u8,
	groups:     [dynamic]Group,
	// The groups before this one are made and can be taken back; the
	// ones from it on were taken back and can be made again.
	done:       int,
	// A command is in progress (`begin`): its steps are one group.
	depth:      int,
	kind:       Kind,
	in_command: bool, // the command has a step
	// The caret and the other end of the selection when the command
	// started: a command can move the two before its first step.
	caret:      int,
	anchor:     int,
	// The next step starts a group: the caret went to another place.
	sealed:     bool,
}

// Steps that come later than this after the one before start a group.
// Short: one Undo takes back what was typed in one go, not a sentence.
GAP :: 0.3 // seconds

// No more bytes than this are kept: the oldest groups go first.
LIMIT :: 16 << 20

destroy :: proc(h: ^History) {
	delete(h.steps)
	delete(h.bytes)
	delete(h.groups)
	h^ = {}
}

// Forgets all: the source is another one (a file that was read again).
clear :: proc(h: ^History) {
	clear_dynamic_array(&h.steps)
	clear_dynamic_array(&h.bytes)
	clear_dynamic_array(&h.groups)
	h.done = 0
	h.in_command = false
	h.sealed = false
}

// Starts a command: the steps to its `end` are one group. A command in
// a command is a part of the outer one. `caret` and `anchor` are the
// caret and the other end of the selection now (-1 for no selection):
// each step of the command has them as its state before.
begin :: proc(h: ^History, kind: Kind, caret: int, anchor := -1) {
	if h.depth == 0 {
		h.kind = kind
		h.in_command = false
		h.caret, h.anchor = caret, anchor
	}
	h.depth += 1
}

end :: proc(h: ^History) {
	h.depth = max(h.depth - 1, 0)
	if h.depth == 0 {
		h.kind = .Other
		h.in_command = false
	}
}

// The next step starts a group.
seal :: proc(h: ^History) {
	h.sealed = true
}

can_undo :: proc(h: ^History) -> bool {
	return h.done > 0
}

can_redo :: proc(h: ^History) -> bool {
	return h.done < len(h.groups)
}

// Takes a change that was made: `came` is in the place of `gone` at
// `start`. `caret_before` and `kind` are for a step that is in no
// command.
record :: proc(h: ^History, start: int, gone: []u8, came: string, caret_before: int, now: f64, kind := Kind.Other) {
	// What was taken back cannot be made again after another change.
	if h.done < len(h.groups) {
		g := h.groups[h.done]
		resize(&h.steps, g.first)
		resize(&h.bytes, g.bytes)
		resize(&h.groups, h.done)
	}
	kind, caret_before, anchor_before := kind, caret_before, -1
	if h.depth > 0 {
		kind, caret_before, anchor_before = h.kind, h.caret, h.anchor
	}
	joins := h.depth > 0 && h.in_command
	if !joins && h.done > 0 && !h.sealed {
		joins = goes_on(h, start, gone, came, caret_before, now, kind)
	}
	if !joins {
		append(&h.groups, Group{len(h.steps), len(h.bytes), kind, now})
		h.done = len(h.groups)
	}
	h.groups[h.done - 1].time = now
	h.in_command = h.depth > 0
	h.sealed = false
	step := Step{start = start, caret_before = caret_before, anchor_before = anchor_before, caret_after = caret_before}
	step.gone = {len(h.bytes), len(h.bytes) + len(gone)}
	append(&h.bytes, ..gone)
	step.came = {len(h.bytes), len(h.bytes) + len(came)}
	append(&h.bytes, came)
	append(&h.steps, step)
	trim(h)
}

// Where the caret is after the last step: the owner knows it only after
// it made the change.
set_caret_after :: proc(h: ^History, caret: int) {
	if n := len(h.steps); n > 0 {
		h.steps[n - 1].caret_after = caret
	}
}

// A step goes on in the last group: see `Kind`.
@(private)
goes_on :: proc(h: ^History, start: int, gone: []u8, came: string, caret_before: int, now: f64, kind: Kind) -> bool {
	g := h.groups[h.done - 1]
	last := h.steps[len(h.steps) - 1]
	last_gone, last_came := last.gone[1] - last.gone[0], last.came[1] - last.came[0]
	if kind == .Replace {
		// In the place of the end of what the last step put in, and
		// of nothing else.
		return len(gone) > 0 && len(gone) <= last_came && start + len(gone) == last.start + last_came && string(gone) == string(h.bytes[last.came[1] - len(gone):last.came[1]])
	}
	if kind == .Other || kind != g.kind || now - g.time > GAP || caret_before != last.caret_after {
		return false
	}
	switch kind {
	case .Typing:
		// Not after a line break: a new line is a group of its own.
		for c in transmute([]u8)came {
			if c == '\n' || c == '\r' {
				return false
			}
		}
		return len(gone) == 0 && last_gone == 0 && start == last.start + last_came
	case .Back:
		return len(came) == 0 && last_came == 0 && start + len(gone) == last.start
	case .Forward:
		return len(came) == 0 && last_came == 0 && start == last.start
	case .Other, .Replace:
	}
	return false
}

// The steps of a group, in the order that they were made.
steps_of :: proc(h: ^History, group: int) -> []Step {
	end := group + 1 < len(h.groups) ? h.groups[group + 1].first : len(h.steps)
	return h.steps[h.groups[group].first:end]
}

gone_of :: proc(h: ^History, step: Step) -> []u8 {
	return h.bytes[step.gone[0]:step.gone[1]]
}

came_of :: proc(h: ^History, step: Step) -> []u8 {
	return h.bytes[step.came[0]:step.came[1]]
}

// The group that Undo takes back: the owner puts `gone` in the place of
// `came` for each of its steps, the last step first. The steps and
// their bytes stay as they are until the next `record`.
undo :: proc(h: ^History) -> (steps: []Step, ok: bool) {
	if h.done == 0 {
		return
	}
	h.done -= 1
	h.sealed = true
	return steps_of(h, h.done), true
}

// The group that Redo makes again: the owner puts `came` in the place
// of `gone` for each of its steps, the first step first.
redo :: proc(h: ^History) -> (steps: []Step, ok: bool) {
	if h.done >= len(h.groups) {
		return
	}
	h.done += 1
	h.sealed = true
	return steps_of(h, h.done - 1), true
}

// Drops the oldest groups while the bytes are more than the limit. The
// group of the last step stays.
@(private)
trim :: proc(h: ^History, limit := LIMIT) {
	if len(h.bytes) <= limit || len(h.groups) < 2 {
		return
	}
	// The first group that stays.
	keep := 1
	for keep < len(h.groups) - 1 && len(h.bytes) - h.groups[keep].bytes > limit {
		keep += 1
	}
	steps, bytes := h.groups[keep].first, h.groups[keep].bytes
	for &step in h.steps[steps:] {
		step.gone -= bytes
		step.came -= bytes
	}
	for &g in h.groups[keep:] {
		g.first -= steps
		g.bytes -= bytes
	}
	remove_range(&h.steps, 0, steps)
	remove_range(&h.bytes, 0, bytes)
	remove_range(&h.groups, 0, keep)
	h.done = max(h.done - keep, 0)
}
