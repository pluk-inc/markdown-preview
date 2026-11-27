package document

import "core:strings"

// The entries of front matter, for the panel that the page shows in its
// place: each "key: value" line of YAML ("---") or "key = value" line of
// TOML ("+++"). The rules are the ones of the app's parser for the web
// page (`MarkdownFrontmatter`), which reads no more of the two formats:
// a value is shown as it is written (with no quotes around it), a line
// that starts with a space goes on with the value before it, and a
// sequence ("- item" lines, or "[a, b]") is the items of its key.

// One entry. `items` is the items of a sequence, and `value` is then the
// items with ", " between them; nil for a value that is no sequence.
// `blank`: a sequence of TOML with no item, which the web page shows as
// nothing (a value that is empty shows as a dash).
Front_Entry :: struct {
	key, value: string,
	items:      []string,
	blank:      bool,
}

// The entries of the front matter at the start of a source that hides
// `hidden` bytes (`hidden_start`). None for a source with no front
// matter. All of the memory is of `allocator`: an arena, or a caller that
// frees all of it at one time.
front_matter :: proc(source: []u8, hidden: int, allocator := context.allocator) -> []Front_Entry {
	context.allocator = allocator
	open := opening_line(source)
	if open == "" || hidden <= bom_size(source) {
		return nil
	}
	toml := open == "+++"
	entries := make([dynamic]Front_Entry)
	items := make([dynamic][dynamic]string)
	_, at := line_at(source, bom_size(source))
	for at < min(hidden, len(source)) {
		end, next := line_at(source, at)
		line := string(source[at:end])
		at = next
		if closes(open, transmute([]u8)line) {
			break
		}
		trimmed := trim_blank(line)
		if trimmed == "" || trimmed[0] == '#' {
			continue
		}
		if toml {
			if trimmed[0] == '[' {
				continue
			}
			equals := strings.index_byte(line, '=')
			if equals < 0 {
				continue
			}
			key := trim_blank(line[:equals])
			value := trim_blank(line[equals + 1:])
			if key == "" {
				continue
			}
			sequence, is_sequence := flow_items(value)
			append(&entries, Front_Entry{key = key, value = is_sequence ? "" : unquote(value), blank = is_sequence && len(sequence) == 0})
			append(&items, sequence)
			continue
		}
		// The items of a sequence are of the key before them, at its
		// indent or deeper: before the rule for a line that goes on.
		if (trimmed == "-" || strings.has_prefix(trimmed, "- ")) && len(entries) > 0 {
			if item := unquote(trim_blank(trimmed[1:])); item != "" {
				append(&items[len(items) - 1], item)
			}
			continue
		}
		if (line[0] == ' ' || line[0] == '\t') && len(entries) > 0 {
			last := &entries[len(entries) - 1]
			last.value = last.value == "" ? trimmed : strings.concatenate({last.value, " ", trimmed})
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		key := trim_blank(line[:colon])
		value := trim_blank(line[colon + 1:])
		if key == "" {
			continue
		}
		if sequence, is_sequence := flow_items(value); is_sequence {
			append(&entries, Front_Entry{key = key})
			append(&items, sequence)
			continue
		}
		switch value {
		case "|", "|-", "|+", ">", ">-", ">+":
			// The value is the lines after it, which go on with it.
			value = ""
		case:
			if value != "" && value[0] != '"' && value[0] != '\'' {
				if comment := strings.index(value, " #"); comment >= 0 {
					value = trim_blank(value[:comment])
				}
			}
		}
		append(&entries, Front_Entry{key = key, value = unquote(value)})
		append(&items, nil)
	}
	for &entry, i in entries {
		if len(items[i]) > 0 {
			entry.items = items[i][:]
			entry.value = strings.join(entry.items, ", ")
		}
	}
	return entries[:]
}

// The items of "[a, b]". False for a value that is no such sequence; one
// with a sequence or a mapping in it stays a value as it is written.
@(private)
flow_items :: proc(value: string) -> (items: [dynamic]string, ok: bool) {
	if !strings.has_prefix(value, "[") || !strings.has_suffix(value, "]") || len(value) < 2 {
		return nil, false
	}
	inner := value[1:len(value) - 1]
	if strings.contains_any(inner, "[{") {
		return nil, false
	}
	items = make([dynamic]string)
	take :: proc(items: ^[dynamic]string, piece: string) {
		if item := unquote(trim_blank(piece)); item != "" {
			append(items, item)
		}
	}
	start := 0
	quote: u8
	for i in 0 ..< len(inner) {
		ch := inner[i]
		switch {
		case quote != 0:
			if ch == quote {
				quote = 0
			}
		case ch == '"' || ch == '\'':
			quote = ch
		case ch == ',':
			take(&items, inner[start:i])
			start = i + 1
		}
	}
	take(&items, inner[start:])
	return items, true
}

// A text with no blank characters at its two ends: the space, the tab,
// and the other spaces of Unicode (a no-break space before a colon, a
// wide space of Chinese and Japanese text), as the app's parser takes
// them off.
@(private)
trim_blank :: proc(s: string) -> string {
	blank :: proc(r: rune) -> bool {
		switch r {
		case ' ', '\t', 0x00A0, 0x1680, 0x2000 ..= 0x200A, 0x202F, 0x205F, 0x3000:
			return true
		}
		return false
	}
	return strings.trim_right_proc(strings.trim_left_proc(s, blank), blank)
}

// A value with no quotes around it.
@(private)
unquote :: proc(value: string) -> string {
	if n := len(value); n >= 2 && value[0] == value[n - 1] && (value[0] == '"' || value[0] == '\'') {
		return value[1:n - 1]
	}
	return value
}
