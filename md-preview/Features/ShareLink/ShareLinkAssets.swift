//
//  ShareLinkAssets.swift
//  md-preview
//
//  Finds the images a rendered document uses, so a share can carry them:
//  files inside the document's folder, and images from the web, downloaded
//  when the link is made. Kept free of AppKit so the SPM helper tests can
//  exercise it without a GUI host.
//

import Foundation

nonisolated enum ShareLinkAssets {

    /// File extension to MIME type; `SharePayload` accepts exactly these types.
    static let mediaTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "svg": "image/svg+xml",
    ]

    // A `>` inside a quoted value (alt="a > b") does not end the tag.
    private static let imgTag = try! NSRegularExpression(
        pattern: #"<img\b(?:[^>"']|"[^"]*"|'[^']*')*>"#, options: [.caseInsensitive])

    /// One attribute: a name and an optional double-quoted, single-quoted,
    /// or unquoted value. Read one after another from the tag's start, so
    /// text inside a quoted value (alt="a src=b.png") is never a name.
    private static let attribute = try! NSRegularExpression(
        // An unquoted value runs to whitespace or `>`, as HTML reads it,
        // so `src=img/a.png?v=1` keeps its `=`.
        pattern: #"([^\s"'=<>/`]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>][^\s>]*)))?"#)

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
        let base = directory.standardizedFileURL
        let root = base.resolvingSymlinksInPath()
        var seen = Set<String>()
        var assets: [SharePayload.Asset] = []

        for src in shownImageSources(in: html) {
            guard let source = decodedRelativeSource(src) else { continue }

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

    /// The `http(s)` addresses of the images `articleHTML` shows, each once,
    /// with character references decoded as the browser reads them.
    static func webImageSources(articleHTML html: String) -> [String] {
        var seen = Set<String>()
        return shownImageSources(in: html)
            .map(decodingCharacterReferences)
            .filter { SharePayload.isWebSource($0) && seen.insert($0).inserted }
    }

    /// The largest web image that can fit. base64 makes an image a third
    /// larger in the JSON, but DEFLATE takes most of that back, so an image
    /// costs the envelope about its own size.
    static let maxWebImageBytes = ShareLinkCrypto.maxEnvelopeBytes

    /// The asset lists to seal, most first: the local images and as many
    /// web images as fit by size (about its own size each, see
    /// `maxWebImageBytes`), the largest left out first; then the local
    /// images alone; then none. Sealing still checks the real size.
    static func assetsToTry(_ assets: [SharePayload.Asset]) -> [[SharePayload.Asset]] {
        let local = assets.filter { $0.source == nil }
        let size = { (assets: [SharePayload.Asset]) in assets.reduce(0) { $0 + $1.data.count } }
        var web = assets.filter { $0.source != nil }.sorted { $0.data.count < $1.data.count }
        while !web.isEmpty, size(local) + size(web) > ShareLinkCrypto.maxEnvelopeBytes {
            web.removeLast()
        }
        let kept = Set(web.map(\.path))
        let first = assets.filter { $0.source == nil || kept.contains($0.path) }
        var lists = [first]
        if first.count > local.count { lists.append(local) }
        if !local.isEmpty { lists.append([]) }
        return lists
    }

    /// MIME type to the extension a web image's asset gets.
    private static let extensionForType = Dictionary(mediaTypes.map { ($0.value, $0.key) }, uniquingKeysWith: min)

    private static let maxParallelDownloads = 6

    /// Downloads the web images, six at a time. Each asset keeps the address
    /// the document uses, under web/1.png and so on (another folder name
    /// when the document has its own web/ folder). An image that fails, is
    /// too large, or is not a supported type stays out; the web viewer
    /// shows its description instead.
    static func downloadWebImages(
        _ sources: [String],
        takenPaths: Set<String>,
        fetch: @escaping @Sendable (URL) async throws -> (Data, URLResponse) = fetchWebImage
    ) async -> [SharePayload.Asset] {
        var folder = "web"
        while takenPaths.contains(where: { $0 == folder || $0.hasPrefix(folder + "/") }) { folder += "_" }
        let webFolder = folder
        let download: @Sendable (Int) async -> (Int, SharePayload.Asset?) = { index in
            (index, await webImage(sources[index], path: "\(webFolder)/\(index + 1)", fetch: fetch))
        }
        var slots = [SharePayload.Asset?](repeating: nil, count: sources.count)
        await withTaskGroup(of: (Int, SharePayload.Asset?).self) { group in
            var next = min(maxParallelDownloads, sources.count)
            for index in 0..<next { group.addTask { await download(index) } }
            for await (index, asset) in group {
                slots[index] = asset
                guard next < sources.count else { continue }
                let index = next
                next += 1
                group.addTask { await download(index) }
            }
        }
        return slots.compactMap { $0 }
    }

    /// The image at `source` as an asset at `path` plus its extension, or
    /// nil when it cannot go in the share.
    private static func webImage(
        _ source: String, path: String,
        fetch: @Sendable (URL) async throws -> (Data, URLResponse)
    ) async -> SharePayload.Asset? {
        guard let url = URL(string: source), let fetched = try? await fetch(url) else { return nil }
        let (data, response) = fetched
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty, data.count <= maxWebImageBytes,
              let type = webImageType(response: response, url: url),
              let fileExtension = extensionForType[type]
        else { return nil }
        return .init(path: "\(path).\(fileExtension)", type: type, data: data, source: source)
    }

    /// No cookies, no cache, 20 seconds in all for each image.
    private static let webImageSession = ShareLinkClient.makeSession(resourceTimeout: 20)

    /// One image from the web. It stops reading as soon as the image is
    /// larger than any share can carry.
    @Sendable static func fetchWebImage(_ url: URL) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await webImageSession.bytes(from: url)
        guard response.expectedContentLength <= maxWebImageBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        data.reserveCapacity(max(0, Int(response.expectedContentLength)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxWebImageBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        return (data, response)
    }

    /// The image's type from the server, or from its address's extension
    /// when the server's type is generic; nil when neither is supported.
    private static func webImageType(response: URLResponse, url: URL) -> String? {
        if let type = response.mimeType?.lowercased(), SharePayload.allowedAssetTypes.contains(type) {
            return type
        }
        return mediaTypes[url.pathExtension.lowercased()]
    }

    /// The `src` of each image the preview shows, as written in the HTML.
    private static func shownImageSources(in html: String) -> [String] {
        let html = inertHTML.stringByReplacingMatches(
            in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
        return imgTag.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let tagRange = Range(match.range, in: html),
                  let attributes = attributes(ofTag: String(html[tagRange])),
                  attributes["hidden"] == nil
            else { return nil }
            return attributes["src"]
        }
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
