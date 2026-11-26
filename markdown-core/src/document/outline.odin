package document

import "core:strings"

// A heading of the document, for an outline.
Heading :: struct {
	level: int, // 1 to 6
	line:  int, // the source line where it starts, from 1
	title: [2]int, // its text, a range of the bytes that `outline` fills
}

// The headings of the document in their order, with the text that shows
// for each one, with no marks (also while the marks at a caret show) and
// no spaces at its ends. An empty heading is one too. It reads the
// records of the blocks, with no parse.
outline :: proc(doc: ^Document, titles: ^[dynamic]u8, out: ^[dynamic]Heading) {
	for part in doc.parts {
		lines := part_lines(part)
		for &b in part_blocks(part) {
			if b.kind != .Heading {
				continue
			}
			line := line_to(doc, &lines, part.source + b.source)
			start := len(titles)
			for span in b.text.spans {
				if .Mark not_in span.style {
					append(titles, ..b.text.bytes[span.start:span.end])
				}
			}
			title := strings.trim_space(string(titles[start:]))
			trimmed := start + len(title)
			copy(titles[start:], title)
			resize(titles, trimmed)
			append(out, Heading{b.level, line, {start, trimmed}})
		}
	}
}

// The bytes at the start of a source that are no Markdown: a byte order
// mark, and front matter after it: a first line of "---" (YAML) or "+++"
// (TOML), with spaces around it, to the first line after it that closes
// it ("---" or "..." for YAML, "+++" for TOML), with its line break. 0
// when the source has neither; a first line that nothing closes is
// Markdown. The rule of the app for the front matter that it shows above
// the page of the web renderer. The parser reads these bytes as blank
// lines (`masked_start`): they make no block, and each offset and line of
// the source after them is as it was.
hidden_start :: proc(source: []u8) -> int {
	at := 0
	if len(source) >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF {
		at = 3
	}
	end, next := line_at(source, at)
	open := strings.trim_space(string(source[at:end]))
	if open != "---" && open != "+++" {
		return at
	}
	for next < len(source) {
		start := next
		end, next = line_at(source, start)
		closing := strings.trim_space(string(source[start:end]))
		if open == "---" ? closing == "---" || closing == "..." : closing == "+++" {
			return next
		}
	}
	return at
}

// A copy of a piece of the source that starts at the start of the source,
// with the bytes of `hidden_start` as spaces and their line breaks kept:
// blank lines for the parser. nil when the source has no such bytes.
masked_start :: proc(bytes: []u8, allocator := context.allocator) -> []u8 {
	hidden := hidden_start(bytes)
	if hidden == 0 {
		return nil
	}
	masked := make([]u8, len(bytes), allocator)
	copy(masked, bytes)
	for &b in masked[:hidden] {
		if b != '\n' && b != '\r' {
			b = ' '
		}
	}
	return masked
}
