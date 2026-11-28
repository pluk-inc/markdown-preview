package document

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:fmt"
import "core:mem"
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
	note:       int, // in the footnotes; -1 among the ones of a piece, for a definition that is not in the piece
	ordinal:    int, // from 1: which reference of its footnote it is
	number:     int, // of its footnote
}

Footnotes :: struct {
	notes:      []Footnote, // the definitions in the order of the source, then the inline ones in that order
	references: []Footnote_Reference, // in the order of the source
	// Where a line that has the form of a definition starts and is none
	// (in a code block, in raw HTML), in the order of the source. A
	// reference can have its label, and is none.
	dead:       []int,
	// What the parser gets in the place of the source (`footnote_mask`):
	// the same bytes for the pass that says what is a footnote and for
	// the parse, so the two read the same blocks. `bullet` is the mark of
	// the list item that a definition is for the parser; `bullet_free`:
	// no line of the source starts with that mark, so no list of the
	// source takes a definition as its item.
	bullet:      u8,
	bullet_free: bool,
	// How many lines of the source start with each of `BULLETS`: a
	// change of a piece that makes another mark the free one is a parse
	// of all (`bullet_after`).
	bullet_lines: [3]int,
	items:       []int, // where the two bytes of that mark go
	masks:       [][2]int, // the ranges of `FOOTNOTE_MASK`
	// The labels of the `dead` ones, for the caller that keeps the
	// labels of a document. Strings of the source.
	dead_labels: []string,
}

// Reads the footnotes of a source from `from` (after what the document
// hides at its start). The memory is of `allocator`.
footnotes :: proc(source: []u8, from: int, allocator := context.allocator) -> (found: Footnotes) {
	start := min(from, len(source))
	// Most sources have none: one look for the two characters.
	if !has_footnote(source[start:]) {
		return
	}
	// Working memory of this call only: a parse can run with no working
	// memory that someone frees (`prepare`, beside the frames).
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	scan := footnote_scan(source, start, len(source), nil, 0, {start, len(source)})
	possible, candidates, confirmed, defined := scan.possible, scan.candidates, scan.confirmed, scan.defined
	context.allocator = allocator
	found.bullet, found.bullet_free, found.bullet_lines = scan.bullet, scan.used[bullet_index(scan.bullet)] == 0, scan.used
	found.items, found.masks = slice.clone(scan.items), slice.clone(scan.masks)
	dead := make([dynamic]int)
	dead_labels := make([dynamic]string)
	for note, n in possible {
		if !defined[n] {
			append(&dead, note.start)
			append(&dead_labels, note.label)
		}
	}
	found.dead, found.dead_labels = dead[:], dead_labels[:]
	// The definitions: the ones that the parser reads the text of. The
	// last one of a label is the one of its references.
	notes := make([dynamic]Footnote)
	references := make([dynamic]Footnote_Reference)
	by_key := make(map[string]int, len(possible), context.temp_allocator)
	for note, n in possible {
		if defined[n] {
			by_key[footnote_key(note.label)] = len(notes)
			kept := note
			// Where a definition ends is of the blocks of the document
			// (`note_end`), not of these lines.
			kept.end = 0
			append(&notes, kept)
		}
	}
	// The references, with the numbers in their order. The text of a
	// definition has none.
	numbers := 0
	ordinals := make([dynamic]int, len(notes), context.temp_allocator)
	for candidate, i in candidates {
		if !confirmed[i] || scan.inside[i] || (candidate.of >= 0 && defined[candidate.of]) {
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
		append(&references, Footnote_Reference{candidate.start, candidate.end, note, ordinals[note], notes[note].number})
	}
	found.notes, found.references = notes[:], references[:]
	return
}

// What can be a reference: "[^label]" with a label that a definition
// can have, or "^[text]".
@(private)
Footnote_Candidate :: struct {
	start, end: int,
	key:        string, // of its label; "" for an inline footnote
	of:         int, // the possible definition whose text it is in; -1 for none
	// It can start or end in code (a backtick in it) or be in the target
	// of a link (after "](" or "]:"): `footnote_out_of_code` asks the
	// parser.
	doubt:      bool,
}

// What a part of a source has that can be a footnote, and what the
// parser says of each: the working memory has all of it.
@(private)
Footnote_Scan :: struct {
	possible:   []Footnote, // what can be a definition, in the order of the source
	defined:    []bool, // for each: the parser reads its text
	candidates: []Footnote_Candidate, // in the order of the source
	confirmed:  []bool, // for each: the parser reads it as text
	inside:     []bool, // for each: in the text of a definition, as the parser has its blocks
	// As in `Footnotes`. `used`: how many lines start with each of
	// `BULLETS`.
	bullet:     u8,
	used:       [3]int,
	items:      []int,
	masks:      [][2]int,
}

// The marks of a list item that a definition can be for the parser.
@(private)
BULLETS :: [3]u8{'+', '-', '*'}

// Which of `BULLETS` a line starts with, after an indent and the marks
// of a quote: the mark of a list item. -1 for none.
@(private)
line_bullet :: proc(source: []u8, at, end: int) -> int {
	lead := at
	for lead < end && (source[lead] == ' ' || source[lead] == '\t' || source[lead] == '>') {
		lead += 1
	}
	if lead < end && (lead + 1 == end || source[lead + 1] == ' ' || source[lead + 1] == '\t') {
		for mark, i in BULLETS {
			if source[lead] == mark {
				return i
			}
		}
	}
	return -1
}

// The mark for the definitions of a source whose lines start with each
// of `BULLETS` so many times: the first that no line has, or the first.
@(private)
bullet_choice :: proc(lines: [3]int) -> u8 {
	for mark, i in BULLETS {
		if lines[i] == 0 {
			return mark
		}
	}
	return BULLETS[0]
}

// For a change of a piece of a document with definitions: how many
// lines start with each of `BULLETS` after it, when `was` is the piece
// before and `now` the piece after. False when the mark of the
// definitions would be another one then: all of the source is parsed.
@(private)
bullet_after :: proc(doc: ^Document, was, now: []u8) -> (lines: [3]int, ok: bool) {
	count :: proc(bytes: []u8, lines: ^[3]int, by: int) {
		for at := 0; at < len(bytes); {
			end, next := line_at(bytes, at)
			if mark := line_bullet(bytes, at, end); mark >= 0 {
				lines[mark] += by
			}
			at = next
		}
	}
	lines = doc.notes.bullet_lines
	count(was, &lines, -1)
	count(now, &lines, 1)
	return lines, bullet_choice(lines) == doc.notes.bullet
}

@(private)
bullet_index :: proc(bullet: u8) -> int {
	for mark, i in BULLETS {
		if mark == bullet {
			return i
		}
	}
	return 0
}

// Reads `source` from `start` to `limit` for what can be a footnote.
// `known`: the labels that a reference can have, for a piece of a
// document; with none, the labels of the definitions that are found.
// `bullet`: the mark of the list item that a definition is for the
// parser, for a piece of a document; 0 for the first of `BULLETS` that
// no line starts with (a list of the source with the same mark would
// take the definition as its item). `around`: the range of the source
// that the parser reads in its passes, which is the range that is read
// here or more (the text of a piece has definitions of links around it).
@(private)
footnote_scan :: proc(source: []u8, start, limit: int, known: ^map[string]int, bullet: u8, around: [2]int) -> Footnote_Scan {
	// What can be a definition, and the lines of the source: of a
	// possible definition (from where its text starts), or of none. What
	// is code or raw HTML is not known here: the parser says that
	// (`footnote_confirm`), so no rule of it is written a second time.
	Piece :: struct {
		start, end: int,
		of:         int, // the possible definition that the line is of; -1 for none
	}
	scan: Footnote_Scan
	possible := make([dynamic]Footnote, context.temp_allocator)
	lines := make([dynamic]Piece, context.temp_allocator)
	for at := start; at < limit; {
		end, next := line_at(source, at)
		end, next = min(end, limit), min(next, limit)
		if mark := line_bullet(source, at, end); mark >= 0 {
			scan.used[mark] += 1
		}
		label, mark, content, is_definition := footnote_definition(source[at:end])
		if !is_definition {
			append(&lines, Piece{at, end, -1})
			at = next
			continue
		}
		note := Footnote{label = label, start = at, content = at + content, mark = at + mark}
		append(&lines, Piece{at + content, end, len(possible)})
		// The lines that it goes on in.
		for next < limit {
			line_end, after := line_at(source, next)
			line_end, after = min(line_end, limit), min(after, limit)
			following := source[next:line_end]
			if strings.trim(string(following), " \t") == "" {
				// An empty line: only before a line that goes on.
				if after >= limit {
					break
				}
				second_end, _ := line_at(source, after)
				second_end = min(second_end, limit)
				if !footnote_continues(source[after:second_end], mark) {
					break
				}
			} else if !footnote_continues(following, mark) {
				break
			} else {
				append(&lines, Piece{next, line_end, len(possible)})
				// Each line of the source counts, as in `bullet_after`.
				if mark := line_bullet(source, next, line_end); mark >= 0 {
					scan.used[mark] += 1
				}
			}
			next = after
		}
		note.end = next
		append(&possible, note)
		at = next
	}
	// The labels that a reference can have: of the possible definitions
	// here, or the ones that the caller knows (of a document, for a
	// piece of it).
	own := make(map[string]int, len(possible), context.temp_allocator)
	labels := known
	if labels == nil {
		for note in possible {
			own[footnote_key(note.label)] = 0
		}
		labels = &own
	}
	// What can be a reference, in the order of the source. Each line is
	// read one time: the "]" after a place is looked for from where the
	// search before it ended, and the "]" of each "[" of a line is found
	// in one pass when the line has an inline footnote. The character
	// after a backslash is that character and no mark.
	candidates := make([dynamic]Footnote_Candidate, context.temp_allocator)
	pairs := make([dynamic]int, context.temp_allocator) // for each byte of a line, where the "]" of its "[" is; 0 for none
	open := make([dynamic]int, context.temp_allocator)
	for piece in lines {
		next_close, next_open := piece.start, piece.start
		paired := false
		// After "](" to the ")", and after "]:": what can be the target
		// of a link.
		target := false
		for i := piece.start; i < piece.end; {
			ch := source[i]
			if ch == ']' && i + 1 < piece.end && (source[i + 1] == '(' || source[i + 1] == ':') {
				target = true
			} else if ch == ')' {
				target = false
			}
			switch {
			case ch == '\\':
				i += 2
			case ch == '[' && i + 1 < piece.end && source[i + 1] == '^':
				next_close = max(next_close, i + 2)
				for next_close < piece.end && source[next_close] != ']' {
					next_close += 1
				}
				close := next_close
				// A label has no "[": with one before the "]", this
				// "[^" is text. Looked for as the "]" is, so a line of
				// many "[^" is read one time.
				next_open = max(next_open, i + 2)
				for next_open < close && source[next_open] != '[' {
					next_open += 1
				}
				if next_open < close {
					i += 2
					continue
				}
				if close >= piece.end {
					// No "]" in the rest of the line.
					i = piece.end
					continue
				}
				if close == i + 2 {
					i += 2
					continue
				}
				// A label of only spaces is none. With no definition that
				// has the label, the "[^" is text, and what is after it
				// is read for itself (an inline footnote can be there).
				key := footnote_key(string(source[i + 2:close]))
				if key == "" || key not_in labels^ {
					i += 2
					continue
				}
				append(&candidates, Footnote_Candidate{i, close + 1, key, piece.of, target || bytes.index_byte(source[i:close], '`') >= 0})
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
				append(&candidates, Footnote_Candidate{i, close + 1, "", piece.of, target || bytes.index_byte(source[i:close], '`') >= 0})
				i = close + 1
			case:
				i += 1
			}
		}
	}
	scan.possible = possible[:]
	footnote_out_of_code(source, around[0], around[1], &scan, &candidates)
	scan.bullet = bullet
	if bullet == 0 {
		scan.bullet = BULLETS[0]
		scan.bullet = bullet_choice(scan.used)
	}
	// What the parser gets in the place of these: the "[^" of each
	// possible definition is the mark of a list item, so a definition
	// can have more than one block, as an item has; its label and the
	// "]:" are no Markdown; and each possible reference is no Markdown,
	// so the parser gives it as one run of text.
	items := make([dynamic]int, context.temp_allocator)
	masks := make([dynamic][2]int, context.temp_allocator)
	for note in possible {
		append(&items, note.mark)
		end := note.content
		for end > note.mark + 2 && (source[end - 1] == ' ' || source[end - 1] == '\t') {
			end -= 1
		}
		append(&masks, [2]int{note.mark + 2, end})
	}
	for candidate in candidates {
		append(&masks, [2]int{candidate.start, candidate.end})
	}
	scan.possible, scan.candidates = possible[:], candidates[:]
	scan.items, scan.masks = items[:], masks[:]
	// What the parser reads as text decides.
	scan.confirmed, scan.defined = footnote_confirm(source, around[0], around[1], &scan)
	return scan
}

// Takes out each possible reference that starts or ends in code, or is
// in the target of a link: one whose first or last byte the parser
// reads as no text in the source as it is. With its bytes masked, the
// backtick that ends the code would go, and the parser would read text
// there; and a target with the mask in it is no target. Only a
// candidate with a backtick in it, or after "](" or "]:" in its line,
// is in doubt: most sources have none, and this is one look at the
// candidates then.
@(private)
footnote_out_of_code :: proc(source: []u8, start, limit: int, scan: ^Footnote_Scan, candidates: ^[dynamic]Footnote_Candidate) {
	ends := make([dynamic]int, context.temp_allocator) // the first and the last byte of each such candidate, in the order of the source
	for candidate in candidates {
		if candidate.doubt {
			append(&ends, candidate.start, candidate.end - 1)
		}
	}
	if len(ends) == 0 {
		return
	}
	State :: struct {
		ctx:        runtime.Context,
		base:       uintptr,
		size, from: int,
		ends:       []int,
		text:       []bool, // for each of `ends`: the parser reads it as text
	}
	// The bytes of the other pass, but for the candidates that are in
	// doubt, which are as they are in the source. Each other candidate
	// is masked here too: as it is, a "[^label]:" in a quote is the
	// definition of a link for the parser, and then what is a link at
	// another place of the source changes with it.
	masked := slice.clone(source[start:limit])
	defer delete(masked)
	for note in scan.possible {
		masked[note.mark - start], masked[note.mark - start + 1] = BULLETS[0], ' '
		end := note.content
		for end > note.mark + 2 && (source[end - 1] == ' ' || source[end - 1] == '\t') {
			end -= 1
		}
		slice.fill(masked[note.mark + 2 - start:end - start], FOOTNOTE_MASK)
	}
	for candidate in candidates {
		if !candidate.doubt {
			slice.fill(masked[candidate.start - start:candidate.end - start], FOOTNOTE_MASK)
		}
	}
	state := State{context, uintptr(raw_data(masked)), len(masked), start, ends[:], make([]bool, len(ends), context.temp_allocator)}
	block :: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int {
		return 0
	}
	span :: proc "c" (type: Md_Span, detail: rawptr, userdata: rawptr) -> c.int {
		return 0
	}
	text :: proc "c" (type: Md_Text, text: [^]u8, size: c.uint, userdata: rawptr) -> c.int {
		state := cast(^State)userdata
		context = state.ctx
		if type != .Normal || uintptr(text) < state.base || uintptr(text) >= state.base + uintptr(state.size) {
			return 0
		}
		from := int(uintptr(text) - state.base) + state.from
		low, high := 0, len(state.ends)
		for low < high {
			middle := (low + high) / 2
			if state.ends[middle] < from {
				low = middle + 1
			} else {
				high = middle
			}
		}
		for ; low < len(state.ends) && state.ends[low] < from + int(size); low += 1 {
			state.text[low] = true
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
	md_parse(raw_data(masked), c.uint(min(len(masked), int(max(c.int)))), &md, &state)
	kept, at := 0, 0
	for candidate in candidates {
		if at < len(ends) && ends[at] == candidate.start {
			at += 2
			if !state.text[at - 2] || !state.text[at - 1] {
				continue
			}
		}
		candidates[kept] = candidate
		kept += 1
	}
	resize(candidates, kept)
}

// The byte that stands for each byte of a reference in what the parser
// gets: no mark of Markdown, so the parser gives a reference as one run
// of text, with no style, entity, or cell of a table that starts in it.
@(private)
FOOTNOTE_MASK :: 0x01

// Changes a copy of a source (from `from` of it) for the parser: the
// two bytes of the mark of a list item at each of `items`, and
// `FOOTNOTE_MASK` in each of `masks`.
@(private)
footnote_mask :: proc(masked: []u8, from: int, bullet: u8, items: []int, masks: [][2]int) {
	for item in items {
		masked[item - from], masked[item - from + 1] = bullet, ' '
	}
	for mask in masks {
		slice.fill(masked[mask[0] - from:mask[1] - from], FOOTNOTE_MASK)
	}
}

@(private)
Footnote_Confirm :: struct {
	ctx:        runtime.Context,
	base:       uintptr, // of the bytes that the parser reads
	size, from: int,
	references: []Footnote_Candidate,
	confirmed:  []bool,
	notes:      []Footnote, // what can be a definition, in the order of the source
	defined:    []bool, // for each of them
	inside:     []bool, // for each reference: in the text of a definition
	items:      int, // the items of lists that are open
	definition: int, // which of them is a definition, counted from 1; 0 for none
}

// Which of the possible references the parser reads as text, and which
// of the possible definitions it reads the text of: one pass of the
// parser with no document, over the source with each of them masked. The rules of code and of raw HTML are the parser's, so they
// are not written a second time here.
@(private)
footnote_confirm :: proc(source: []u8, from, limit: int, scan: ^Footnote_Scan) -> (confirmed: []bool, defined: []bool) {
	notes, references := scan.possible, scan.candidates
	confirmed = make([]bool, len(references), context.temp_allocator)
	defined = make([]bool, len(notes), context.temp_allocator)
	scan.inside = make([]bool, len(references), context.temp_allocator)
	if len(notes) == 0 && len(references) == 0 {
		return
	}
	masked := slice.clone(source[from:limit])
	defer delete(masked)
	footnote_mask(masked, from, scan.bullet, scan.items, scan.masks)
	state := Footnote_Confirm{context, uintptr(raw_data(masked)), len(masked), from, references, confirmed, notes, defined, scan.inside, 0, 0}
	// The items of lists that are open, and which of them is a
	// definition: the text of a definition has no footnote, also in a
	// line that goes on in its paragraph with no indent.
	enter :: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int {
		state := cast(^Footnote_Confirm)userdata
		state.items += int(type == .Li)
		return 0
	}
	leave :: proc "c" (type: Md_Block, detail: rawptr, userdata: rawptr) -> c.int {
		state := cast(^Footnote_Confirm)userdata
		if type == .Li {
			if state.items == state.definition {
				state.definition = 0
			}
			state.items -= 1
		}
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
		// The definition whose text starts in this text: after the mark
		// of its item, where its label is.
		if at := definition_at_label(state.notes, start); at < len(state.notes) && state.notes[at].mark + 2 < end {
			state.defined[at] = true
			state.definition = state.items
		}
		// From the first reference that starts in this text.
		for at := candidate_from(state.references, start); at < len(state.references) && state.references[at].end <= end; at += 1 {
			state.confirmed[at] = true
			state.inside[at] = state.definition > 0
		}
		return 0
	}
	md := Md_Parser {
		flags       = MD_FLAGS,
		enter_block = enter,
		leave_block = leave,
		enter_span  = span,
		leave_span  = span,
		text        = text,
	}
	// md4c takes a 32-bit size; a larger source is cut there.
	md_parse(raw_data(masked), c.uint(min(len(masked), int(max(c.int)))), &md, &state)
	return
}

// The footnotes of a document: each parse of all of its source reads
// them, and each change of a piece moves them (`notes_commit`).
@(private)
document_footnotes :: proc(doc: ^Document) -> Footnotes {
	return doc.notes
}

@(private)
notes_destroy :: proc(notes: ^Footnotes) {
	delete(notes.notes)
	delete(notes.references)
	delete(notes.dead)
	delete(notes.items)
	delete(notes.masks)
	delete(notes.dead_labels)
	notes^ = {}
}

@(private)
note_keys_destroy :: proc(doc: ^Document) {
	for key in doc.note_keys {
		delete(key)
	}
	delete(doc.note_keys)
	doc.note_keys = nil
}

// How many of the footnotes of a document are definitions: they are the
// first of them, in the order of the source.
@(private)
definition_count :: proc(notes: []Footnote) -> (count: int) {
	for count < len(notes) && !notes[count].inline {
		count += 1
	}
	return
}

// The first of the definitions, and of the references, that starts at
// an offset of the source or after it.
@(private)
definition_from :: proc(notes: []Footnote, offset: int) -> int {
	low, high := 0, len(notes)
	for low < high {
		middle := (low + high) / 2
		if notes[middle].start < offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

// The first of the definitions whose label (after the "[^" of its mark)
// is at an offset of the source or after it.
@(private)
definition_at_label :: proc(notes: []Footnote, offset: int) -> int {
	low, high := 0, len(notes)
	for low < high {
		middle := (low + high) / 2
		if notes[middle].mark + 2 < offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

@(private)
candidate_from :: proc(candidates: []Footnote_Candidate, offset: int) -> int {
	low, high := 0, len(candidates)
	for low < high {
		middle := (low + high) / 2
		if candidates[middle].start < offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

@(private)
reference_from :: proc(references: []Footnote_Reference, offset: int) -> int {
	low, high := 0, len(references)
	for low < high {
		middle := (low + high) / 2
		if references[middle].start < offset {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

// The footnotes of a piece of the source of a document, for a parse of
// the piece alone: `text[from:to]` is the piece as it is now, and
// `old_start` to `old_end` is where it was in the source of the
// document. True when the piece has the footnotes that it had: the same
// definitions, and the same references in the same order. Then no
// number of the document changes, and the result has the numbers of the
// document, with offsets of `text`: the definitions of the piece, and
// its references. False for a piece whose
// footnotes are others (a parse of all of the source is right then).
// The memory is of `allocator`.
piece_footnotes :: proc(doc: ^Document, text: []u8, from, to: int, old_start, old_end: int, allocator := context.allocator) -> (found: Footnotes, ok: bool) {
	// At the start of a source with front matter, all is parsed: the
	// bytes that the document hides are no Markdown.
	if old_start == 0 && doc.hidden > 0 {
		return
	}
	// Working memory of this call only, as in `footnotes`.
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch)
	defer mem.dynamic_arena_destroy(&scratch)
	context.temp_allocator = mem.dynamic_arena_allocator(&scratch)
	old := doc.notes
	// The definitions and the references that the piece had.
	definitions := old.notes[:definition_count(old.notes)]
	d0, d1 := definition_from(definitions, old_start), definition_from(definitions, old_end)
	r0, r1 := reference_from(old.references, old_start), reference_from(old.references, old_end)
	// A line that has the form of a definition and is none, in the piece
	// before or now: the labels that a reference can have are others
	// then, in all of the source.
	for start in old.dead {
		if start >= old_start && start < old_end {
			return
		}
	}
	// The parser reads all of the text of the piece: the definitions of
	// links around the piece are in it, and a link is one for it as in
	// a parse of all of the source.
	scan := footnote_scan(text, from, to, &doc.note_keys, old.bullet, {0, len(text)})
	notes := make([dynamic]Footnote, allocator)
	references := make([dynamic]Footnote_Reference, allocator)
	defer if !ok {
		delete(notes)
		delete(references)
	}
	// The definitions: each is the one that was at its place.
	for note, n in scan.possible {
		if !scan.defined[n] {
			return
		}
		at := d0 + len(notes)
		if at >= d1 || (doc.note_keys[footnote_key(note.label)] or_return) != at {
			return
		}
		kept := note
		kept.label, kept.number, kept.end = "", old.notes[at].number, 0
		append(&notes, kept)
	}
	if len(notes) != d1 - d0 {
		return
	}
	// The references: each is of the footnote that the one at its place
	// was of, with the number of that one.
	count := 0
	for candidate, i in scan.candidates {
		if !scan.confirmed[i] || scan.inside[i] || (candidate.of >= 0 && scan.defined[candidate.of]) {
			continue
		}
		// The label of a line that is no definition: no reference.
		if candidate.key != "" && doc.note_keys[candidate.key] < 0 {
			continue
		}
		if r0 + count >= r1 {
			return
		}
		was := old.references[r0 + count]
		of := old.notes[was.note]
		if candidate.key == "" {
			if !of.inline {
				return
			}
		} else if of.inline || (doc.note_keys[candidate.key] or_return) != was.note {
			return
		}
		in_piece := was.note >= d0 && was.note < d1
		append(&references, Footnote_Reference{candidate.start, candidate.end, in_piece ? was.note - d0 : -1, was.ordinal, was.number})
		count += 1
	}
	if count != r1 - r0 {
		return
	}
	found = {notes = notes[:], references = references[:], bullet = scan.bullet}
	found.items, found.masks = slice.clone(scan.items, allocator), slice.clone(scan.masks, allocator)
	return found, true
}

// After a change of a piece of the source: the footnotes of the document
// with the offsets of the new source. `piece` is what `piece_footnotes`
// gave for the piece (nothing for a piece with no footnote), `base` is
// where its offsets count from in the new source, `old_start` is where
// the piece was, and the source is `grown` bytes longer from `edit_end`
// on.
@(private)
notes_commit :: proc(doc: ^Document, piece: Footnotes, base, old_start, edit_end, grown: int) {
	notes, references := doc.notes.notes, doc.notes.references
	definitions := definition_count(notes)
	// The ones of the piece are where the piece has them now: they are
	// the same ones in the same order. Found by where they were, so
	// before the others move.
	d := definition_from(notes[:definitions], old_start)
	r := reference_from(references, old_start)
	// The ones after the edit are that much later. The definitions, the
	// inline footnotes, and the references are each in the order of the
	// source: the ones before the edit are not looked at.
	later :: proc(notes: []Footnote, edit_end, grown: int) {
		for &note in notes[definition_from(notes, edit_end):] {
			note.start += grown
			note.content += grown
			// A mark is of a definition, and an end of an inline
			// footnote.
			note.mark += note.inline ? 0 : grown
			note.end += note.inline ? grown : 0
		}
	}
	later(notes[:definitions], edit_end, grown)
	later(notes[definitions:], edit_end, grown)
	for &reference in references[reference_from(references, edit_end):] {
		reference.start += grown
		reference.end += grown
	}
	for &start in doc.notes.dead {
		start += start >= edit_end ? grown : 0
	}
	for note in piece.notes {
		number := notes[d].number
		notes[d] = note
		notes[d].number = number
		notes[d].start += base
		notes[d].content += base
		notes[d].mark += base
		d += 1
	}
	for reference in piece.references {
		was := &references[r]
		was.start, was.end = reference.start + base, reference.end + base
		if of := &notes[was.note]; of.inline {
			of.start, of.end, of.content = was.start, was.end, was.start + 2
		}
		r += 1
	}
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
		// A label has no "[" (as for a reference).
		if line[close] == '[' {
			return
		}
		close += 1
	}
	// A label of only spaces is none.
	if close == at + 2 || close + 1 >= len(line) || line[close + 1] != ':' || strings.trim_space(string(line[at + 2:close])) == "" {
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
		// The definitions are few beside the blocks.
		for note in doc.notes.notes {
			if note.inline {
				break
			}
			if note.number == number && doc.count > 0 {
				return block_at_offset(doc, note.start), true
			}
		}
		return 0, false
	}
	// From the source, and not from the numbers in the texts: a reference
	// with the caret in it shows as its source, and is still the
	// reference that it was.
	found := document_footnotes(doc)
	for r in found.references {
		if r.ordinal == reference && r.number == number && doc.count > 0 {
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
		if !b.noted || (b.marker == .Note && b.spacing != .Continuation) {
			break
		}
		end += 1
	}
	return end
}

// True for bytes that can have a footnote in them: a reference, a
// definition, or an inline footnote. A change of a piece with none has
// nothing to ask of the footnotes of the document (`piece_footnotes`).
has_footnote :: proc(source: []u8) -> bool {
	// Each of the forms has a "^", which most text has none of: the
	// search for that byte is the fast one of the library, and a parse
	// of a source with no footnote pays little for this.
	for at := 0; at < len(source); {
		found := bytes.index_byte(source[at:], '^')
		if found < 0 {
			return false
		}
		at += found
		if (at > 0 && source[at - 1] == '[') || (at + 1 < len(source) && source[at + 1] == '[') {
			return true
		}
		at += 1
	}
	return false
}

// A line that a definition goes on in.
@(private)
footnote_continues :: proc(line: []u8, lead: int) -> bool {
	// As far in as the text of the item that the definition is for the
	// parser: its indent and `FOOTNOTE_INDENT` columns. A tab goes to the
	// next column that is a multiple of four, as for the parser.
	columns := 0
	for ch in line {
		switch ch {
		case ' ':
			columns += 1
		case '\t':
			columns = (columns / 4 + 1) * 4
		case:
			return columns >= lead + FOOTNOTE_INDENT
		}
		if columns >= lead + FOOTNOTE_INDENT {
			return true
		}
	}
	return false
}

// The label of a footnote as its references find it: with no spaces
// around it, and in small letters.
@(private)
footnote_key :: proc(label: string, allocator := context.temp_allocator) -> string {
	return strings.to_lower(strings.trim_space(label), allocator)
}
