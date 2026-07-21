//
//  MarkdownFrontmatter.swift
//  md-preview
//

import Foundation

struct FrontmatterEntry: Equatable, Identifiable {
    let id: Int
    let key: String
    let value: String
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
    // indented continuation lines append to the previous value. We don't
    // interpret YAML types — values are shown verbatim in the Inspector.
    static func parse(_ raw: String, format: Format = .yaml) -> [FrontmatterEntry] {
        switch format {
        case .yaml:
            parseYaml(raw)
        case .toml:
            parseToml(raw)
        }
    }

    private static func parseYaml(_ raw: String) -> [FrontmatterEntry] {
        var entries: [FrontmatterEntry] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if line.first == " " || line.first == "\t", !entries.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let prev = entries[entries.count - 1]
                let combined = prev.value.isEmpty ? trimmed : "\(prev.value) \(trimmed)"
                entries[entries.count - 1] = FrontmatterEntry(id: prev.id, key: prev.key, value: combined)
                continue
            }

            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            entries.append(FrontmatterEntry(id: entries.count, key: key, value: value))
        }
        return entries
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
            entries.append(FrontmatterEntry(id: entries.count, key: key, value: unquoteTomlValue(value)))
        }
        return entries
    }

    private static func unquoteTomlValue(_ value: String) -> String {
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
