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

    private static let imgSrc = try! NSRegularExpression(
        // `\s` before `src`, not `\b`: `\b` also matches inside `data-src`.
        pattern: #"<img\b[^>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
        options: [.caseInsensitive])

    /// The images `articleHTML` references by relative path, read from
    /// `directory`. Each asset's path is relative to `directory`.
    static func collect(articleHTML html: String,
                        directory: URL,
                        reader: (URL) throws -> Data = { try Data(contentsOf: $0) })
        -> [SharePayload.Asset] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var seen = Set<String>()
        var assets: [SharePayload.Asset] = []

        let range = NSRange(html.startIndex..., in: html)
        for match in imgSrc.matches(in: html, range: range) {
            let captured = [1, 2].lazy
                .compactMap { Range(match.range(at: $0), in: html) }
                .first
            guard let captured,
                  let source = decodedRelativeSource(String(html[captured]))
            else { continue }

            let file = root.appendingPathComponent(source).standardizedFileURL
                .resolvingSymlinksInPath()
            guard file != root, file.isDescendantOrSame(of: root),
                  let type = mediaTypes[file.pathExtension.lowercased()]
            else { continue }
            let path = String(file.path.dropFirst(root.path.count + 1))
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
