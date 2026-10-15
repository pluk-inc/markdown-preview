//
//  EPUBPackage.swift
//  md-preview
//

import Foundation

/// An EPUB 3 book assembled from already-converted XHTML sections. Pure
/// string and byte work, so it can be built off the main actor and tested
/// without WebKit.
nonisolated struct EPUBPackage: Sendable {
    /// One spine item. `xhtml` is a serialized, well-formed element that
    /// becomes the content of `<body>`.
    struct Section: Sendable {
        var fileName: String
        var title: String
        var xhtml: String
        var containsMath = false
    }

    /// A table-of-contents entry. `href` is relative to the content folder.
    struct Heading: Sendable {
        var level: Int
        var title: String
        var href: String
    }

    /// A picture stored next to the sections; `path` is relative to them.
    struct Resource: Sendable {
        var path: String
        var mediaType: String
        var data: Data
    }

    var title: String
    var authors: [String] = []
    var language: String
    var identifier = "urn:uuid:" + UUID().uuidString.lowercased()
    var modified = Date()
    var sections: [Section]
    var headings: [Heading] = []
    var resources: [Resource] = []

    static let contentFolder = "OEBPS"

    enum PackageError: Error {
        /// A section is not well-formed XML; a reader would show nothing for it.
        case malformedSection(String)
    }

    func archiveData() throws -> Data {
        var archive = ZIPArchiveWriter()
        try archive.add(Data("application/epub+zip".utf8), at: "mimetype", compression: .stored)
        try archive.add(Data(Self.containerDocument.utf8), at: "META-INF/container.xml")
        let folder = Self.contentFolder
        try archive.add(Data(packageDocument.utf8), at: "\(folder)/content.opf")
        try archive.add(Data(navigationDocument.utf8), at: "\(folder)/nav.xhtml")
        try archive.add(Data(Self.stylesheet.utf8), at: "\(folder)/style.css")
        for section in sections {
            let document = Data(contentDocument(for: section).utf8)
            // XMLDocument, unlike XMLParser, also rejects a prefix that has no
            // namespace bound to it.
            guard (try? XMLDocument(data: document)) != nil else {
                throw PackageError.malformedSection(section.fileName)
            }
            try archive.add(document, at: "\(folder)/\(section.fileName)")
        }
        for resource in resources {
            // PNG and JPEG are already compressed.
            try archive.add(resource.data, at: "\(folder)/\(resource.path)", compression: .stored)
        }
        return try archive.finish()
    }

    // MARK: - Documents

    private static let containerDocument = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
    <rootfiles>
    <rootfile full-path="\(contentFolder)/content.opf" media-type="application/oebps-package+xml"/>
    </rootfiles>
    </container>

    """

    var packageDocument: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let creators = authors.map { "<dc:creator>\(Self.escape($0))</dc:creator>\n" }.joined()
        let sectionItems = sections.enumerated().map { index, section in
            // Readers reject a document that uses MathML without declaring it.
            let attribute = section.containsMath ? " properties=\"mathml\"" : ""
            return """
            <item id="section-\(index + 1)" href="\(Self.escape(section.fileName))" \
            media-type="application/xhtml+xml"\(attribute)/>
            """
        }
        let resourceItems = resources.enumerated().map { index, resource in
            """
            <item id="resource-\(index + 1)" href="\(Self.escape(resource.path))" \
            media-type="\(Self.escape(resource.mediaType))"/>
            """
        }
        let spine = sections.indices.map { "<itemref idref=\"section-\($0 + 1)\"/>" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" \
        xml:lang="\(Self.escape(language))">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="book-id">\(Self.escape(identifier))</dc:identifier>
        <dc:title>\(Self.escape(title))</dc:title>
        <dc:language>\(Self.escape(language))</dc:language>
        \(creators)<meta property="dcterms:modified">\(formatter.string(from: modified))</meta>
        </metadata>
        <manifest>
        <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="style" href="style.css" media-type="text/css"/>
        \((sectionItems + resourceItems).joined(separator: "\n"))
        </manifest>
        <spine>
        \(spine.joined(separator: "\n"))
        </spine>
        </package>

        """
    }

    var navigationDocument: String {
        var entries = headings.filter { !$0.title.isEmpty }
        if entries.isEmpty, let first = sections.first {
            // The table of contents must not be empty.
            entries = [Heading(level: 1, title: title, href: first.fileName)]
        }
        var list = ""
        var open: [Int] = []
        for entry in entries {
            // Leave a nested list only when the entry belongs at or above its
            // parent; an item may hold one list, so it is never reopened.
            while open.count > 1, open[open.count - 2] >= entry.level {
                list += "</li>\n</ol>\n"
                open.removeLast()
            }
            if let last = open.last, last >= entry.level {
                // Skipped levels (h1, h3, h2) and a heading shallower than the
                // first one become siblings in the list that is already open.
                list += "</li>\n"
                open[open.count - 1] = entry.level
            } else {
                list += "<ol>\n"
                open.append(entry.level)
            }
            list += "<li><a href=\"\(Self.escape(entry.href))\">\(Self.escape(entry.title))</a>"
        }
        list += String(repeating: "</li>\n</ol>\n", count: open.count)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" \
        lang="\(Self.escape(language))" xml:lang="\(Self.escape(language))">
        <head>
        <meta charset="UTF-8"/>
        <title>\(Self.escape(title))</title>
        </head>
        <body>
        <nav epub:type="toc" id="toc">
        <h1>\(Self.escape(title))</h1>
        \(list)</nav>
        </body>
        </html>

        """
    }

    func contentDocument(for section: Section) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="\(Self.escape(language))" \
        xml:lang="\(Self.escape(language))">
        <head>
        <meta charset="UTF-8"/>
        <title>\(Self.escape(section.title.isEmpty ? title : section.title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(section.xhtml)
        </body>
        </html>

        """
    }

    /// Escapes text for XML content and attributes, dropping the control
    /// characters XML 1.0 cannot represent at all.
    static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Stylesheet

    /// Structure only. Typeface, text size, margins and page colours belong to
    /// the reading app, so nothing here sets them for body text. Code blocks
    /// are the exception: syntax colours need a known background.
    static let stylesheet: String = {
        // E-readers cannot be relied on for CSS variables; resolve the app's
        // light code palette into literal colours.
        var codeColors = MarkdownHTML.highlightThemeCSS
        for line in MarkdownHTML.lightCodePaletteCSS.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
            codeColors = codeColors.replacingOccurrences(
                of: "var(\(name))", with: value == "var(--text)" ? codeText : value)
        }
        return baseStylesheet + codeColors + "\n"
    }()

    private static let codeText = "#1d1d1f"

    private static let baseStylesheet = """
    h1, h2, h3, h4, h5, h6 {
        margin: 1.4em 0 0.5em;
        line-height: 1.25;
        page-break-after: avoid;
        break-after: avoid;
    }
    h1 { font-size: 1.6em; }
    h2 { font-size: 1.35em; }
    h3 { font-size: 1.15em; }
    h4, h5, h6 { font-size: 1em; }
    p { margin: 0 0 0.8em; }
    ul, ol { margin: 0 0 0.8em; padding-inline-start: 1.6em; }
    li > p { margin-bottom: 0.3em; }
    li.task-list-item { list-style-type: none; }
    li.task-list-item > p:first-of-type { display: inline; }
    .md-source-list-indent-step { display: block; padding-inline-start: 1.6em; }
    .md-source-list-line { display: block; }
    .md-inline-tab { white-space: pre; }
    /* Readers left-align paragraphs with a rule of their own, so a
       right-to-left block asks for the right edge, as in the preview. */
    [dir="rtl"] { text-align: right; }
    /* Logical sides, so right-to-left blocks indent from their own start. */
    blockquote {
        margin: 1em 0;
        padding: 0;
        padding-inline-start: 1em;
        border-inline-start: 0.25em solid #b0b0b5;
    }
    hr { margin: 1.5em 0; border: 0; border-top: 1px solid #b0b0b5; }
    img { max-width: 100%; height: auto; }
    figure { margin: 1em 0; text-align: center; }
    sup { line-height: 0; }
    mark { background: #fff3a3; color: \(codeText); }
    pre, code, kbd, samp { font-family: monospace; }
    code { font-size: 0.9em; }
    /* Reading apps cannot scroll sideways, so long lines wrap. */
    pre {
        margin: 1em 0;
        padding: 0.7em 0.9em;
        border: 1px solid #e0e0e3;
        border-radius: 4px;
        background: #f7f7f8;
        color: \(codeText);
        font-size: 0.8em;
        line-height: 1.4;
        white-space: pre-wrap;
        word-wrap: break-word;
        overflow-wrap: break-word;
    }
    pre code { font-size: 1em; }
    /* A page cannot scroll sideways either. Columns narrow by hyphenating
       words and breaking links; numbers and short words stay whole, and
       tables with many columns use smaller type. */
    table { margin: 1em 0; max-width: 100%; border-collapse: collapse; font-size: 0.85em; }
    table.md-many-columns { font-size: 0.7em; }
    th, td {
        padding: 0.3em 0.5em;
        border: 1px solid #b0b0b5;
        vertical-align: top;
        -webkit-hyphens: auto;
        hyphens: auto;
    }
    th a, td a, th code, td code { overflow-wrap: anywhere; }
    .md-frontmatter th { text-align: start; }
    .md-fm-pill { margin-inline-end: 0.6em; }
    .markdown-alert {
        margin: 1em 0;
        padding: 0.1em 0;
        padding-inline-start: 1em;
        border-inline-start: 0.25em solid #696969;
    }
    .markdown-alert-title { font-weight: bold; }
    .math-display { margin: 1em 0; text-align: center; }
    .footnotes { font-size: 0.9em; }
    .footnote-backref { text-decoration: none; }
    summary { font-weight: bold; }

    """
}
