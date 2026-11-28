package document

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// The cases that the app's parser of front matter is tested with too
// (frontmatter_cases.json, beside this file): the panel of the native
// page has the keys, the values, and the items that the web page shows.
@(test)
test_front_matter_has_the_entries_of_the_shared_cases :: proc(t: ^testing.T) {
	Want :: struct {
		key, value: string,
		items:      []string,
	}
	Case :: struct {
		source:  string,
		entries: []Want,
	}
	cases: []Case
	if err := json.unmarshal(#load("frontmatter_cases.json"), &cases, allocator = context.temp_allocator); err != nil {
		testing.fail_now(t, fmt.tprint("the cases do not parse:", err))
	}
	show :: proc(out: ^strings.Builder, key, value: string, items: []string) {
		fmt.sbprintf(out, "%s=%s", key, value)
		for item in items {
			fmt.sbprintf(out, "[%s]", item)
		}
		strings.write_byte(out, '|')
	}
	for c in cases {
		want := strings.builder_make(context.temp_allocator)
		for e in c.entries {
			show(&want, e.key, e.value, e.items)
		}
		source := transmute([]u8)c.source
		hidden, unclosed := hidden_start(source)
		got := strings.builder_make(context.temp_allocator)
		if !unclosed {
			for e in front_matter(source, hidden, context.temp_allocator) {
				show(&got, e.key, e.value, e.items)
			}
		}
		testing.expectf(t, strings.to_string(got) == strings.to_string(want), "%q: %q, not %q", c.source, strings.to_string(got), strings.to_string(want))
	}
}

// A value of many lines is its lines with a space between them, and the
// value of the entry after it starts new. The memory for it is about its
// size, not its size times its lines.
@(test)
test_a_front_matter_value_of_many_lines :: proc(t: ^testing.T) {
	LINES :: 2000
	source := strings.builder_make(context.temp_allocator)
	want := strings.builder_make(context.temp_allocator)
	strings.write_string(&source, "---\ntext: |\n")
	for i in 0 ..< LINES {
		fmt.sbprintf(&source, "  line %d\n", i)
		fmt.sbprintf(&want, "%sline %d", i > 0 ? " " : "", i)
	}
	strings.write_string(&source, "first: one\n  two\nlast: end\n---\n\nBody.\n")
	bytes := transmute([]u8)strings.to_string(source)
	hidden, _ := hidden_start(bytes)
	// Memory of a fixed size: a parse that needs more gets none.
	arena: mem.Arena
	buffer := make([]u8, 16 * len(bytes))
	defer delete(buffer)
	mem.arena_init(&arena, buffer)
	entries := front_matter(bytes, hidden, mem.arena_allocator(&arena))
	if !testing.expect_value(t, len(entries), 3) {
		return
	}
	testing.expect_value(t, entries[0].value, strings.to_string(want))
	testing.expect_value(t, entries[1].value, "one two")
	testing.expect_value(t, entries[2].value, "end")
}
