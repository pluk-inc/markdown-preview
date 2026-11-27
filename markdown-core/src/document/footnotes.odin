package document

import "core:fmt"
import "core:strings"

// The footnotes of a source: the references in its text and the texts
// that they refer to. The parser of the core has no footnotes, so this
// reads them from the source, by the rules of the app's web renderer
// (`MarkdownHTML+Footnotes`) and of the Markdown that readers write:
//
// - A reference is "[^label]" in the text. The label is a number or a
//   name; a footnote shows as a number in each case.
// - A definition is a line "[^label]: text", with no more than three
//   spaces before it. It goes on in the lines after it that start with
//   `FOOTNOTE_INDENT` spaces or a tab, also after an empty line.
// - An inline footnote is "^[text]" in the text: a reference with its
//   text in it.
// - Not in code: a reference in a fenced code block or between
//   backticks is text.
// - The footnotes have their numbers in the order of their first
//   reference. A reference with no definition is text, and a definition
//   that no reference has shows nowhere (its number is 0).

FOOTNOTE_INDENT :: 2

Footnote :: struct {
	number:    int, // from 1; 0 for a definition with no reference
	label:     string, // as it is written; "" for an inline footnote
	inline:    bool,
	// A definition: its lines in the source, to the start of the line
	// after its last one, and where its text starts in its first line.
	// An inline footnote: the "^[" to the "]", and its text after "^[".
	start, end: int,
	content:   int,
	mark:      int, // of a definition: where its "[" is
}

Footnote_Reference :: struct {
	start, end: int, // of "[^label]", or of "^[text]"
	note:       int, // in the footnotes
	ordinal:    int, // from 1: which reference of its footnote it is
}

Footnotes :: struct {
	notes:      []Footnote, // the definitions in the order of the source, then nothing: inline ones are among them at their place
	references: []Footnote_Reference, // in the order of the source
}

// Reads the footnotes of a source from `from` (after what the document
// hides at its start). The memory is of `allocator`.
footnotes :: proc(source: []u8, from: int, allocator := context.allocator) -> (found: Footnotes) {
	// Most sources have none: one look for the two characters.
	if !strings.contains(string(source[min(from, len(source)):]), "[^") && !strings.contains(string(source[min(from, len(source)):]), "^[") {
		return
	}
	context.allocator = allocator
	notes := make([dynamic]Footnote)
	references := make([dynamic]Footnote_Reference)
	keys := make([dynamic]string, context.temp_allocator) // of each note, "" for an inline one
	// The lines of text: not of a fenced code block, and not of a
	// definition. A definition is found first, so a reference before its
	// definition has it.
	Piece :: struct {
		start, end: int,
	}
	text_lines := make([dynamic]Piece, context.temp_allocator)
	fence: u8
	fence_len := 0
	for at := min(from, len(source)); at < len(source); {
		end, next := line_at(source, at)
		line := source[at:end]
		lead := 0
		for lead < len(line) && lead < 3 && line[lead] == ' ' {
			lead += 1
		}
		run := lead
		for run < len(line) && (line[run] == '`' || line[run] == '~') && line[run] == line[lead] {
			run += 1
		}
		switch {
		case fence != 0:
			// The closing fence: the same character, not shorter, and
			// nothing after it.
			if run - lead >= fence_len && line[lead] == fence && strings.trim(string(line[run:]), " \t") == "" {
				fence = 0
			}
		case run - lead >= 3 && !(line[lead] == '`' && strings.contains_rune(string(line[run:]), '`')):
			fence, fence_len = line[lead], run - lead
		case:
			if label, mark, content, is_definition := footnote_definition(line); is_definition {
				note := Footnote{label = label, start = at, content = at + content, mark = at + mark}
				// The lines that it goes on in.
				for next < len(source) {
					line_end, after := line_at(source, next)
					following := source[next:line_end]
					if strings.trim(string(following), " \t") == "" {
						// An empty line: only before a line that goes on.
						if after >= len(source) {
							break
						}
						second_end, _ := line_at(source, after)
						if !footnote_continues(source[after:second_end]) {
							break
						}
					} else if !footnote_continues(following) {
						break
					}
					next = after
				}
				note.end = next
				append(&notes, note)
				append(&keys, footnote_key(label))
			} else {
				append(&text_lines, Piece{at, end})
			}
		}
		at = next
	}
	// The references, in the order of the source.
	numbers := 0
	ordinals := make([dynamic]int, context.temp_allocator)
	resize(&ordinals, len(notes))
	for piece in text_lines {
		for i := piece.start; i < piece.end; {
			ch := source[i]
			switch {
			case ch == '`':
				// Code between two runs of backticks of the same length,
				// in the line: no reference in it.
				run := i
				for run < piece.end && source[run] == '`' {
					run += 1
				}
				close := footnote_code_end(source, run, piece.end, run - i)
				i = close > 0 ? close : run
			case ch == '[' && i + 1 < piece.end && source[i + 1] == '^':
				close := i + 2
				for close < piece.end && source[close] != ']' {
					close += 1
				}
				if close >= piece.end || close == i + 2 {
					i += 2
					continue
				}
				key := footnote_key(string(source[i + 2:close]))
				// The last definition of a label is the one of its
				// references.
				note := -1
				#reverse for k, n in keys {
					if k == key && !notes[n].inline {
						note = n
						break
					}
				}
				if note < 0 {
					i = close + 1
					continue
				}
				if notes[note].number == 0 {
					numbers += 1
					notes[note].number = numbers
				}
				ordinals[note] += 1
				append(&references, Footnote_Reference{i, close + 1, note, ordinals[note]})
				i = close + 1
			case ch == '^' && i + 1 < piece.end && source[i + 1] == '[':
				// To the "]" of this "[": brackets in the text count.
				depth, close := 1, i + 2
				for close < piece.end {
					if source[close] == '[' {
						depth += 1
					} else if source[close] == ']' {
						depth -= 1
						if depth == 0 {
							break
						}
					}
					close += 1
				}
				if close >= piece.end || close == i + 2 {
					i += 2
					continue
				}
				numbers += 1
				append(&notes, Footnote{number = numbers, inline = true, start = i, end = close + 1, content = i + 2})
				append(&keys, "")
				append(&ordinals, 1)
				append(&references, Footnote_Reference{i, close + 1, len(notes) - 1, 1})
				i = close + 1
			case:
				i += 1
			}
		}
	}
	return {notes[:], references[:]}
}

// A line that is a definition: its label, and where its text starts in
// the line.
@(private)
footnote_definition :: proc(line: []u8) -> (label: string, mark, content: int, ok: bool) {
	at := 0
	for at < len(line) && at < 3 && (line[at] == ' ' || line[at] == '\t') {
		at += 1
	}
	if at + 2 >= len(line) || line[at] != '[' || line[at + 1] != '^' {
		return
	}
	close := at + 2
	for close < len(line) && line[close] != ']' {
		close += 1
	}
	if close == at + 2 || close + 1 >= len(line) || line[close + 1] != ':' {
		return
	}
	content = close + 2
	for content < len(line) && (line[content] == ' ' || line[content] == '\t') {
		content += 1
	}
	return string(line[at + 2:close]), at, content, true
}

// The block of a footnote of the document: of its definition
// (`reference` 0), or of one of its references, counted from 1 in the
// order of the text. False for none.
note_block :: proc(doc: ^Document, number, reference: int) -> (block: int, ok: bool) {
	seen := 0
	for i in 0 ..< doc.count {
		b := block_at(doc, i)
		if reference == 0 {
			if b.marker == .Note && b.number == number {
				return i, true
			}
			continue
		}
		for &text in block_texts(b) {
			for span in text.spans {
				if .Note in span.style && span.link == number {
					seen += 1
					if seen == reference {
						return i, true
					}
				}
			}
		}
	}
	return 0, false
}

// Appends the text of a footnote of the document to `out`, as plain
// text: the texts of the blocks of its definition, with an empty line
// between two of them, or the text of an inline footnote as it is in
// the source. False for no such footnote.
note_text :: proc(doc: ^Document, number: int, out: ^[dynamic]u8) -> bool {
	if block, defined := note_block(doc, number, 0); defined {
		item := block_at(doc, block).item
		for i := block; i < doc.count; i += 1 {
			b := block_at(doc, i)
			if i > block && (b.item != item || b.spacing != .Continuation) {
				break
			}
			for &text, cell in block_texts(b) {
				if i > block || cell > 0 {
					append(out, cell > 0 ? "\t" : "\n\n")
				}
				append(out, ..text.bytes[:])
			}
		}
		return true
	}
	// An inline footnote has its text only in the source.
	found := footnotes(doc.source, doc.unclosed ? 0 : doc.hidden, context.temp_allocator)
	for note in found.notes {
		if note.inline && note.number == number {
			append(out, ..doc.source[note.content:note.end - 1])
			return true
		}
	}
	return false
}

// True for a block of the definition of a footnote: its first block, or
// a later block of the same list item.
in_note :: proc(doc: ^Document, block: int) -> bool {
	b := block_at(doc, block)
	if b.marker == .Note {
		return true
	}
	if b.item == 0 || b.spacing != .Continuation {
		return false
	}
	for i := block - 1; i >= 0; i -= 1 {
		first := block_at(doc, i)
		if first.item != b.item {
			break
		}
		if first.spacing != .Continuation {
			return first.marker == .Note
		}
	}
	return false
}

// The mark that goes back from the text of a footnote to the place of
// its reference, in the list of the footnotes (`notes_source`).
NOTE_BACK :: "\u21a9\ufe0e"

// The footnotes of a document as the Markdown of a numbered list, in the
// order of their numbers: the text of each (its lines with the indent of
// an item of the list), and a link with `NOTE_BACK` at the end of its
// first paragraph. A page shows it at its end, where a reader looks for
// footnotes. "" for a document with none. The memory is of `allocator`.
notes_source :: proc(doc: ^Document, allocator := context.allocator) -> string {
	found := footnotes(doc.source, doc.unclosed ? 0 : doc.hidden, context.temp_allocator)
	count := 0
	for note in found.notes {
		count = max(count, note.number)
	}
	if count == 0 {
		return ""
	}
	by_number := make([]int, count + 1, context.temp_allocator)
	for note, i in found.notes {
		if note.number > 0 {
			by_number[note.number] = i
		}
	}
	out := strings.builder_make(allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for number in 1 ..= count {
		note := found.notes[by_number[number]]
		clear(&lines)
		if note.inline {
			append(&lines, string(doc.source[note.content:note.end - 1]))
		} else {
			for at := note.content; at < note.end; {
				line_end, next := line_at(doc.source, at)
				line := string(doc.source[at:line_end])
				if at > note.content {
					// With no indent of the definition: a tab, or as many
					// as four spaces.
					if strings.has_prefix(line, "\t") {
						line = line[1:]
					} else {
						for cut := 0; cut < 4 && strings.has_prefix(line, " "); cut += 1 {
							line = line[1:]
						}
					}
				}
				append(&lines, line)
				at = next
			}
			for len(lines) > 0 && strings.trim_space(lines[len(lines) - 1]) == "" {
				pop(&lines)
			}
		}
		// The last line of the first paragraph: the mark goes there.
		last := 0
		for last + 1 < len(lines) && strings.trim_space(lines[last + 1]) != "" {
			last += 1
		}
		prefix := fmt.tprintf("%d. ", number)
		for line, i in lines {
			if i == 0 {
				strings.write_string(&out, prefix)
			} else if strings.trim_space(line) != "" {
				for _ in 0 ..< len(prefix) {
					strings.write_byte(&out, ' ')
				}
			}
			strings.write_string(&out, line)
			if i == last {
				fmt.sbprintf(&out, " [%s](#back)", NOTE_BACK)
			}
			strings.write_byte(&out, '\n')
		}
		if len(lines) == 0 {
			fmt.sbprintf(&out, "%s[%s](#back)\n", prefix, NOTE_BACK)
		}
		strings.write_byte(&out, '\n')
	}
	return strings.to_string(out)
}

// True for bytes that can have a footnote in them: a reference, a
// definition, or an inline footnote. A piece of the source with one is
// parsed with all of the source (`parse_owned`): the number of a footnote
// is of all of its references before it.
has_footnote :: proc(bytes: []u8) -> bool {
	for i in 0 ..< len(bytes) - 1 {
		if (bytes[i] == '[' && bytes[i + 1] == '^') || (bytes[i] == '^' && bytes[i + 1] == '[') {
			return true
		}
	}
	return false
}

// A line that a definition goes on in.
@(private)
footnote_continues :: proc(line: []u8) -> bool {
	if len(line) > 0 && line[0] == '\t' {
		return true
	}
	if len(line) < FOOTNOTE_INDENT {
		return false
	}
	for ch in line[:FOOTNOTE_INDENT] {
		if ch != ' ' {
			return false
		}
	}
	return true
}

// The end of code that starts after a run of `count` backticks at
// `from`: after the next run of exactly as many, in the line. 0 with no
// such run.
@(private)
footnote_code_end :: proc(source: []u8, from, limit, count: int) -> int {
	for i := from; i < limit; {
		if source[i] != '`' {
			i += 1
			continue
		}
		run := i
		for run < limit && source[run] == '`' {
			run += 1
		}
		if run - i == count {
			return run
		}
		i = run
	}
	return 0
}

// The label of a footnote as its references find it: with no spaces
// around it, and in small letters.
@(private)
footnote_key :: proc(label: string) -> string {
	return strings.to_lower(strings.trim_space(label), context.temp_allocator)
}
