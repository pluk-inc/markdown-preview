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

    private static let mediaTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml",
    ]

    private static let imgTag = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])

    // `\s` before `src`, not `\b`: `\b` also matches inside `data-src`.
    private static let srcAttribute = try! NSRegularExpression(
        pattern: #"\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive])

    private static let hiddenAttribute = try! NSRegularExpression(
        pattern: #"\shidden(?:\s|=|/?>)"#, options: [.caseInsensitive])

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
            let tag = String(html[tagRange])
            let tagNSRange = NSRange(tag.startIndex..., in: tag)
            guard hiddenAttribute.firstMatch(in: tag, range: tagNSRange) == nil,
                  let attribute = srcAttribute.firstMatch(in: tag, range: tagNSRange),
                  let captured = [1, 2].lazy
                    .compactMap({ Range(attribute.range(at: $0), in: tag) })
                    .first,
                  let source = decodedRelativeSource(String(tag[captured]))
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

    /// The percent-decoded path of a relative `src`, without its query or
    /// fragment. Nil for URLs with a scheme, absolute paths, and `//host`.
    private static func decodedRelativeSource(_ source: String) -> String? {
        let unescaped = source
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        guard !unescaped.isEmpty, !unescaped.hasPrefix("/"), !unescaped.hasPrefix("#"),
              let components = URLComponents(string: unescaped),
              components.scheme == nil, components.host == nil
        else { return nil }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        return path.isEmpty ? nil : path
    }
}
