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
