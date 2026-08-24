//
//  CodeFenceInfo.swift
//  md-preview
//

import Foundation

/// Parsed components of a CommonMark fenced code block info string.
///
/// CommonMark trims the info string of surrounding whitespace; by convention
/// its first whitespace-separated token is the language identifier and
/// anything after is implementation-defined metadata (e.g. a mermaid diagram
/// name, GFM `title="foo.ts"`).
nonisolated struct CodeFenceInfo: Equatable {
    /// First whitespace-separated token of the info string, lowercased.
    /// Empty when the info string is missing or whitespace-only.
    let language: String

    /// Remainder of the info string after the language word, with surrounding
    /// whitespace trimmed. Empty when there is no metadata.
    let metadata: String

    /// Language identifier passed to the read-mode highlighter.
    ///
    /// CodeMirror treats these common shell fence names as one shell grammar,
    /// while highlight.js reserves `shell` and `console` for transcript-style
    /// input. Normalize them so read and edit mode parse the same source as
    /// shell code.
    var highlightLanguage: String {
        switch language {
        case "shell", "sh", "zsh", "console":
            return "bash"
        default:
            return language
        }
    }

    init(rawInfoString: String?) {
        guard let raw = rawInfoString else {
            self.language = ""
            self.metadata = ""
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            self.language = trimmed.lowercased()
            self.metadata = ""
            return
        }
        self.language = trimmed[..<split].lowercased()
        self.metadata = trimmed[split...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Conservative content-based detection used only when a fence has no info
/// string. Explicit fence languages always remain the source of truth.
nonisolated enum CodeFenceLanguageDetector {
    static func detect(_ source: String) -> String? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if matches(#"(?m)^#!.*\b(?:ba)?sh\b|^\s*\$\s+"#, in: text) {
            return "bash"
        }
        if (text.hasPrefix("{") && text.hasSuffix("}"))
            || (text.hasPrefix("[") && text.hasSuffix("]")),
           let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return "json"
        }
        if matches(#"(?m)^\s*(?:<!DOCTYPE\s+html|<html\b|<(?:div|span|section|article)\b)"#, in: text) {
            return "html"
        }
        if matches(#"(?m)\b(?:resource|data|provider|variable|module)\s+\"[\w-]+\"(?:\s+\"[\w-]+\")?\s*\{|\bterraform\s*\{"#, in: text) {
            return "hcl"
        }
        if matches(#"\b(?:import\s+Foundation|func\s+\w+\s*\(|@main)\b|\b(?:let|var)\s+\w+\s*:\s*(?:String|Int|Bool|Double|Float)\b"#, in: text) {
            return "swift"
        }
        if matches(#"(?m)^\s*(?:#\s*include\s*<iostream>|(?:using\s+namespace\s+std|std::\w+|(?:cout|cin)\s*(?:<<|>>))\b)"#, in: text) {
            return "cpp"
        }
        if matches(#"(?m)^\s*(?:#\s*include\s*[<"](?:assert|ctype|errno|float|inttypes|limits|math|setjmp|signal|stdarg|stdbool|stddef|stdint|stdio|stdlib|string|time)\.h[>"]|(?:int|void)\s+main\s*\([^)]*\)\s*\{)"#, in: text) {
            return "c"
        }
        if matches(#"(?m)^\s*(?:async\s+)?def\s+\w+\s*\(|^\s*from\s+\w+[\w.]*\s+import\b|^\s*class\s+\w+\s*[:(]"#, in: text) {
            return "python"
        }
        if matches(#"(?i)\b(?:SELECT|INSERT|UPDATE|DELETE|CREATE\s+(?:TABLE|VIEW|INDEX)|WITH)\b[\s\S]*\b(?:FROM|INTO|WHERE|AS)\b"#, in: text) {
            return "sql"
        }
        if matches(#"(?m)(?:^|\n)\s*(?:[#.]?[A-Za-z][\w-]*)\s*\{[\s\S]*:[\s\S]*\}"#, in: text)
            || matches(#"@(?:media|keyframes|supports)\b"#, in: text) {
            return "css"
        }
        if matches(#"(?m)^\s*(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*(?::[^=\n]+)?\s*="#, in: text)
            || matches(#"\b(?:function\s+\w+\s*\(|console\.(?:log|error|warn)|=>)"#, in: text) {
            return "javascript"
        }
        if matches(#"(?m)^\s*(?:[-A-Za-z_][\w-]*):\s*(?:[^:#\n]|$)"#, in: text)
            && !text.contains("{") && !text.contains(";") {
            return "yaml"
        }
        if matches(#"(?m)^\s*(?:echo|printf|export|source|cd|mkdir|rm|cp|mv)\s+"#, in: text) {
            return "bash"
        }
        return nil
    }

    private static func matches(_ pattern: String, in source: String) -> Bool {
        source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
