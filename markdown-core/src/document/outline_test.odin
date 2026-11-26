package document

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
headings_of :: proc(source: string) -> string {
	doc := parse(source)
	defer destroy(&doc)
	titles: [dynamic]u8
	defer delete(titles)
	out: [dynamic]Heading
	defer delete(out)
	outline(&doc, &titles, &out)
	text := strings.builder_make()
	for h in out {
		fmt.sbprintf(&text, "%d@%d:%s|", h.level, h.line, string(titles[h.title[0]:h.title[1]]))
	}
	return strings.to_string(text)
}

@(test)
test_the_outline_has_each_heading_with_its_line_and_text :: proc(t: ^testing.T) {
	Case :: struct {
		source, want: string,
	}
	cases := []Case {
		{"# One\n\ntext\n\n## Two **bold** `code` [link](u)\n", "1@1:One|2@5:Two bold code link|"},
		// Setext headings, empty headings, headings in containers.
		{"Top\n===\n\n#\n\n> ### In a quote\n\n- #### In an item\n", "1@1:Top|1@4:|3@6:In a quote|4@8:In an item|"},
		// Not in code.
		{"```\n# not\n```\n\n# yes\n", "1@5:yes|"},
		// Front matter is no Markdown; its lines still count.
		{"---\ntitle: x\n---\n\n# Body\n", "1@5:Body|"},
		{"+++\ntitle = 'x'\n+++\n# Body\n", "1@4:Body|"},
		{"---\na: b\n...\n# Body\n", "1@4:Body|"},
		// No closing line: no front matter.
		{"---\n# Body\n", "1@2:Body|"},
		{"\r\n# CRLF\r\n\r\n## Two\r\n", "1@2:CRLF|2@4:Two|"},
	}
	for c in cases {
		got := headings_of(c.source)
		defer delete(got)
		testing.expectf(t, got == c.want, "%q: %q, not %q", c.source, got, c.want)
	}
}

// The lines are right after the first part of the document too.
@(test)
test_the_outline_counts_lines_over_parts :: proc(t: ^testing.T) {
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for i in 0 ..< 3 * PART_BLOCKS {
		fmt.sbprintf(&text, "# H%d\n\n", i)
	}
	got := headings_of(strings.to_string(text))
	defer delete(got)
	want := strings.builder_make()
	defer strings.builder_destroy(&want)
	for i in 0 ..< 3 * PART_BLOCKS {
		fmt.sbprintf(&want, "1@%d:H%d|", 2 * i + 1, i)
	}
	testing.expect_value(t, got, strings.to_string(want))
}

// The marks that show at a caret are no part of the text of a heading.
@(test)
test_the_outline_has_no_marks_that_show :: proc(t: ^testing.T) {
	source := "## A **b**\n"
	doc := parse_owned(transmute([]u8)fmt.aprintf("%s", source), 8)
	defer destroy(&doc)
	testing.expect(t, len(block_at(&doc, 0).text.bytes) > len("A b"))
	titles: [dynamic]u8
	defer delete(titles)
	out: [dynamic]Heading
	defer delete(out)
	outline(&doc, &titles, &out)
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, string(titles[:]), "A b")
}

// The cases that the app's outline of the web renderer is tested with
// too (outline_cases.json, beside this file): the two outlines have the same
// headings and lines, and the same texts but where a case says
// `native_title`: the text of a heading as the native page shows it
// (raw HTML in a heading shows its text, not its tags).
@(test)
test_the_outline_has_the_headings_of_the_shared_cases :: proc(t: ^testing.T) {
	Want :: struct {
		level, line:         int,
		title, native_title: string,
	}
	Case :: struct {
		source:   string,
		headings: []Want,
	}
	cases: []Case
	if err := json.unmarshal(#load("outline_cases.json"), &cases, allocator = context.temp_allocator); err != nil {
		testing.fail_now(t, fmt.tprint("the cases do not parse:", err))
	}
	for c in cases {
		want := strings.builder_make(context.temp_allocator)
		for h in c.headings {
			fmt.sbprintf(&want, "%d@%d:%s|", h.level, h.line, h.native_title if h.native_title != "" else h.title)
		}
		got := headings_of(c.source)
		defer delete(got)
		testing.expectf(t, got == strings.to_string(want), "%q: %q, not %q", c.source, got, strings.to_string(want))
	}
}
