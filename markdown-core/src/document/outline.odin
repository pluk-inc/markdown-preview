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
// it ("---" or "..." for YAML, "+++" for TOML), with its line break.
// `unclosed`: the first line opens front matter that nothing closes, so
// it is Markdown. The rule of the app for the front matter that it shows
// above the page of the web renderer. The parser reads these bytes as
// blank lines (`masked_start`): they make no block, and each offset and
// line of the source after them is as it was.
hidden_start :: proc(source: []u8) -> (hidden: int, unclosed: bool) {
	at := bom_size(source)
	open := opening_line(source)
	if open == "" {
		return at, false
	}
	_, next := line_at(source, at)
	for next < len(source) {
		start := next
		end: int
		end, next = line_at(source, start)
		if closes(open, source[start:end]) {
			return next, false
		}
	}
	return at, true
}

// 3 for a source that starts with a byte order mark, else 0.
bom_size :: proc(source: []u8) -> int {
	return len(source) >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF ? 3 : 0
}

// The first line of a source when it opens front matter ("---", "+++"),
// with no spaces around it; "" for any other first line.
@(private)
opening_line :: proc(source: []u8) -> string {
	at := bom_size(source)
	end, _ := line_at(source, at)
	open := strings.trim_space(string(source[at:end]))
	return open == "---" || open == "+++" ? open : ""
}

@(private)
closes :: proc(open: string, line: []u8) -> bool {
	closing := strings.trim_space(string(line))
	return open == "---" ? closing == "---" || closing == "..." : closing == "+++"
}

// If an edit can change the bytes at the start that are no Markdown
// (`Document.hidden`), with no read of all of the source: an edit in the
// first line or before the end of front matter, and, when nothing closes
// the front matter, an edit whose lines in the new source close it.
hidden_changes :: proc(doc: ^Document, start, end: int, source: []u8, text_len: int) -> bool {
	first, _ := line_at(doc.source, bom_size(doc.source))
	if start <= first || start <= doc.hidden && doc.hidden > bom_size(doc.source) {
		return true
	}
	if !doc.unclosed {
		return false
	}
	// The lines of the new source that the edit is in.
	open := opening_line(doc.source)
	line := start
	for line > 0 && source[line - 1] != '\n' && source[line - 1] != '\r' {
		line -= 1
	}
	for line <= start + text_len && line < len(source) {
		line_end, next := line_at(source, line)
		if closes(open, source[line:line_end]) {
			return true
		}
		line = next
	}
	return false
}

// A copy of a piece of the source that starts at the start of the source,
// with the bytes of `hidden_start` as blank lines for the parser: the
// front matter as spaces with its line breaks, the byte order mark as
// line breaks. nil when the source has no such bytes.
masked_start :: proc(bytes: []u8, allocator := context.allocator) -> (masked: []u8, hidden: int, unclosed: bool) {
	hidden, unclosed = hidden_start(bytes)
	if hidden == 0 {
		return
	}
	masked = make([]u8, len(bytes), allocator)
	copy(masked, bytes)
	// The mark as line breaks, not as spaces: spaces before the first line
	// would make it code. The lines are counted from the source itself.
	bom := bom_size(bytes)
	for &b in masked[:bom] {
		b = '\n'
	}
	for &b in masked[bom:hidden] {
		if b != '\n' && b != '\r' {
			b = ' '
		}
	}
	return
}
