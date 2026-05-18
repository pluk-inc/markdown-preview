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
