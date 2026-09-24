import Foundation

/// Fence names supported by the bundled editor grammars, plus unhighlighted text.
nonisolated struct CodeLanguageOption: Identifiable, Equatable {
    let id: String
    let name: String
    let glyph: String
    let aliases: String
}

nonisolated enum CodeLanguageCatalog {
    static let all: [CodeLanguageOption] = [
        .init(id: "bash", name: "Bash", glyph: "$", aliases: "shell sh zsh console"),
        .init(id: "c", name: "C", glyph: "C", aliases: "h"),
        .init(id: "cpp", name: "C++", glyph: "C⁺⁺", aliases: "cc hpp"),
        .init(id: "csharp", name: "C#", glyph: "C#", aliases: "cs"),
        .init(id: "css", name: "CSS", glyph: "#", aliases: "scss"),
        .init(id: "go", name: "Go", glyph: "Go", aliases: "golang"),
        .init(id: "hcl", name: "HCL", glyph: "{}", aliases: "terraform tf"),
        .init(id: "html", name: "HTML", glyph: "<>", aliases: "htm xml"),
        .init(id: "java", name: "Java", glyph: "J", aliases: ""),
        .init(id: "javascript", name: "JavaScript", glyph: "JS", aliases: "js jsx node"),
        .init(id: "json", name: "JSON", glyph: "{}", aliases: "jsonc"),
        .init(id: "kotlin", name: "Kotlin", glyph: "K", aliases: "kt"),
        .init(id: "objective-c", name: "Objective-C", glyph: "m", aliases: "objc objectivec"),
        .init(id: "text", name: "Plain Text", glyph: "¶", aliases: "txt plaintext"),
        .init(id: "python", name: "Python", glyph: "Py", aliases: "py"),
        .init(id: "ruby", name: "Ruby", glyph: "Rb", aliases: "rb"),
        .init(id: "rust", name: "Rust", glyph: "Rs", aliases: "rs"),
        .init(id: "sql", name: "SQL", glyph: "SQL", aliases: ""),
        .init(id: "swift", name: "Swift", glyph: "", aliases: ""),
        .init(id: "toml", name: "TOML", glyph: "T", aliases: ""),
        .init(id: "typescript", name: "TypeScript", glyph: "TS", aliases: "ts tsx"),
        .init(id: "yaml", name: "YAML", glyph: "Y", aliases: "yml"),
    ].sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static let commonIDs = ["swift", "objective-c", "c", "cpp", "python", "javascript", "bash", "json", "html"]
    static let recentKey = "editor.recentCodeLanguages"

    static func matching(_ query: String) -> [CodeLanguageOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { "\($0.name) \($0.id) \($0.aliases)".localizedStandardContains(query) }
    }

    static func options(for ids: [String]) -> [CodeLanguageOption] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return all.first { $0.id == id }
        }
    }

    static func recent(defaults: UserDefaults = .standard) -> [CodeLanguageOption] {
        Array(options(for: defaults.stringArray(forKey: recentKey) ?? []).prefix(5))
    }

    static func remember(_ id: String, defaults: UserDefaults = .standard) {
        guard all.contains(where: { $0.id == id }) else { return }
        let ids = [id] + recent(defaults: defaults).map(\.id).filter { $0 != id }
        defaults.set(Array(ids.prefix(5)), forKey: recentKey)
    }
}
