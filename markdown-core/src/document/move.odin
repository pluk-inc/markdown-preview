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
	// An ASCII character starts a character, and is all of it when no
	// mark comes after it: most steps read two bytes. A line break is
	// such a character.
	if forward {
		if text[at] == '\n' || (text[at] < 0x80 && (at + 1 == len(text) || text[at + 1] < 0x80)) {
			return at + 1
		}
	} else if text[at - 1] < 0x80 {
		return at - 1
	}
	// No character goes over a line break, and one starts at each ASCII
	// byte: the characters are read from the last such place before the
	// byte, to the end of the line.
	start := at
	for start > 0 && text[start - 1] != '\n' {
		start -= 1
		if text[start] < 0x80 {
			break
		}
	}
	end := paragraph_end(text, at, true)
	it := utf8.decode_grapheme_iterator_make(string(text[start:end]))
	next, before := end, start
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		first := start + grapheme.byte_index
		if first > at {
			next = first
			break
		}
		if first < at {
			before = first
		}
	}
	// Bytes that are no UTF-8 are one character each for the reader of
	// characters; a step does not end in the middle of what the source
	// has as one run of them.
	to := forward ? next : before
	for to > 0 && to < len(text) && text[to] & 0xc0 == 0x80 {
		to += forward ? 1 : -1
	}
	return to
}

// True for a character that is a part of a word: one that starts with a letter, a
// digit, or "_".
@(private = "file")
in_word :: proc(text: []u8, at: int) -> bool {
	r, _ := utf8.decode_rune(text[at:])
	return unicode.is_letter(r) || unicode.is_number(r) || r == '_'
}

// The end of the word at a byte of a text or after it, or the start of
// the word at the byte or before it.
word_step :: proc(text: []u8, at: int, forward: bool) -> int {
	at := clamp(at, 0, len(text))
	if forward {
		for at < len(text) && !in_word(text, at) {
			at = char_step(text, at, true)
		}
		for at < len(text) && in_word(text, at) {
			at = char_step(text, at, true)
		}
		return at
	}
	for at > 0 {
		before := char_step(text, at, false)
		if in_word(text, before) {
			break
		}
		at = before
	}
	for at > 0 {
		before := char_step(text, at, false)
		if !in_word(text, before) {
			break
		}
		at = before
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
			return {block, cell, forward ? 0 : len(texts[cell].bytes)}, true
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
	first = text_beside(doc, {0, -1, 0}, true) or_return
	for block := doc.count - 1; block >= 0; block -= 1 {
		if texts := block_texts(block_at(doc, block)); len(texts) > 0 {
			return first, {block, len(texts) - 1, len(texts[len(texts) - 1].bytes)}, true
		}
	}
	return
}

// The address one step from an address, in reading order or against it.
// At an end of a text, the step goes to the text beside it. False when
// there is no such address.
step :: proc(doc: ^Document, at: Address, how: Step, forward: bool) -> (next: Address, ok: bool) {
	text := text_at(doc, at)
	if text == nil || (forward ? at.byte >= len(text.bytes) : at.byte <= 0) {
		next = text_beside(doc, at, forward) or_return
		// The step of a word goes on to the word of the text beside.
		if beside := text_at(doc, next); how == .Word && beside != nil {
			next.byte = word_step(beside.bytes[:], next.byte, forward)
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
