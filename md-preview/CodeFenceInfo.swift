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
