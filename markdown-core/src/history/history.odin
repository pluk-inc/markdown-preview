// The changes of the source that a reader made, in the order that they
// came, so that each can be taken back and made again.
//
// A step is one change of the source: the bytes that went and the bytes
// that came at an offset. A group is the steps that one Undo takes back,
// with the caret and the selection before them and the caret after them:
// the steps of one command (Return over a selection is two changes), and
// the commands that go on from the one before in a short time (letters
// that are typed one after the other, the text of an input method that
// takes the place of its own earlier form).
//
// This package knows no document. The owner makes each change in a
// command (`begin`, `record`, `end`), and makes the changes of a group
// that `undo` or `redo` gives back.
package history

import "core:time"

// What a command is: the commands of some kinds go on in the group
// before.
Kind :: enum u8 {
	// A command that is a group of its own: a paste, Return, a delete of
	// more than a character, a task that is set.
	Other,
	// Text that came at the caret.
	Typing,
	// The character before the caret went.
	Back,
	// The character after the caret went.
	Forward,
	// Text that the host put in the place of a range: it goes on in the
	// last group when the range is the end of the text that the group
	// put in (the text of an input method, which each new form of it
	// replaces: also its first form over text that was selected; in an
	// empty line a line break came before its first form, and goes with
	// all of its text when it is taken back).
	Replace,
}

Step :: struct {
	start:      int, // the offset in the source
	gone, came: [2]int, // the bytes, as a range of `History.bytes`
}

Group :: struct {
	first: int, // its first step; its last one is before the first of the next group
	bytes: int, // where the bytes of its steps start
	kind:  Kind,
	time:  time.Tick, // of its last step
	// The caret and the other end of the selection (-1 for none) before
	// the group, and the caret after it. `upstream`: the caret is at the
	// end of a line where its offset is also the start of the next one
	// (a line that wraps).
	caret_before:    int,
	anchor_before:   int,
	caret_after:     int,
	upstream_before: bool,
	upstream_after:  bool,
}

History :: struct {
	steps:      [dynamic]Step,
	bytes:      [dynamic]u8,
	groups:     [dynamic]Group,
	// The groups before this one are made and can be taken back; the
	// ones from it on were taken back and can be made again.
	done:       int,
	// The command that is in progress (`begin`).
	depth:      int,
	kind:       Kind,
	caret:      int,
	anchor:     int,
	upstream:   bool,
	in_command: bool, // the command has a step
	// The next command starts a group: the caret went to another place.
	sealed:     bool,
}

// A command that comes later than this after the one before starts a
// group. Short: one Undo takes back what was typed in one go, not a
// sentence.
GAP :: 0.3 // seconds

// When the memory of the history (its bytes and its records) is more
// than this, the oldest groups go until it is half of it: no key moves
// all of them.
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

// Starts a command: its steps (`record`) to its `end` go in one group.
// A command in a command is a part of the outer one. `caret` and
// `anchor` are the caret and the other end of the selection now (-1 for
// no selection); `upstream` is the side of the caret at the end of a
// line.
begin :: proc(h: ^History, kind: Kind, caret: int, anchor := -1, upstream := false) {
	if h.depth == 0 {
		h.kind = kind
		h.caret, h.anchor, h.upstream = caret, anchor, upstream
		h.in_command = false
	}
	h.depth += 1
}

// Ends a command, with the caret where it is after all that the command
// did, and its side at the end of a line.
end :: proc(h: ^History, caret: int, upstream := false) {
	h.depth = max(h.depth - 1, 0)
	if h.depth > 0 {
		return
	}
	if h.in_command {
		h.groups[h.done - 1].caret_after = caret
		h.groups[h.done - 1].upstream_after = upstream
	}
	h.in_command = false
}

// The next command starts a group.
seal :: proc(h: ^History) {
	h.sealed = true
}

can_undo :: proc(h: ^History) -> bool {
	return h.done > 0
}

can_redo :: proc(h: ^History) -> bool {
	return h.done < len(h.groups)
}

// Takes a change that the command in progress made: `came` is in the
// place of `gone` at `start`. A change to the same bytes is none.
record :: proc(h: ^History, start: int, gone: []u8, came: string, now: time.Tick) {
	assert(h.depth > 0, "a change of the history out of a command")
	if string(gone) == came {
		return
	}
	// What was taken back cannot be made again after another change.
	if h.done < len(h.groups) {
		g := h.groups[h.done]
		resize(&h.steps, g.first)
		resize(&h.bytes, g.bytes)
		resize(&h.groups, h.done)
	}
	goes := !h.in_command && h.done > 0 && !h.sealed && goes_on(h, start, gone, came, now)
	if goes && merge(h, start, gone, came) {
		h.groups[h.done - 1].time = now
		h.in_command = true
		keep_in_limit(h)
		return
	}
	if !(h.in_command || goes) {
		append(&h.groups, Group{len(h.steps), len(h.bytes), h.kind, now, h.caret, h.anchor, h.caret, h.upstream, h.upstream})
		h.done = len(h.groups)
	}
	h.groups[h.done - 1].time = now
	h.in_command = true
	h.sealed = false
	step := Step{start = start}
	step.gone = {len(h.bytes), len(h.bytes) + len(gone)}
	append(&h.bytes, ..gone)
	step.came = {len(h.bytes), len(h.bytes) + len(came)}
	append(&h.bytes, came)
	append(&h.steps, step)
	keep_in_limit(h)
}

@(private)
keep_in_limit :: proc(h: ^History) {
	if size_from(h, 0) > LIMIT {
		trim(h, LIMIT / 2)
	}
}

// A step that goes on in the last group and is next to its last step in
// the source is a part of that step: Undo of a run of characters is one
// change of the source, not one for each character. The bytes of the
// last step are at the end of `bytes`, so they grow in place.
@(private)
merge :: proc(h: ^History, start: int, gone: []u8, came: string) -> bool {
	last := &h.steps[len(h.steps) - 1]
	switch h.kind {
	case .Typing:
		// After the text of the last step.
		append(&h.bytes, came)
		last.came[1] += len(came)
	case .Back:
		// Before the bytes that went: they are the last ones, as the
		// step put nothing in.
		inject_at(&h.bytes, last.gone[0], ..gone)
		last.start = start
		last.gone[1] += len(gone)
		last.came += len(gone)
	case .Forward:
		append(&h.bytes, ..gone)
		last.gone[1] += len(gone)
		last.came += len(gone)
	case .Replace:
		// In the place of the end of the text of the last step only: a
		// range that starts before it (the line break before the text of
		// an input method in an empty line) is a step of its own.
		if start < last.start {
			return false
		}
		resize(&h.bytes, len(h.bytes) - len(gone))
		append(&h.bytes, came)
		last.came[1] = len(h.bytes)
	case .Other:
		return false
	}
	return true
}

// The first step of a command goes on in the last group: see `Kind`.
@(private)
goes_on :: proc(h: ^History, start: int, gone: []u8, came: string, now: time.Tick) -> bool {
	g := h.groups[h.done - 1]
	last := h.steps[len(h.steps) - 1]
	last_end := last.start + (last.came[1] - last.came[0])
	if h.kind == .Replace {
		// In the place of the end of what the group put in, and of
		// nothing else.
		return last.came[1] > last.came[0] && len(gone) > 0 && start >= h.steps[g.first].start && start + len(gone) == last_end
	}
	if h.kind == .Other || h.kind != g.kind || h.caret != g.caret_after || time.duration_seconds(time.tick_diff(g.time, now)) > GAP {
		return false
	}
	last_gone, last_came := last.gone[1] - last.gone[0], last.came[1] - last.came[0]
	switch h.kind {
	case .Typing:
		// Not a line break: a new line is a group of its own.
		for c in transmute([]u8)came {
			if c == '\n' || c == '\r' {
				return false
			}
		}
		return len(gone) == 0 && last_gone == 0 && start == last_end
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
undo :: proc(h: ^History) -> (steps: []Step, group: Group, ok: bool) {
	if h.done == 0 {
		return
	}
	h.done -= 1
	h.sealed = true
	return steps_of(h, h.done), h.groups[h.done], true
}

// The group that Redo makes again: the owner puts `came` in the place
// of `gone` for each of its steps, the first step first.
redo :: proc(h: ^History) -> (steps: []Step, group: Group, ok: bool) {
	if h.done >= len(h.groups) {
		return
	}
	h.done += 1
	h.sealed = true
	return steps_of(h, h.done - 1), h.groups[h.done - 1], true
}

// The memory of the groups from `group` on, with their steps and bytes.
@(private)
size_from :: proc(h: ^History, group: int) -> int {
	if group >= len(h.groups) {
		return 0
	}
	g := h.groups[group]
	return len(h.bytes) - g.bytes + (len(h.steps) - g.first) * size_of(Step) + (len(h.groups) - group) * size_of(Group)
}

// Drops the oldest groups until the memory of the history is no more
// than `limit`. The last group stays.
@(private)
trim :: proc(h: ^History, limit: int) {
	if len(h.groups) < 2 {
		return
	}
	// The first group that stays.
	keep := 1
	for keep < len(h.groups) - 1 && size_from(h, keep) > limit {
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
