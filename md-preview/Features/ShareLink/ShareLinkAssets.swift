//
//  ShareLinkAssets.swift
//  md-preview
//
//  Finds the local images a rendered document uses, so a share can carry
//  them. Only files inside the document's folder go along; remote images
//  stay links. Kept free of AppKit so the SPM helper tests can exercise it
//  without a GUI host.
//

import Foundation

nonisolated enum ShareLinkAssets {

    /// File extension to MIME type; `SharePayload` accepts exactly these types.
    static let mediaTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml",
    ]

    private static let imgTag = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    /// One attribute: a name and an optional double-quoted, single-quoted,
    /// or unquoted value. Read one after another from the tag's start, so
    /// text inside a quoted value (alt="a src=b.png") is never a name.
    private static let attribute = try! NSRegularExpression(
        pattern: #"([^\s"'=<>/`]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?"#)

    private static let characterReference = try! NSRegularExpression(
        pattern: #"&(?:#[xX]([0-9a-fA-F]{1,6})|#([0-9]{1,7})|(amp|quot|apos|lt|gt));"#)

    /// HTML that the preview never shows: comments and the contents of
    /// elements that do not render. An image written there must not be
    /// uploaded with the share without the user ever seeing it.
    private static let inertHTML = try! NSRegularExpression(
        pattern: #"<!--[\s\S]*?(?:-->|$)|<(script|style|template|textarea|noscript|title|xmp)\b[\s\S]*?</\1\s*>"#,
        options: [.caseInsensitive])

    /// The images `articleHTML` shows by relative path, read from
    /// `directory`. Each asset keeps the path the document uses for it.
    static func collect(articleHTML html: String,
                        directory: URL,
                        reader: (URL) throws -> Data = { try Data(contentsOf: $0) })
        -> [SharePayload.Asset] {
        let html = inertHTML.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        let base = directory.standardizedFileURL
        let root = base.resolvingSymlinksInPath()
        var seen = Set<String>()
        var assets: [SharePayload.Asset] = []

        for match in imgTag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            guard let attributes = attributes(ofTag: String(html[tagRange])),
                  attributes["hidden"] == nil,
                  let src = attributes["src"],
                  let source = decodedRelativeSource(src)
            else { continue }

            // The authored path names the asset, because the HTML refers to
            // it by that name; the resolved file decides confinement and is
            // what gets read, so a symlink cannot reach outside the folder.
            let authored = base.appendingPathComponent(source).standardizedFileURL
            let file = authored.resolvingSymlinksInPath()
            guard authored != base, authored.isDescendantOrSame(of: base),
                  file != root, file.isDescendantOrSame(of: root),
                  let type = mediaTypes[file.pathExtension.lowercased()]
            else { continue }
            let path = String(authored.path.dropFirst(base.path.count + 1))
            guard seen.insert(path).inserted, let data = try? reader(file) else { continue }
            assets.append(.init(path: path, type: type, data: data))
        }
        return assets
    }

    /// The tag's attributes by lowercased name, the first of each name
    /// winning as in HTML. Nil when the tag has text no attribute accounts
    /// for, such as an unclosed quote: the browser may read that tag
    /// differently, so its image is not uploaded.
    private static func attributes(ofTag tag: String) -> [String: String]? {
        let body = tag.dropFirst(4).dropLast() // "<img" and ">"
        let text = String(body)
        var attributes: [String: String] = [:]
        var cursor = text.startIndex
        for match in attribute.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  text[cursor..<whole.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "/" }),
                  let name = Range(match.range(at: 1), in: text)
            else { return nil }
            cursor = whole.upperBound
            let value = [2, 3, 4].lazy.compactMap { Range(match.range(at: $0), in: text) }.first
            let key = text[name].lowercased()
            if attributes[key] == nil { attributes[key] = value.map { String(text[$0]) } ?? "" }
        }
        guard text[cursor...].allSatisfy({ $0.isWhitespace || $0 == "/" }) else { return nil }
        return attributes
    }

    /// The percent-decoded path of a relative `src`, without its query or
    /// fragment. Nil for URLs with a scheme, absolute paths, and `//host`.
    private static func decodedRelativeSource(_ source: String) -> String? {
        let unescaped = decodingCharacterReferences(source)
        guard !unescaped.isEmpty, !unescaped.hasPrefix("/"), !unescaped.hasPrefix("#"),
              let components = URLComponents(string: unescaped),
              components.scheme == nil, components.host == nil
        else { return nil }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.isEmpty ? nil : path
    }

    /// Numeric (`&#32;`, `&#x2F;`) and the common named references, in one
    /// pass, as an HTML parser reads them: `&#38;quot;` stays `&quot;`.
    private static func decodingCharacterReferences(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">"]
        let result = NSMutableString(string: text)
        for match in characterReference.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let replacement: String?
            if let name = Range(match.range(at: 3), in: text) {
                replacement = named[String(text[name])]
            } else {
                let hex = match.range(at: 1).location != NSNotFound
                replacement = Range(match.range(at: hex ? 1 : 2), in: text)
                    .flatMap { UInt32(text[$0], radix: hex ? 16 : 10) }
                    .flatMap(Unicode.Scalar.init)
                    .map { String(Character($0)) }
            }
            if let replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }
}
