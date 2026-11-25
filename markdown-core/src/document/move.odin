package document

import "core:bytes"
import "core:unicode"
import "core:unicode/utf8"

// The steps of a caret through the text of a document, from one address
// to the next one. They need no layout: a step to the line above or
// below does, and is in the layout.

// How far a step goes.
Step :: enum {
	Character,
	Word,
}

// The end of the character that starts at a byte of a text, or the
// start of the one that ends there: a letter with the marks that go on
// it, the parts of an emoji, and the like are one character. The same
// byte at an end of the text.
char_step :: proc(text: []u8, at: int, forward: bool) -> int {
	at := clamp(at, 0, len(text))
	if forward ? at >= len(text) : at <= 0 {
		return at
	}
	// A character of ASCII between two others of ASCII is a character of
	// its own: no mark goes on it from behind, and nothing before it
	// takes it in. Most steps read three bytes. A line break is such a
	// character each time.
	if forward {
		if text[at] == '\n' || (text[at] < 0x80 && (at + 1 == len(text) || text[at + 1] < 0x80)) {
			return at + 1
		}
	} else if text[at - 1] == '\n' || (text[at - 1] < 0x80 && (at == 1 || text[at - 2] < 0x80) && (at == len(text) || text[at] < 0x80)) {
		return at - 1
	}
	bounds := line_characters(text, at)
	defer delete(bounds)
	to := at
	if forward {
		for bound in bounds {
			if bound > at {
				to = bound
				break
			}
		}
	} else {
		#reverse for bound in bounds {
			if bound < at {
				to = bound
				break
			}
		}
	}
	return to
}

// Where each character of the line of a byte starts, and the end of
// the line: no character goes over a line break. Bytes that are no
// UTF-8 are one character for each run of them that the reader of
// characters cuts, so no start is in the middle of what a source has
// as a cut character. The caller deletes the result.
@(private = "file")
line_characters :: proc(text: []u8, at: int) -> (bounds: [dynamic]int) {
	start, end := paragraph_end(text, at, false), paragraph_end(text, at, true)
	// At the start of the line for a byte that is the line break.
	if at > 0 && at == start && at == end {
		start = paragraph_end(text, at - 1, false)
	}
	it := utf8.decode_grapheme_iterator_make(string(text[start:end]))
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		first := start + grapheme.byte_index
		if first == start || first >= len(text) || text[first] & 0xc0 != 0x80 {
			append(&bounds, first)
		}
	}
	append(&bounds, end)
	return
}

// True for a character that is a part of a word: one that starts with a letter, a
// digit, or "_".
@(private = "file")
in_word :: proc(text: []u8, at: int) -> bool {
	r, _ := utf8.decode_rune(text[at:])
	return unicode.is_letter(r) || unicode.is_number(r) || r == '_'
}

// The end of the word at a byte of a text or after it, or the start of
// the word at the byte or before it. The characters of a line are read
// one time for a step in it.
word_step :: proc(text: []u8, at: int, forward: bool) -> int {
	at := clamp(at, 0, len(text))
	for forward ? at < len(text) : at > 0 {
		// Over a line break, which is in no word.
		if text[forward ? at : at - 1] == '\n' {
			at += forward ? 1 : -1
			continue
		}
		bounds := line_characters(text, forward ? at : at - 1)
		defer delete(bounds)
		last := len(bounds) - 1
		if forward {
			i := 0
			for i < last && bounds[i] < at {
				i += 1
			}
			for i < last && !in_word(text, bounds[i]) {
				i += 1
			}
			if i < last {
				for i < last && in_word(text, bounds[i]) {
					i += 1
				}
				return bounds[i]
			}
			at = bounds[last]
		} else {
			i := last
			for i > 0 && bounds[i] > at {
				i -= 1
			}
			for i > 0 && !in_word(text, bounds[i - 1]) {
				i -= 1
			}
			if i > 0 {
				for i > 0 && in_word(text, bounds[i - 1]) {
					i -= 1
				}
				return bounds[i]
			}
			at = bounds[0]
		}
	}
	return at
}

// The start or the end of the paragraph that a byte of a text is in: a
// text is one paragraph, and each line of a code block is one.
paragraph_end :: proc(text: []u8, at: int, end: bool) -> int {
	at := clamp(at, 0, len(text))
	if end {
		rest := bytes.index_byte(text[at:], '\n')
		return rest < 0 ? len(text) : at + rest
	}
	return bytes.last_index_byte(text[:at], '\n') + 1
}

// The start of the text after the text of an address, or the end of the
// text before it: the next cell of a table, or a text of the next block
// that has one. False at the two ends of the document.
text_beside :: proc(doc: ^Document, at: Address, forward: bool) -> (next: Address, ok: bool) {
	step := forward ? 1 : -1
	block, cell := at.block, at.cell + step
	for block >= 0 && block < doc.count {
		texts := block_texts(block_at(doc, block))
		if cell >= 0 && cell < len(texts) {
			if forward {
				return {block = block, cell = cell}, true
			}
			// The end of the last text of a block is after its empty
			// paragraphs, or after the spaces at the end of its text.
			if cell == len(texts) - 1 {
				return block_end(doc, block)
			}
			return {block = block, cell = cell, byte = len(texts[cell].bytes)}, true
		}
		block += step
		if block >= 0 && block < doc.count {
			cell = forward ? 0 : len(block_texts(block_at(doc, block))) - 1
		}
	}
	return
}

// The two ends of the text of a document for a caret: the start of its
// first text and the end of its last one, also of a text with nothing
// in it (an item of a list with no text yet). False for a document
// with no text.
caret_ends :: proc(doc: ^Document) -> (first, last: Address, ok: bool) {
	first = text_beside(doc, {cell = -1}, true) or_return
	for block := doc.count - 1; block >= 0; block -= 1 {
		if at, has := block_end(doc, block); has {
			return first, at, true
		}
	}
	return
}

// The address one step from an address, in reading order or against it.
// At an end of a text, the step goes to the text beside it. False when
// there is no such address.
step :: proc(doc: ^Document, at: Address, how: Step, forward: bool) -> (next: Address, ok: bool) {
	at := at
	text := text_at(doc, at)
	// After the end of the last text of a block: the spaces at the end
	// of the text, a step of a character for each and one step of a
	// word for all, and then each empty paragraph after the block, one
	// step of each kind.
	if text != nil && at.byte >= len(text.bytes) {
		b := block_at(doc, at.block)
		n, spaces := empty_of(doc, at), spaces_of(doc, at)
		if at.cell == len(block_texts(b)) - 1 {
			next = at
			switch {
			case forward && n == 0 && spaces < int(b.end_spaces):
				next.spaces = how == .Word ? int(b.end_spaces) : spaces + 1
				return next, true
			case forward && n < int(b.empties):
				return empty_address(doc, at.block, n + 1)
			case !forward && n > 1:
				return empty_address(doc, at.block, n - 1)
			case !forward && n == 1:
				next.empty, next.spaces = 0, int(b.end_spaces)
				return next, true
			case !forward && spaces > 0 && how == .Character:
				next.spaces = spaces - 1
				return next, true
			}
		}
		// From here, a place in the text.
		at.empty, at.spaces = 0, 0
	}
	if text == nil || (forward ? at.byte >= len(text.bytes) : at.byte <= 0) {
		next = text_beside(doc, at, forward) or_return
		// The step of a word goes on to the word of the text beside.
		// Not to an empty paragraph, which is a stop of its own.
		if beside := text_at(doc, next); how == .Word && beside != nil && next.empty == 0 {
			next.byte = word_step(beside.bytes[:], next.byte, forward)
			next.spaces = 0
		}
		return next, true
	}
	next = at
	switch how {
	case .Character:
		next.byte = char_step(text.bytes[:], at.byte, forward)
	case .Word:
		next.byte = word_step(text.bytes[:], at.byte, forward)
	}
	return next, true
}
