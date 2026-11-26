package document

// A heading of the document, for an outline.
Heading :: struct {
	level: int, // 1 to 6
	line:  int, // the source line where it starts, from 1
	title: [2]int, // its text, a range of the bytes that `outline` fills
}

// The headings of the document in their order, with the text that shows
// for each one, with no marks (also while the marks at a caret show).
// An empty heading is one too. A heading in front matter at the top of
// the source (`front_matter_lines`) is none: front matter is no Markdown.
// It reads the records of the blocks, with no parse.
outline :: proc(doc: ^Document, titles: ^[dynamic]u8, out: ^[dynamic]Heading) {
	skip := front_matter_lines(doc.source)
	for part in doc.parts {
		// The lines before the part, and from its start to each block.
		line, counted := part.line + 1, part.source
		for &b in part_blocks(part) {
			if b.kind != .Heading {
				continue
			}
			at := part.source + b.source
			line += count_lines(doc.source, counted, at)
			counted = at
			if line <= skip {
				continue
			}
			start := len(titles)
			for span in b.text.spans {
				if .Mark not_in span.style {
					append(titles, ..b.text.bytes[span.start:span.end])
				}
			}
			append(out, Heading{b.level, line, {start, len(titles)}})
		}
	}
}

// How many lines of the source are front matter: a first line of "---"
// (YAML) or "+++" (TOML), with spaces or tabs around it, to the first
// line after it that closes it ("---" or "..." for YAML, "+++" for TOML).
// 0 when the source has none, or when nothing closes it. The same rule
// as the front matter that the app shows above the page; a byte order
// mark at the start is no part of the first line.
front_matter_lines :: proc(source: []u8) -> int {
	trimmed :: proc(line: []u8) -> string {
		first, last := 0, len(line)
		for first < last && (line[first] == ' ' || line[first] == '\t') {
			first += 1
		}
		for last > first && (line[last - 1] == ' ' || line[last - 1] == '\t') {
			last -= 1
		}
		return string(line[first:last])
	}
	at := 0
	if len(source) >= 3 && source[0] == 0xEF && source[1] == 0xBB && source[2] == 0xBF {
		at = 3
	}
	// The next line from `at`, and where the line after it starts.
	next_line :: proc(source: []u8, at: int) -> (line: []u8, next: int) {
		end := at
		for end < len(source) && source[end] != '\n' && source[end] != '\r' {
			end += 1
		}
		// LF, CRLF, or CR.
		next = end
		if next < len(source) && source[next] == '\r' {
			next += 1
		}
		if next < len(source) && source[next] == '\n' {
			next += 1
		}
		return source[at:end], next
	}
	first, after := next_line(source, at)
	open := trimmed(first)
	if open != "---" && open != "+++" {
		return 0
	}
	lines := 1
	for after < len(source) {
		line: []u8
		line, after = next_line(source, after)
		lines += 1
		closing := trimmed(line)
		if open == "---" ? closing == "---" || closing == "..." : closing == "+++" {
			return lines
		}
	}
	return 0
}
