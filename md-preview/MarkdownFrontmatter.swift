//
//  MarkdownFrontmatter.swift
//  md-preview
//

import Foundation

struct FrontmatterEntry: Equatable, Identifiable {
    let id: Int
    let key: String
    let value: String
    /// Non-nil when the value is a sequence (`tags: [a, b]` or `- item`
    /// lines). `value` then carries the items joined with ", " for
    /// plain-text consumers like the Inspector.
    let items: [String]?

    nonisolated init(id: Int, key: String, value: String, items: [String]? = nil) {
        self.id = id
        self.key = key
        self.value = value
        self.items = items
    }
}

// Swift-markdown is CommonMark: it has no frontmatter notion, so delimiter
// blocks can be rendered as document content. We split supported frontmatter
// from the Markdown body, then surface its parsed entries in the rendered page
// and Inspector.
nonisolated enum MarkdownFrontmatter {

    enum Format {
        case yaml
        case toml
    }

    static func split(_ markdown: String) -> (raw: String?, format: Format?, body: String) {
        let stripped = markdown.first == "\u{FEFF}" ? String(markdown.dropFirst()) : markdown
        var lines: [String] = []
        stripped.enumerateLines { line, _ in lines.append(line) }

        guard let first = lines.first,
              let delimiter = Delimiter(openingLine: first)
        else { return (nil, nil, markdown) }

        guard let close = lines.dropFirst().firstIndex(where: {
            delimiter.closes($0)
        }) else { return (nil, nil, markdown) }

        let raw = lines[1..<close].joined(separator: "\n")
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (raw, delimiter.format, body)
    }

    // Best-effort parse: each top-level `key: value` line becomes an entry;
    // indented continuation lines append to the previous value, `- item`
    // lines and `[a, b]` flow sequences become the entry's items. We don't
    // interpret other YAML types — scalars are shown verbatim (unquoted).
    static func parse(_ raw: String, format: Format = .yaml) -> [FrontmatterEntry] {
        switch format {
        case .yaml:
            parseYaml(raw)
        case .toml:
            parseToml(raw)
        }
    }

    private static func parseYaml(_ raw: String) -> [FrontmatterEntry] {
        var entries: [(key: String, value: String, items: [String])] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Sequence items belong to the previous key. YAML allows them
            // at the key's own indent or deeper, so match before the
            // continuation-line rule below.
            if trimmed == "-" || trimmed.hasPrefix("- "), !entries.isEmpty {
                let item = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if !item.isEmpty { entries[entries.count - 1].items.append(item) }
                continue
            }

            if line.first == " " || line.first == "\t", !entries.isEmpty {
                let prev = entries[entries.count - 1].value
                entries[entries.count - 1].value = prev.isEmpty ? trimmed : "\(prev) \(trimmed)"
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if let flowItems = flowSequenceItems(value) {
                entries.append((key, "", flowItems))
                continue
            }

            if blockScalarIndicators.contains(value) {
                // `key: >-` etc. — the value is the indented block that
                // follows; continuation lines fill it in, folded with spaces.
                value = ""
            } else if value.first != "\"", value.first != "'",
                      let comment = value.range(of: " #") {
                value = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            entries.append((key, unquote(value), []))
        }
        return entries.enumerated().map { index, entry in
            let items = entry.items.isEmpty ? nil : entry.items
            return FrontmatterEntry(
                id: index,
                key: entry.key,
                value: items?.joined(separator: ", ") ?? entry.value,
                items: items
            )
        }
    }

    private static func parseToml(_ raw: String) -> [FrontmatterEntry] {
        var entries: [FrontmatterEntry] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("[") { continue }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if let items = flowSequenceItems(value) {
                entries.append(FrontmatterEntry(
                    id: entries.count,
                    key: key,
                    value: items.joined(separator: ", "),
                    items: items
                ))
            } else {
                entries.append(FrontmatterEntry(id: entries.count, key: key, value: unquote(value)))
            }
        }
        return entries
    }

    private static let blockScalarIndicators: Set<String> = ["|", "|-", "|+", ">", ">-", ">+"]

    /// `["a", "b"]` → `["a", "b"]`. Nil unless the value is a simple flow
    /// sequence — nested collections stay verbatim scalars.
    private static func flowSequenceItems(_ value: String) -> [String]? {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return nil }
        let inner = String(value.dropFirst().dropLast())
        guard !inner.contains("["), !inner.contains("{") else { return nil }

        var items: [String] = []
        var current = ""
        var quote: Character?
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                items.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        items.append(current)
        return items
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              first == value.last,
              first == "\"" || first == "'"
        else { return value }

        return String(value.dropFirst().dropLast())
    }

    private enum Delimiter {
        case yaml
        case toml

        var format: Format {
            switch self {
            case .yaml: .yaml
            case .toml: .toml
            }
        }

        init?(openingLine: String) {
            switch openingLine.trimmingCharacters(in: .whitespaces) {
            case "---":
                self = .yaml
            case "+++":
                self = .toml
            default:
                return nil
            }
        }

        func closes(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            switch self {
            case .yaml:
                return trimmed == "---" || trimmed == "..."
            case .toml:
                return trimmed == "+++"
            }
        }
    }
}
