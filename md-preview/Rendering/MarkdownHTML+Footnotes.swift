//
//  MarkdownHTML+Footnotes.swift
//  md-preview
//
//  Footnote extraction and rendering.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // MARK: - Footnotes

    struct FootnoteExtraction {
        let markdown: String
        let definitions: [FootnoteDefinition]
        let references: [FootnoteReference]
    }

    struct FootnoteDefinition {
        let key: String
        let label: String
        let content: String
        let number: Int
        let sourceLine: Int
    }

    struct FootnoteReference {
        let number: Int
        let ordinal: Int
    }

    struct FootnoteDefinitionRenderResult {
        let html: String
        let containsMath: Bool
        let containsMermaid: Bool
    }

    private static let footnoteDefinitionRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"^[ \t]{0,3}\[\^([^\]\n]+)\]:[ \t]*(.*)$"#)
    }()

    private static let footnoteReferenceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#)
    }()

    static func extractFootnotes(from markdown: String) -> FootnoteExtraction {
        guard markdown.contains("[^") else {
            return FootnoteExtraction(markdown: markdown, definitions: [], references: [])
        }

        let split = splitFootnoteDefinitions(from: markdown)
        var protected: [String] = []

        let afterFences = replaceFullMatches(of: codeFenceRegex, in: split.markdown) { full in
            protected.append(full)
            return "MdPreviewFootnoteProtect\(protected.count - 1)Token"
        }
        let afterInlineCode = replaceFullMatches(of: inlineCodeRegex, in: afterFences) { full in
            protected.append(full)
            return "MdPreviewFootnoteProtect\(protected.count - 1)Token"
        }

        var orderedDefinitions: [FootnoteDefinition] = []
        var referenceOrdinalsByNumber: [Int: Int] = [:]
        var references: [FootnoteReference] = []

        let replacedReferences = replaceFootnoteReferenceMatches(in: afterInlineCode) { label, full in
            let key = normalizeFootnoteKey(label)
            guard let stored = split.definitions[key] else { return full }

            let definition: FootnoteDefinition
            if let existing = orderedDefinitions.first(where: { $0.key == key }) {
                definition = existing
            } else {
                definition = FootnoteDefinition(
                    key: key,
                    label: stored.label,
                    content: stored.content,
                    number: orderedDefinitions.count + 1,
                    sourceLine: stored.sourceLine
                )
                orderedDefinitions.append(definition)
            }

            let ordinal = (referenceOrdinalsByNumber[definition.number] ?? 0) + 1
            referenceOrdinalsByNumber[definition.number] = ordinal
            let token = "MdPreviewFootnoteRef\(references.count)Token"
            references.append(FootnoteReference(number: definition.number, ordinal: ordinal))
            return token
        }

        let restored = restoreIndexedTokens(
            in: replacedReferences,
            prefix: "MdPreviewFootnoteProtect",
            suffix: "Token",
            replacements: protected
        )

        return FootnoteExtraction(
            markdown: restored,
            definitions: orderedDefinitions,
            references: references
        )
    }

    private static func splitFootnoteDefinitions(from markdown: String) -> (
        markdown: String,
        definitions: [String: (label: String, content: String, sourceLine: Int)]
    ) {
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var definitions: [String: (label: String, content: String, sourceLine: Int)] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if let match = firstMatch(of: footnoteDefinitionRegex, in: line) {
                let definitionStartIndex = index
                let nsLine = line as NSString
                let label = nsLine.substring(with: match.range(at: 1))
                var contentLines = [nsLine.substring(with: match.range(at: 2))]
                index += 1

                while index < lines.count {
                    let continuation = lines[index]
                    if continuation.trimmingCharacters(in: .whitespaces).isEmpty {
                        if index + 1 < lines.count, isIndentedFootnoteContinuation(lines[index + 1]) {
                            contentLines.append("")
                            index += 1
                            continue
                        }
                        break
                    }
                    guard isIndentedFootnoteContinuation(continuation) else { break }
                    contentLines.append(stripFootnoteContinuationIndent(from: continuation))
                    index += 1
                }

                definitions[normalizeFootnoteKey(label)] = (
                    label: label,
                    content: contentLines.joined(separator: "\n"),
                    sourceLine: definitionStartIndex + 1
                )
                // Keep one blank placeholder for every removed source line.
                // Swift Markdown ignores these lines, while ranges for all
                // following blocks continue to match the original document.
                output.append(contentsOf: repeatElement(
                    "",
                    count: index - definitionStartIndex
                ))
            } else {
                output.append(line)
                index += 1
            }
        }

        return (output.joined(separator: "\n"), definitions)
    }


    private static func isIndentedFootnoteContinuation(_ line: String) -> Bool {
        if line.hasPrefix("\t") { return true }
        return line.count >= 4 && line.prefix(4).allSatisfy { $0 == " " }
    }

    private static func stripFootnoteContinuationIndent(from line: String) -> String {
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        if line.count >= 4 && line.prefix(4).allSatisfy({ $0 == " " }) {
            return String(line.dropFirst(4))
        }
        return line
    }

    private static func normalizeFootnoteKey(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func replaceFootnoteReferenceMatches(in source: String,
                                                        transform: (String, String) -> String) -> String {
        let nsSource = source as NSString
        let matches = footnoteReferenceRegex.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        guard !matches.isEmpty else { return source }

        var result = ""
        result.reserveCapacity(source.count)
        var cursor = 0
        for match in matches {
            result += nsSource.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let full = nsSource.substring(with: match.range)
            let label = nsSource.substring(with: match.range(at: 1))
            result += transform(label, full)
            cursor = match.range.location + match.range.length
        }
        result += nsSource.substring(from: cursor)
        return result
    }

    static func renderFootnoteReferences(in html: String,
                                                 with footnotes: FootnoteExtraction) -> String {
        guard !footnotes.references.isEmpty else { return html }
        let replacements = footnotes.references.map { reference in
            let refID = footnoteReferenceID(number: reference.number, ordinal: reference.ordinal)
            let footnoteID = footnoteDefinitionID(number: reference.number)
            let accessibilityLabel = htmlEscape(String(
                format: NSLocalizedString("Footnote %d", comment: "Footnote accessibility label"),
                reference.number
            ))
            let replacement = """
            <sup class="footnote-ref"><a id="\(refID)" href="#\(footnoteID)" aria-label="\(accessibilityLabel)">\(reference.number)</a></sup>
            """
            return replacement
        }
        return restoreIndexedTokens(
            in: html,
            prefix: "MdPreviewFootnoteRef",
            suffix: "Token",
            replacements: replacements
        )
    }

    static func renderFootnoteDefinitions(
        _ footnotes: FootnoteExtraction,
        sourceLineOffset: Int
    ) -> FootnoteDefinitionRenderResult {
        guard !footnotes.definitions.isEmpty else {
            return FootnoteDefinitionRenderResult(
                html: "",
                containsMath: false,
                containsMermaid: false
            )
        }

        var containsMath = false
        var containsMermaid = false
        let referencesByNumber = Dictionary(grouping: footnotes.references, by: { $0.number })
        let items = footnotes.definitions.map { definition -> String in
            let renderedContent = renderFootnoteDefinitionContent(
                definition.content,
                sourceLineOffset: sourceLineOffset + definition.sourceLine - 1
            )
            containsMath = containsMath || renderedContent.containsMath
            containsMermaid = containsMermaid || renderedContent.containsMermaid
            let backrefs = (referencesByNumber[definition.number] ?? []).map { reference in
                let accessibilityLabel = htmlEscape(String(
                    format: NSLocalizedString(
                        "Back to reference %d",
                        comment: "Footnote back-reference accessibility label"
                    ),
                    reference.number
                ))
                return """
                <a href="#\(footnoteReferenceID(number: reference.number, ordinal: reference.ordinal))" class="footnote-backref" aria-label="\(accessibilityLabel)">&#8617;</a>
                """
            }.joined(separator: " ")
            let contentHTML = appendFootnoteBackrefs(backrefs, to: renderedContent.html)

            return """
            <li id="\(footnoteDefinitionID(number: definition.number))">
            \(contentHTML)
            </li>
            """
        }.joined(separator: "\n")

        return FootnoteDefinitionRenderResult(
            html: """

            <section class="footnotes" role="doc-endnotes">
            <hr />
            <ol>
            \(items)
            </ol>
            </section>
            """,
            containsMath: containsMath,
            containsMermaid: containsMermaid
        )
    }

    private static func appendFootnoteBackrefs(_ backrefs: String, to html: String) -> String {
        guard !backrefs.isEmpty else { return html }
        let inlineBackrefs = "<span class=\"footnote-backrefs\">\(backrefs)</span>"
        if let range = html.range(of: "</p>", options: .backwards) {
            var updated = html
            updated.replaceSubrange(range, with: " \(inlineBackrefs)</p>")
            return updated
        }
        return html + inlineBackrefs
    }

    private static func renderFootnoteDefinitionContent(
        _ markdown: String,
        sourceLineOffset: Int
    ) -> FootnoteDefinitionRenderResult {
        let math = extractMath(from: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        let formatted = EscapingHTMLFormatter.format(
            math.processedMarkdown,
            sourceLineOffset: sourceLineOffset
        )
        let mermaidResult = renderMermaidBlocks(in: formatted)
        let mathResult = renderMathBlocks(in: mermaidResult.html, with: math)
        return FootnoteDefinitionRenderResult(
            html: mathResult.html,
            containsMath: mathResult.containsMath,
            containsMermaid: mermaidResult.containsMermaid
        )
    }

    private static func footnoteDefinitionID(number: Int) -> String {
        "fn-\(number)"
    }

    private static func footnoteReferenceID(number: Int, ordinal: Int) -> String {
        ordinal == 1 ? "fnref-\(number)" : "fnref-\(number)-\(ordinal)"
    }
}
