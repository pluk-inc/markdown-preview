package document

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:slice"
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
// - Not in code: a reference is one only where the parser reads text
//   (`footnote_confirm`). In a code block, between backticks, or in raw
//   HTML it is what it was.
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
	notes:      []Footnote, // the definitions in the order of the source, then the inline ones in that order
	references: []Footnote_Reference, // in the order of the source
}

// Reads the footnotes of a source from `from` (after what the document
// hides at its start). The memory is of `allocator`.
footnotes :: proc(source: []u8, from: int, allocator := context.allocator) -> (found: Footnotes) {
	start := min(from, len(source))
	// Most sources have none: one look for the two characters.
	if !strings.contains(string(source[start:]), "[^") && !strings.contains(string(source[start:]), "^[") {
		return
	}
	context.allocator = allocator
	// What can be a definition, and the lines of the source: of a
	// possible definition (from where its text starts), or of none. What
	// is code or raw HTML is not known here: the parser says that
	// (`footnote_confirm`), so no rule of it is written a second time.
	Piece :: struct {
		start, end: int,
		of:         int, // the possible definition that the line is of; -1 for none
	}
	possible := make([dynamic]Footnote, context.temp_allocator)
	lines := make([dynamic]Piece, context.temp_allocator)
	for at := start; at < len(source); {
		end, next := line_at(source, at)
		label, mark, content, is_definition := footnote_definition(source[at:end])
		if !is_definition {
			append(&lines, Piece{at, end, -1})
			at = next
			continue
		}
		note := Footnote{label = label, start = at, content = at + content, mark = at + mark}
		append(&lines, Piece{at + content, end, len(possible)})
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
			} else {
				append(&lines, Piece{next, line_end, len(possible)})
			}
			next = after
		}
		note.end = next
		append(&possible, note)
		at = next
	}
	labels := make(map[string]bool, len(possible), context.temp_allocator)
	for note in possible {
		labels[footnote_key(note.label)] = true
	}
	// What can be a reference, in the order of the source. Each line is
	// read one time: the "]" after a place is looked for from where the
	// search before it ended, and the "]" of each "[" of a line is found
	// in one pass when the line has an inline footnote. The character
	// after a backslash is that character and no mark.
	Candidate :: struct {
		start, end: int,
		key:        string, // of its label; "" for an inline footnote
		of:         int, // as of its line
	}
	candidates := make([dynamic]Candidate, context.temp_allocator)
	pairs := make([dynamic]int, context.temp_allocator) // for each byte of a line, where the "]" of its "[" is; 0 for none
	open := make([dynamic]int, context.temp_allocator)
	for piece in lines {
		next_close := piece.start
		paired := false
		for i := piece.start; i < piece.end; {
			ch := source[i]
			switch {
			case ch == '\\':
				i += 2
			case ch == '[' && i + 1 < piece.end && source[i + 1] == '^':
				next_close = max(next_close, i + 2)
				for next_close < piece.end && source[next_close] != ']' {
					next_close += 1
				}
				close := next_close
				if close >= piece.end {
					// No "]" in the rest of the line.
					i = piece.end
					continue
				}
				if close == i + 2 {
					i += 2
					continue
				}
				if key := footnote_key(string(source[i + 2:close])); key in labels {
					append(&candidates, Candidate{i, close + 1, key, piece.of})
				}
				i = close + 1
			case ch == '^' && i + 1 < piece.end && source[i + 1] == '[':
				// To the "]" of this "[": brackets in the text count.
				if !paired {
					paired = true
					clear(&pairs)
					resize(&pairs, piece.end - piece.start)
					clear(&open)
					for at := piece.start; at < piece.end; at += 1 {
						switch source[at] {
						case '\\':
							at += 1
						case '[':
							append(&open, at)
						case ']':
							if len(open) > 0 {
								pairs[pop(&open) - piece.start] = at
							}
						}
					}
				}
				close := pairs[i + 1 - piece.start]
				if close == 0 || close == i + 2 {
					i += 2
					continue
				}
				append(&candidates, Candidate{i, close + 1, "", piece.of})
				i = close + 1
			case:
				i += 1
			}
		}
	}
	// What the parser reads as text decides.
	masks := make([]Footnote_Reference, len(candidates), context.temp_allocator)
	for candidate, i in candidates {
		masks[i] = {candidate.start, candidate.end, 0, 0}
	}
	confirmed, defined := footnote_confirm(source, start, possible[:], masks)
	// The definitions: the ones that the parser reads the text of. The
	// last one of a label is the one of its references.
	notes := make([dynamic]Footnote)
	references := make([dynamic]Footnote_Reference)
	by_key := make(map[string]int, len(possible), context.temp_allocator)
	for note, n in possible {
		if defined[n] {
			by_key[footnote_key(note.label)] = len(notes)
			append(&notes, note)
		}
	}
	// The references, with the numbers in their order. The text of a
	// definition has none.
	numbers := 0
	ordinals := make([dynamic]int, len(notes), context.temp_allocator)
	for candidate, i in candidates {
		if !confirmed[i] || (candidate.of >= 0 && defined[candidate.of]) {
			continue
		}
		note: int
		if candidate.key == "" {
			note = len(notes)
			append(&notes, Footnote{inline = true, start = candidate.start, end = candidate.end, content = candidate.start + 2})
			append(&ordinals, 0)
		} else {
			note = by_key[candidate.key] or_continue
		}
		if notes[note].number == 0 {
			numbers += 1
			notes[note].number = numbers
		}
		ordinals[note] += 1
		append(&references, Footnote_Reference{candidate.start, candidate.end, note, ordinals[note]})
	}
	return {notes[:], references[:]}
}

// The byte that stands for each byte of a reference in what the parser
// gets: no mark of Markdown, so the parser gives a reference as one run
// of text, with no style, entity, or cell of a table that starts in it.
@(private)
FOOTNOTE_MASK :: 0x01

// Changes a copy of a source (from `from` of it) for the parser: the
// "[^" of a definition is the mark of a list item ("+" and a space), so
// a definition can have more than one block, as an item has; and a
// reference is a run of `FOOTNOTE_MASK`.
@(private)
footnote_mask :: proc(masked: []u8, from: int, notes: []Footnote, references: []Footnote_Reference) {
	for note in notes {
		if note.inline {
			continue
		}
		masked[note.mark - from], masked[note.mark - from + 1] = '+', ' '
		// Its label and the "]:" are no Markdown: an entity or a mark of
		// a style in a label does not split it for the parser.
		end := note.content
		for end > note.mark + 2 && (masked[end - 1 - from] == ' ' || masked[end - 1 - from] == '\t') {
			end -= 1
		}
		slice.fill(masked[note.mark + 2 - from:end - from], FOOTNOTE_MASK)
	}
	for reference in references {
		slice.fill(masked[reference.start - from:reference.end - from], FOOTNOTE_MASK)
	}
}

@(private)
Footnote_Confirm :: struct {
	ctx:        runtime.Context,
	base:       uintptr, // of the bytes that the parser reads
	size, from: int,
	references: []Footnote_Reference,
	confirmed:  []bool,
	notes:      []Footnote,
	marks:      []int, // the definitions among the notes, in the order of the source
	defined:    []bool, // for each note
}

// Which of the possible references the parser reads as text, and which
// of the possible definitions it reads the text of: one pass of the
// parser with no document, over the source with each of them masked. The rules of code and of raw HTML are the parser's, so they
// are not written a second time here.
@(private)
footnote_confirm :: proc(source: []u8, from: int, notes: []Footnote, references: []Footnote_Reference) -> (confirmed: []bool, defined: []bool) {
	confirmed = make([]bool, len(references), context.temp_allocator)
	defined = make([]bool, len(notes), context.temp_allocator)
	if len(notes) == 0 && len(references) == 0 {
		return
	}
	marks := make([dynamic]int, context.temp_allocator)
	for note, n in notes {
		if !note.inline {
			append(&marks, n)
		}
	}
	masked := slice.clone(source[from:])
	defer delete(masked)
	footnote_mask(masked, from, notes, references)
	state := Footnote_Confirm{context, uintptr(raw_data(masked)), len(masked), from, references, confirmed, notes, marks[:], defined}
	block :: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int {
		return 0
	}
	span :: proc "c" (type: Md_Span, detail: rawptr, userdata: rawptr) -> c.int {
		return 0
	}
	text :: proc "c" (type: Md_Text, text: [^]u8, size: c.uint, userdata: rawptr) -> c.int {
		state := cast(^Footnote_Confirm)userdata
		context = state.ctx
		if type != .Normal || uintptr(text) < state.base || uintptr(text) >= state.base + uintptr(state.size) {
			return 0
		}
		start := int(uintptr(text) - state.base) + state.from
		end := start + int(size)
		// The first reference that starts in this text.
		low, high := 0, len(state.references)
		for low < high {
			middle := (low + high) / 2
			if state.references[middle].start < start {
				low = middle + 1
			} else {
				high = middle
			}
		}
		for ; low < len(state.references) && state.references[low].end <= end; low += 1 {
			state.confirmed[low] = true
		}
		// The definition whose text starts in this text: after the mark
		// of its item, where its label is.
		low, high = 0, len(state.marks)
		for low < high {
			middle := (low + high) / 2
			if state.notes[state.marks[middle]].mark + 2 < start {
				low = middle + 1
			} else {
				high = middle
			}
		}
		if low < len(state.marks) && state.notes[state.marks[low]].mark + 2 < end {
			state.defined[state.marks[low]] = true
		}
		return 0
	}
	md := Md_Parser {
		flags       = MD_FLAGS,
		enter_block = block,
		leave_block = block,
		enter_span  = span,
		leave_span  = span,
		text        = text,
	}
	// md4c takes a 32-bit size; a larger source is cut there.
	md_parse(raw_data(masked), c.uint(min(len(masked), int(max(c.int)))), &md, &state)
	return
}

// The footnotes of a document: the ones of its last parse of all of the
// source while that is its source, or read again. The memory is of the
// document or of the working memory.
@(private)
document_footnotes :: proc(doc: ^Document) -> Footnotes {
	if doc.notes_valid {
		return doc.notes
	}
	return footnotes(doc.source, doc.unclosed ? 0 : doc.hidden, context.temp_allocator)
}

// A line that is a definition: its label, and where its text starts in
// the line.
@(private)
footnote_definition :: proc(line: []u8) -> (label: string, mark, content: int, ok: bool) {
	at := 0
	// Spaces only: a tab is the indent of a code block.
	for at < len(line) && at < 3 && line[at] == ' ' {
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
	// 0 is the number of a definition that no reference has.
	if number <= 0 {
		return 0, false
	}
	if reference == 0 {
		for i in 0 ..< doc.count {
			if b := block_at(doc, i); b.marker == .Note && b.number == number {
				return i, true
			}
		}
		return 0, false
	}
	// From the source, and not from the numbers in the texts: a reference
	// with the caret in it shows as its source, and is still the
	// reference that it was.
	found := document_footnotes(doc)
	for r in found.references {
		if r.ordinal == reference && found.notes[r.note].number == number && doc.count > 0 {
			return block_at_offset(doc, r.start), true
		}
	}
	return 0, false
}

// Appends the text of a footnote of the document to `out`, as plain
// text: the texts of the blocks of its definition, with an empty line
// between two of them, or the text of an inline footnote as it is in
// the source. False for no such footnote.
note_text :: proc(doc: ^Document, number: int, out: ^[dynamic]u8) -> bool {
	if number <= 0 {
		return false
	}
	if block, defined := note_block(doc, number, 0); defined {
		for i in block ..< note_end(doc, block) {
			b := block_at(doc, i)
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
	found := document_footnotes(doc)
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
	return block_at(doc, block).noted
}

// The block after the last block of the definition that starts at
// `block`: the later blocks of its item, and the lists in its text.
@(private)
note_end :: proc(doc: ^Document, block: int) -> int {
	end := block + 1
	for end < doc.count {
		b := block_at(doc, end)
		if !b.noted || (b.list_depth == 1 && b.spacing != .Continuation) {
			break
		}
		end += 1
	}
	return end
}

// The mark that goes back from the text of a footnote to the place of
// its reference, in the list of the footnotes (`notes_source`).
NOTE_BACK :: "\u21a9\ufe0e"

// Where its link goes: no place of a file, only a name for this link.
NOTE_BACK_TARGET :: "#back"

// The footnotes of a document as the Markdown of a numbered list, in the
// order of their numbers: the text of each (its lines with the indent of
// an item of the list), and a link with `NOTE_BACK` at the end of its
// first paragraph. A page shows it at its end, where a reader looks for
// footnotes. "" for a document with none. The memory is of `allocator`.
notes_source :: proc(doc: ^Document, allocator := context.allocator) -> string {
	found := document_footnotes(doc)
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
	// The first block of each definition, from one pass of the blocks.
	first_block := make([]int, count + 1, context.temp_allocator)
	for i in 0 ..< doc.count {
		if b := block_at(doc, i); b.marker == .Note && b.number > 0 && b.number <= count {
			first_block[b.number] = i + 1
		}
	}
	out := strings.builder_make(allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for number in 1 ..= count {
		note := found.notes[by_number[number]]
		clear(&lines)
		// The mark that goes back is at the end of the first paragraph.
		// A text that starts with a fence of code or a table has it in a
		// paragraph of its own after the text: no line of those can have
		// more text.
		apart := false
		if note.inline {
			append(&lines, string(doc.source[note.content:note.end - 1]))
		} else {
			// The lines of the blocks that the parser has in the
			// definition: a line with no indent right after a paragraph
			// of it goes on in that paragraph.
			end := note.end
			if first := first_block[number] - 1; first >= 0 {
				after := note_end(doc, first)
				end = after < doc.count ? block_start(doc, after) : len(doc.source)
				// But for the definitions of links after its last block,
				// which are no block.
				last := block_start(doc, after - 1)
				for def in doc.defs {
					if def.start > last && def.start < end {
						end = def.start
						break
					}
				}
			}
			for at := note.content; at < end; {
				line_end, next := line_at(doc.source, at)
				line := string(doc.source[at:line_end])
				if at > note.content {
					// With no indent of the item that the definition is
					// for the parser (`FOOTNOTE_INDENT` columns; a tab is
					// four): what is left of the indent is of the text,
					// as it is in its place (a list in it, code).
					if strings.has_prefix(line, "\t") {
						line = strings.concatenate({"  ", line[1:]}, context.temp_allocator)
					} else {
						for cut := 0; cut < FOOTNOTE_INDENT && strings.has_prefix(line, " "); cut += 1 {
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
			if len(lines) > 0 {
				first := strings.trim_space(lines[0])
				apart = strings.has_prefix(first, "```") || strings.has_prefix(first, "~~~") || strings.has_prefix(first, "|")
			}
		}
		// The last line of the first paragraph: the mark goes there. A
		// fence of code right after it starts another block.
		last := apart ? -1 : 0
		for !apart && last + 1 < len(lines) {
			next := strings.trim_space(lines[last + 1])
			if next == "" || strings.has_prefix(next, "```") || strings.has_prefix(next, "~~~") {
				break
			}
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
				fmt.sbprintf(&out, " [%s](%s)", NOTE_BACK, NOTE_BACK_TARGET)
			}
			strings.write_byte(&out, '\n')
		}
		if len(lines) == 0 {
			fmt.sbprintf(&out, "%s[%s](%s)\n", prefix, NOTE_BACK, NOTE_BACK_TARGET)
		} else if apart {
			// A fence that nothing closes would have the mark as code.
			if first := strings.trim_space(lines[0]); first[0] != '|' {
				run := 0
				for run < len(first) && first[run] == first[0] {
					run += 1
				}
				closed := false
				for line in lines[1:] {
					end := strings.trim_space(line)
					closed ||= len(end) >= run && strings.trim_left(end, first[:1]) == ""
				}
				if !closed {
					for _ in 0 ..< len(prefix) {
						strings.write_byte(&out, ' ')
					}
					strings.write_string(&out, first[:run])
					strings.write_byte(&out, '\n')
				}
			}
			strings.write_byte(&out, '\n')
			for _ in 0 ..< len(prefix) {
				strings.write_byte(&out, ' ')
			}
			fmt.sbprintf(&out, "[%s](%s)\n", NOTE_BACK, NOTE_BACK_TARGET)
		}
		strings.write_byte(&out, '\n')
	}
	// The definitions of links of the document, for a link of a text
	// that uses one.
	for def in doc.defs {
		strings.write_string(&out, strings.trim_right(string(doc.source[def.start:min(def.end, len(doc.source))]), "\r\n"))
		strings.write_string(&out, "\n")
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

// The label of a footnote as its references find it: with no spaces
// around it, and in small letters.
@(private)
footnote_key :: proc(label: string) -> string {
	return strings.to_lower(strings.trim_space(label), context.temp_allocator)
}
