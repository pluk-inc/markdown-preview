//
//  EscapingHTMLFormatter.swift
//  md-preview
//

import Foundation
import Markdown

nonisolated enum TaskCheckboxSource {
    private static let markerRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"^(\s*(?:>\s*)*(?:[-+*]|\d+[.)])\s+\[)([ xX])(\])"#
        )
    }()

    /// Returns a copy with the task marker on the 1-based source line set to
    /// the requested state. The source line comes from swift-markdown's range,
    /// so duplicate task labels and nested lists remain unambiguous.
    static func settingChecked(_ checked: Bool,
                               onLine sourceLine: Int,
                               in markdown: String) -> String? {
        guard sourceLine > 0 else { return nil }
        var lines = markdown.components(separatedBy: "\n")
        let index = sourceLine - 1
        guard lines.indices.contains(index) else { return nil }

        let line = lines[index]
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = markerRegex.firstMatch(in: line, range: fullRange),
              let markerRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        lines[index].replaceSubrange(markerRange, with: checked ? "x" : " ")
        return lines.joined(separator: "\n")
    }
}

nonisolated enum MarkdownTableEdit: Equatable {
    case setCell(row: Int, column: Int, markdown: String)
    case insertRowBefore(Int)
    case insertRowAfter(Int)
    case deleteRow(Int)
    case insertColumnBefore(Int)
    case insertColumnAfter(Int)
    case deleteColumn(Int)
}

/// Applies visual table edits back to a source-mapped GFM table. The rendered
/// preview supplies the table's exact source range, so similarly-shaped tables
/// and duplicate cell values remain unambiguous.
nonisolated enum MarkdownTableSource {
    private enum Alignment {
        case none, left, center, right
    }

    static func applying(_ edit: MarkdownTableEdit,
                         fromLine startLine: Int,
                         throughLine endLine: Int,
                         in markdown: String) -> String? {
        guard startLine > 0, endLine >= startLine else { return nil }
        var sourceLines = markdown.components(separatedBy: "\n")
        let startIndex = startLine - 1
        let endIndex = endLine - 1
        guard sourceLines.indices.contains(startIndex),
              sourceLines.indices.contains(endIndex) else { return nil }

        let tableLines = Array(sourceLines[startIndex...endIndex])
        guard tableLines.count >= 2 else { return nil }
        var rows = tableLines.map(splitRow)
        guard rows.count >= 2,
              !rows[0].isEmpty,
              let alignments = parseAlignments(rows[1]) else { return nil }

        // The delimiter row is structural rather than an editable data row.
        rows.remove(at: 1)
        var tableAlignments = alignments
        let initialColumnCount = max(rows.map(\.count).max() ?? 0, tableAlignments.count)
        guard initialColumnCount > 0 else { return nil }
        normalizeRows(&rows, columnCount: initialColumnCount)
        normalizeAlignments(&tableAlignments, columnCount: initialColumnCount)

        switch edit {
        case let .setCell(row, column, value):
            guard rows.indices.contains(row), rows[row].indices.contains(column) else { return nil }
            rows[row][column] = escapedCell(value)
        case let .insertRowAfter(after):
            guard after >= 0, after < rows.count else { return nil }
            rows.insert(Array(repeating: "", count: tableAlignments.count), at: after + 1)
        case let .insertRowBefore(before):
            // A row cannot precede the Markdown header.
            guard before > 0, before < rows.count else { return nil }
            rows.insert(Array(repeating: "", count: tableAlignments.count), at: before)
        case let .deleteRow(row):
            // Header deletion would make the table invalid. Keep at least the
            // header; a table with no body rows is still valid Markdown.
            guard row > 0, rows.indices.contains(row) else { return nil }
            rows.remove(at: row)
        case let .insertColumnAfter(after):
            guard after >= 0, after < tableAlignments.count else { return nil }
            for index in rows.indices {
                rows[index].insert("", at: after + 1)
            }
            tableAlignments.insert(.none, at: after + 1)
        case let .insertColumnBefore(before):
            guard before >= 0, before < tableAlignments.count else { return nil }
            for index in rows.indices {
                rows[index].insert("", at: before)
            }
            tableAlignments.insert(.none, at: before)
        case let .deleteColumn(column):
            guard tableAlignments.count > 1,
                  column >= 0,
                  column < tableAlignments.count else { return nil }
            for index in rows.indices {
                rows[index].remove(at: column)
            }
            tableAlignments.remove(at: column)
        }

        let replacement = serialize(rows: rows, alignments: tableAlignments)
        sourceLines.replaceSubrange(startIndex...endIndex, with: replacement)
        return sourceLines.joined(separator: "\n")
    }

    /// Returns the exact Markdown source for each rendered data cell. The
    /// delimiter row is structural and is omitted so these coordinates match
    /// the table row indices emitted into the preview DOM.
    static func sourceRows(from tableLines: [String]) -> [[String]]? {
        guard tableLines.count >= 2 else { return nil }
        var rows = tableLines.map(splitRow)
        guard !rows[0].isEmpty,
              let alignments = parseAlignments(rows[1]) else { return nil }
        rows.remove(at: 1)
        let columnCount = max(rows.map(\.count).max() ?? 0, alignments.count)
        guard columnCount > 0 else { return nil }
        normalizeRows(&rows, columnCount: columnCount)
        return rows
    }

    private static func splitRow(_ source: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var backslashCount = 0
        var codeFenceLength = 0
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if character == "`" && backslashCount.isMultiple(of: 2) {
                var runEnd = source.index(after: index)
                while runEnd < source.endIndex, source[runEnd] == "`" {
                    runEnd = source.index(after: runEnd)
                }
                let runLength = source.distance(from: index, to: runEnd)
                if codeFenceLength == 0 {
                    codeFenceLength = runLength
                } else if codeFenceLength == runLength {
                    codeFenceLength = 0
                }
                cell.append(contentsOf: source[index..<runEnd])
                index = runEnd
                backslashCount = 0
                continue
            }
            if character == "|", backslashCount.isMultiple(of: 2), codeFenceLength == 0 {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            if character == "\\" {
                backslashCount += 1
            } else {
                backslashCount = 0
            }
            index = source.index(after: index)
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        if source.trimmingCharacters(in: .whitespaces).hasPrefix("|"), cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if source.trimmingCharacters(in: .whitespaces).hasSuffix("|"), cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func parseAlignments(_ cells: [String]) -> [Alignment]? {
        guard !cells.isEmpty else { return nil }
        var result: [Alignment] = []
        for cell in cells {
            let token = cell.trimmingCharacters(in: .whitespaces)
            let left = token.hasPrefix(":")
            let right = token.hasSuffix(":")
            let hyphens = token.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard hyphens.count >= 3, hyphens.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return result
    }

    private static func normalizeRows(_ rows: inout [[String]], columnCount: Int) {
        for index in rows.indices {
            if rows[index].count < columnCount {
                rows[index].append(contentsOf: repeatElement("", count: columnCount - rows[index].count))
            } else if rows[index].count > columnCount {
                rows[index] = Array(rows[index].prefix(columnCount))
            }
        }
    }

    private static func normalizeAlignments(_ alignments: inout [Alignment], columnCount: Int) {
        if alignments.count < columnCount {
            alignments.append(contentsOf: repeatElement(.none, count: columnCount - alignments.count))
        } else if alignments.count > columnCount {
            alignments = Array(alignments.prefix(columnCount))
        }
    }

    private static func escapedCell(_ source: String) -> String {
        let flattened = source.replacingOccurrences(of: "\n", with: " ")
        var result = ""
        var backslashCount = 0
        var codeFenceLength = 0
        var index = flattened.startIndex
        while index < flattened.endIndex {
            let character = flattened[index]
            if character == "`" && backslashCount.isMultiple(of: 2) {
                var runEnd = flattened.index(after: index)
                while runEnd < flattened.endIndex, flattened[runEnd] == "`" {
                    runEnd = flattened.index(after: runEnd)
                }
                let runLength = flattened.distance(from: index, to: runEnd)
                if codeFenceLength == 0 { codeFenceLength = runLength }
                else if codeFenceLength == runLength { codeFenceLength = 0 }
                result.append(contentsOf: flattened[index..<runEnd])
                index = runEnd
                backslashCount = 0
                continue
            }
            if character == "|", backslashCount.isMultiple(of: 2), codeFenceLength == 0 {
                result.append("\\")
            }
            result.append(character)
            backslashCount = character == "\\" ? backslashCount + 1 : 0
            index = flattened.index(after: index)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func serialize(rows: [[String]], alignments: [Alignment]) -> [String] {
        let widths = alignments.indices.map { column in
            max(3, rows.map { $0[column].count }.max() ?? 0)
        }
        func dataRow(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { index, cell in
                cell + String(repeating: " ", count: max(0, widths[index] - cell.count))
            }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + alignments.enumerated().map { index, alignment in
            let width = widths[index]
            switch alignment {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: max(3, width - 1))
            case .right: return String(repeating: "-", count: max(3, width - 1)) + ":"
            case .center: return ":" + String(repeating: "-", count: max(3, width - 2)) + ":"
            }
        }.joined(separator: " | ") + " |"

        var result = [dataRow(rows[0]), delimiter]
        result.append(contentsOf: rows.dropFirst().map(dataRow))
        return result
    }
}

// Mirrors swift-markdown's HTMLFormatter but HTML-escapes text, code, and
// attribute values. Upstream HTMLFormatter emits unescaped content
// (swift-markdown 0.7.x), so characters like `<`, `>`, and `&` either render
// invisibly or get reinterpreted as HTML — see issue #33.
nonisolated struct EscapingHTMLFormatter: MarkupWalker {
    private(set) var result = ""

    let options: HTMLFormatterOptions
    let sourceLineOffset: Int
    private let sourceLines: [String]

    private var inTableHead = false
    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var tableSourceRows: [[String]]?
    private var currentTableColumn = 0
    private var currentTableRow = 0

    init(options: HTMLFormatterOptions = [],
         sourceLineOffset: Int = 0,
         sourceMarkdown: String = "") {
        self.options = options
        self.sourceLineOffset = sourceLineOffset
        self.sourceLines = sourceMarkdown.components(separatedBy: "\n")
    }

    static func format(_ markdown: String,
                       options: HTMLFormatterOptions = [],
                       sourceLineOffset: Int = 0,
                       sourceMarkdown: String? = nil) -> String {
        let document = Document(parsing: markdown)
        var walker = EscapingHTMLFormatter(
            options: options,
            sourceLineOffset: sourceLineOffset,
            sourceMarkdown: sourceMarkdown ?? markdown
        )
        walker.visit(document)
        return walker.result
    }

    // MARK: Block elements

    private func sourceLineAttribute(_ markup: Markup) -> String {
        guard let range = markup.range else { return "" }
        let start = range.lowerBound.line + sourceLineOffset
        // SourceRange is half-open. A range ending at column 1 belongs to the
        // previous source line, not the new line whose first column it meets.
        let inclusiveEndLine = range.upperBound.column == 1
            && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1
            : range.upperBound.line
        let end = max(start, inclusiveEndLine + sourceLineOffset)
        // Keep data-source-line while callers migrate to the richer range.
        return " data-source-line=\"\(start)\" data-source-start=\"\(start)\" data-source-end=\"\(end)\""
    }

    private func precedingBlankLineCount(for markup: Markup) -> Int {
        guard let line = markup.range?.lowerBound.line else { return 0 }
        var precedingLineIndex = line - 2
        var blankLineCount = 0
        while precedingLineIndex >= 0,
              precedingLineIndex < sourceLines.count,
              sourceLines[precedingLineIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty {
            blankLineCount += 1
            precedingLineIndex -= 1
        }
        return blankLineCount
    }

    mutating func visitDocument(_ document: Document) {
        for child in document.children {
            // CommonMark discards source blank lines between blocks. Restore
            // them with fixed, sanitizer-safe markers before rendering each
            // block so consecutive empty lines remain distinct in preview.
            for _ in 0..<precedingBlankLineCount(for: child) {
                result += "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n"
            }
            visit(child)
        }
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if renderAlertIfPresent(blockQuote) {
            return
        }
        if options.contains(.parseAsides),
           let aside = Aside(blockQuote, tagRequirement: .requireSingleWordTag) {
            result += "<aside data-kind=\"\(escapeAttribute(aside.kind.rawValue))\">\n"
            for child in aside.content {
                visit(child)
            }
            result += "</aside>\n"
        } else {
            result += "<blockquote\(sourceLineAttribute(blockQuote))>\n"
            descendInto(blockQuote)
            result += "</blockquote>\n"
        }
    }

    // GitHub-style alerts: `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`,
    // `> [!WARNING]`, `> [!CAUTION]`. Tag matching is case-insensitive. Any
    // text on the tag line after the closing `]` is used as a custom title;
    // otherwise the alert's default title is used.
    private mutating func renderAlertIfPresent(_ blockQuote: BlockQuote) -> Bool {
        let blocks = Array(blockQuote.children)
        guard let firstPara = blocks.first as? Paragraph else { return false }
        let inlines = Array(firstPara.children)
        guard let firstText = inlines.first as? Text,
              let (kind, prefixLen) = Self.matchAlertTag(firstText.string) else {
            return false
        }

        var firstTextRest = String(firstText.string.dropFirst(prefixLen))
        if firstTextRest.hasPrefix(" ") {
            firstTextRest.removeFirst()
        }

        var titleInlinesAfter: [Markup] = []
        var firstParaBody: [Markup] = []
        var pastTitle = false
        for inline in inlines.dropFirst() {
            if !pastTitle {
                if inline is SoftBreak || inline is LineBreak {
                    pastTitle = true
                    continue
                }
                titleInlinesAfter.append(inline)
            } else {
                firstParaBody.append(inline)
            }
        }

        let hasCustomTitle = !firstTextRest.trimmingCharacters(in: .whitespaces).isEmpty
            || !titleInlinesAfter.isEmpty

        result += "<div class=\"markdown-alert markdown-alert-\(kind.rawValue)\">\n"
        result += "<p class=\"markdown-alert-title\">"
        result += kind.iconSVG
        result += " "
        if hasCustomTitle {
            if !firstTextRest.isEmpty {
                result += escapeText(firstTextRest)
            }
            for inline in titleInlinesAfter {
                visit(inline)
            }
        } else {
            result += escapeText(kind.defaultTitle)
        }
        result += "</p>\n"

        if !firstParaBody.isEmpty {
            result += "<p>"
            for inline in firstParaBody {
                visit(inline)
            }
            result += "</p>\n"
        }
        for block in blocks.dropFirst() {
            visit(block)
        }
        result += "</div>\n"
        return true
    }

    private enum AlertKind: String {
        case note, tip, important, warning, caution

        // GitHub Octicons (info, light-bulb, report, alert, stop).
        // Stripped to the path data only — the wrapper is built by `iconSVG`.
        private var iconPath: String {
            switch self {
            case .note:
                return "M0 8a8 8 0 1 1 16 0A8 8 0 0 1 0 8Zm8-6.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM6.5 7.75A.75.75 0 0 1 7.25 7h1a.75.75 0 0 1 .75.75v2.75h.25a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1 0-1.5h.25v-2h-.25a.75.75 0 0 1-.75-.75ZM8 6a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"
            case .tip:
                return "M8 1.5c-2.363 0-4 1.69-4 3.75 0 .984.424 1.625.984 2.304l.214.253c.223.264.47.556.673.848.284.411.537.896.621 1.49a.75.75 0 0 1-1.484.211c-.04-.282-.163-.547-.37-.847a8.456 8.456 0 0 0-.542-.68c-.084-.1-.173-.205-.268-.32C3.201 7.75 2.5 6.766 2.5 5.25 2.5 2.31 4.863 0 8 0s5.5 2.31 5.5 5.25c0 1.516-.701 2.5-1.328 3.259-.095.115-.184.22-.268.319-.207.245-.383.453-.541.681-.208.3-.33.565-.37.847a.751.751 0 0 1-1.485-.212c.084-.593.337-1.078.621-1.489.203-.292.45-.584.673-.848.075-.088.147-.173.213-.253.561-.679.985-1.32.985-2.304 0-2.06-1.637-3.75-4-3.75ZM5.75 12h4.5a.75.75 0 0 1 0 1.5h-4.5a.75.75 0 0 1 0-1.5ZM6 15.25a.75.75 0 0 1 .75-.75h2.5a.75.75 0 0 1 0 1.5h-2.5a.75.75 0 0 1-.75-.75Z"
            case .important:
                return "M0 1.75C0 .784.784 0 1.75 0h12.5C15.216 0 16 .784 16 1.75v9.5A1.75 1.75 0 0 1 14.25 13H8.06l-2.573 2.573A1.458 1.458 0 0 1 3 14.543V13H1.75A1.75 1.75 0 0 1 0 11.25Zm1.75-.25a.25.25 0 0 0-.25.25v9.5c0 .138.112.25.25.25h2a.75.75 0 0 1 .75.75v2.19l2.72-2.72a.749.749 0 0 1 .53-.22h6.5a.25.25 0 0 0 .25-.25v-9.5a.25.25 0 0 0-.25-.25Zm7 2.25v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 9a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
            case .warning:
                return "M6.457 1.047c.659-1.234 2.427-1.234 3.086 0l6.082 11.378A1.75 1.75 0 0 1 14.082 15H1.918a1.75 1.75 0 0 1-1.543-2.575Zm1.763.707a.25.25 0 0 0-.44 0L1.698 13.132a.25.25 0 0 0 .22.368h12.164a.25.25 0 0 0 .22-.368Zm.53 3.996v2.5a.75.75 0 0 1-1.5 0v-2.5a.75.75 0 0 1 1.5 0ZM9 11a1 1 0 1 1-2 0 1 1 0 0 1 2 0Z"
            case .caution:
                return "M4.47.22A.749.749 0 0 1 5 0h6c.199 0 .389.079.53.22l4.25 4.25c.141.14.22.331.22.53v6a.749.749 0 0 1-.22.53l-4.25 4.25A.749.749 0 0 1 11 16H5a.749.749 0 0 1-.53-.22L.22 11.53A.749.749 0 0 1 0 11V5c0-.199.079-.389.22-.53Zm.84 1.28L1.5 5.31v5.38l3.81 3.81h5.38l3.81-3.81V5.31L10.69 1.5ZM8 4a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 8 4Zm0 8a1 1 0 1 1 0-2 1 1 0 0 1 0 2Z"
            }
        }

        var iconSVG: String {
            "<svg class=\"markdown-alert-icon\" viewBox=\"0 0 16 16\" width=\"16\" height=\"16\" aria-hidden=\"true\"><path d=\"\(iconPath)\"></path></svg>"
        }

        var defaultTitle: String {
            switch self {
            case .note: return "Note"
            case .tip: return "Tip"
            case .important: return "Important"
            case .warning: return "Warning"
            case .caution: return "Caution"
            }
        }
    }

    private static func matchAlertTag(_ text: String) -> (AlertKind, Int)? {
        let tags: [(String, AlertKind)] = [
            ("[!note]", .note),
            ("[!tip]", .tip),
            ("[!important]", .important),
            ("[!warning]", .warning),
            ("[!caution]", .caution),
        ]
        let lower = text.lowercased()
        for (tag, kind) in tags where lower.hasPrefix(tag) {
            return (kind, tag.count)
        }
        return nil
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let info = CodeFenceInfo(rawInfoString: codeBlock.language)
        let languageAttr = info.language.isEmpty
            ? ""
            : " class=\"language-\(escapeAttribute(info.language))\""
        result += "<pre\(sourceLineAttribute(codeBlock))><code\(languageAttr)>\(escapeText(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        result += "<h\(heading.level)\(sourceLineAttribute(heading))>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr\(sourceLineAttribute(thematicBreak)) />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Raw HTML blocks are passed through per CommonMark.
        result += html.rawHTML
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            result += "<li class=\"task-list-item\"\(sourceLineAttribute(listItem))>"
            result += "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled=\"\""
            if checkbox == .checked {
                result += " checked=\"\""
            }
            result += " /> "
        } else {
            result += "<li\(sourceLineAttribute(listItem))>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start: String
        if orderedList.startIndex != 1 {
            start = " start=\"\(orderedList.startIndex)\""
        } else {
            start = ""
        }
        result += "<ol\(start)\(sourceLineAttribute(orderedList))>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul\(sourceLineAttribute(unorderedList))>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p\(sourceLineAttribute(paragraph))>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        result += "<table\(sourceLineAttribute(table))>\n"
        tableColumnAlignments = table.columnAlignments
        tableSourceRows = sourceRows(for: table)
        currentTableRow = 0
        descendInto(table)
        tableColumnAlignments = nil
        tableSourceRows = nil
        result += "</table>\n"
    }

    private func sourceRows(for table: Table) -> [[String]]? {
        guard let range = table.range else { return nil }
        let startIndex = range.lowerBound.line - 1
        let inclusiveEndLine = range.upperBound.column == 1
            && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1
            : range.upperBound.line
        let endIndex = inclusiveEndLine - 1
        guard sourceLines.indices.contains(startIndex),
              sourceLines.indices.contains(endIndex),
              startIndex <= endIndex else { return nil }
        return MarkdownTableSource.sourceRows(
            from: Array(sourceLines[startIndex...endIndex])
        )
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
        currentTableRow = 1
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        if !tableBody.isEmpty {
            result += "<tbody>\n"
            descendInto(tableBody)
            result += "</tbody>\n"
        }
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>\n"
        currentTableColumn = 0
        descendInto(tableRow)
        result += "</tr>\n"
        currentTableRow += 1
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard let alignments = tableColumnAlignments,
              currentTableColumn < alignments.count else { return }
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }

        let element = inTableHead ? "th" : "td"
        result += "<\(element) data-table-row=\"\(currentTableRow)\" data-table-column=\"\(currentTableColumn)\""

        if let rows = tableSourceRows,
           rows.indices.contains(currentTableRow),
           rows[currentTableRow].indices.contains(currentTableColumn) {
            let source = rows[currentTableRow][currentTableColumn]
            result += " data-table-markdown=\"\(escapeAttribute(source))\""
        }

        if let alignment = alignments[currentTableColumn] {
            result += " align=\"\(alignment)\""
        }
        currentTableColumn += 1

        if tableCell.rowspan > 1 {
            result += " rowspan=\"\(tableCell.rowspan)\""
        }
        if tableCell.colspan > 1 {
            result += " colspan=\"\(tableCell.colspan)\""
        }

        result += ">"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    // MARK: Inline elements

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(escapeText(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img"
        if let source = image.source, !source.isEmpty {
            result += " src=\"\(escapeAttribute(source))\""
        }
        if let title = image.title, !title.isEmpty {
            result += " title=\"\(escapeAttribute(title))\""
        }
        result += " />"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br />\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        // Obsidian-style breaks: a single newline in the source is a real
        // line break, not a CommonMark soft-wrap space.
        result += "<br />\n"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a"
        if let destination = link.destination {
            result += " href=\"\(escapeAttribute(destination))\""
        }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        result += escapeText(text.string)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) {
        if let destination = symbolLink.destination {
            result += "<code>\(escapeText(destination))</code>"
        }
    }

    mutating func visitInlineAttributes(_ attributes: InlineAttributes) {
        result += "<span data-attributes=\"\(escapeAttribute(attributes.attributes))\""

        if options.contains(.parseInlineAttributeClass) {
            let wrappedAttributes = "{\(attributes.attributes)}"
            if let attributesData = wrappedAttributes.data(using: .utf8) {
                struct ParsedAttributes: Decodable {
                    var `class`: String
                }
                let decoder = JSONDecoder()
                decoder.allowsJSON5 = true
                if let parsed = try? decoder.decode(ParsedAttributes.self, from: attributesData) {
                    result += " class=\"\(escapeAttribute(parsed.class))\""
                }
            }
        }

        result += ">"
        descendInto(attributes)
        result += "</span>"
    }
}

private nonisolated func escapeText(_ string: String) -> String {
    var out = ""
    out.reserveCapacity(string.count)
    for ch in string {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        default: out.append(ch)
        }
    }
    return out
}

private nonisolated func escapeAttribute(_ string: String) -> String {
    var out = ""
    out.reserveCapacity(string.count)
    for ch in string {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.append(ch)
        }
    }
    return out
}
