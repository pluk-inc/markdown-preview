//
//  EscapingHTMLFormatter.swift
//  md-preview
//

import Foundation
import Markdown

// Mirrors swift-markdown's HTMLFormatter but HTML-escapes text, code, and
// attribute values. Upstream HTMLFormatter emits unescaped content
// (swift-markdown 0.7.x), so characters like `<`, `>`, and `&` either render
// invisibly or get reinterpreted as HTML — see issue #33.
nonisolated struct EscapingHTMLFormatter: MarkupWalker {
    private(set) var result = ""

    let options: HTMLFormatterOptions

    private var inTableHead = false
    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var currentTableColumn = 0

    init(options: HTMLFormatterOptions = []) {
        self.options = options
    }

    static func format(_ markdown: String, options: HTMLFormatterOptions = []) -> String {
        let document = Document(parsing: markdown)
        var walker = EscapingHTMLFormatter(options: options)
        walker.visit(document)
        return walker.result
    }

    // MARK: Block elements

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
            result += "<blockquote>\n"
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
        result += "<pre><code\(languageAttr)>\(escapeText(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        result += "<h\(heading.level)>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Raw HTML blocks are passed through per CommonMark.
        result += html.rawHTML
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            result += "<li class=\"task-list-item\">"
            result += "<input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled=\"\""
            if checkbox == .checked {
                result += " checked=\"\""
            }
            result += " /> "
        } else {
            result += "<li>"
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
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>\n"
        tableColumnAlignments = table.columnAlignments
        descendInto(table)
        tableColumnAlignments = nil
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
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
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard let alignments = tableColumnAlignments,
              currentTableColumn < alignments.count else { return }
        guard tableCell.colspan > 0, tableCell.rowspan > 0 else { return }

        let element = inTableHead ? "th" : "td"
        result += "<\(element)"

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
        result += "\n"
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
