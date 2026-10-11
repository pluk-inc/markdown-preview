import Foundation
import ImageIO
import UniformTypeIdentifiers

enum InlineLocalAssets {

    struct Attachment: Equatable {
        let data: Data
        /// Lowercased file extension of the source (e.g. `"png"`). Empty if
        /// the source URL had none. Lets the caller derive a UTType.
        let pathExtension: String
    }

    struct Result {
        let html: String
        let attachments: [String: Attachment]
    }

    static func rewriteRelativeImages(
        html: String,
        baseDirectory: URL,
        reader: (URL) throws -> Data,
        perImageByteCap: Int = 4 * 1024 * 1024,
        cumulativeByteCap: Int = 8 * 1024 * 1024
    ) -> Result {
        let nsHtml = html as NSString
        let matches = imgSrcRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else {
            return Result(html: html, attachments: [:])
        }

        let base = baseDirectory.standardizedFileURL
        var attachments: [String: Attachment] = [:]
        var srcToCID: [String: String] = [:]
        var cumulativeBytes = 0
        var output = ""
        output.reserveCapacity(html.count)
        var cursor = 0

        for match in matches {
            output += nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))

            let prefix = nsHtml.substring(with: match.range(at: 1))
            let src = nsHtml.substring(with: match.range(at: 3))
            let suffix = nsHtml.substring(with: match.range(at: 4))

            let replacement: String
            if let existingCID = srcToCID[src] {
                replacement = "\(prefix)cid:\(existingCID)\(suffix)"
            } else if let resolved = resolveRelative(src: src, baseDirectory: baseDirectory),
                      let data = try? reader(resolved),
                      data.count <= perImageByteCap,
                      cumulativeBytes + data.count <= cumulativeByteCap,
                      isDescendantOrSame(resolved, of: base) || isImageData(data, url: resolved) {
                let cid = "md-asset-\(attachments.count)"
                attachments[cid] = Attachment(
                    data: data,
                    pathExtension: resolved.pathExtension.lowercased()
                )
                srcToCID[src] = cid
                cumulativeBytes += data.count
                replacement = "\(prefix)cid:\(cid)\(suffix)"
            } else {
                replacement = nsHtml.substring(with: match.range)
            }

            output += replacement
            cursor = match.range.location + match.range.length
        }
        output += nsHtml.substring(from: cursor)

        return Result(html: output, attachments: attachments)
    }

    static func dataURLHTML(from result: Result) -> String {
        let nsHtml = result.html as NSString
        let matches = imgSrcRegex.matches(
            in: result.html,
            range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return result.html }

        var output = ""
        output.reserveCapacity(result.html.count)
        var cursor = 0

        for match in matches {
            output += nsHtml.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))

            let src = nsHtml.substring(with: match.range(at: 3))
            let contentID = src.hasPrefix("cid:") ? String(src.dropFirst(4)) : ""
            if let attachment = result.attachments[contentID] {
                let prefix = nsHtml.substring(with: match.range(at: 1))
                let suffix = nsHtml.substring(with: match.range(at: 4))
                let mimeType = UTType(filenameExtension: attachment.pathExtension)?.preferredMIMEType
                    ?? "application/octet-stream"
                let dataURL = "data:\(mimeType);base64,\(attachment.data.base64EncodedString())"
                output += "\(prefix)\(dataURL)\(suffix)"
            } else {
                output += nsHtml.substring(with: match.range)
            }

            cursor = match.range.location + match.range.length
        }
        output += nsHtml.substring(from: cursor)
        return output
    }

    // Matches the double-quoted image tags emitted by MarkdownHTML's renderer
    // and the single-quoted ones authors write in raw HTML. Other attributes'
    // quoted values are skipped whole, so `src` text inside them never
    // matches, and the whitespace before `src` skips `data-src`. Group 2 is
    // the quote, group 3 the value, group 4 the closing quote.
    private static let imgSrcRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(<img\b(?:[^>"']|"[^"]*"|'[^']*')*?\ssrc\s*=\s*(["']))([\s\S]*?)(\2)"#,
            options: [.caseInsensitive]
        )
    }()

    /// Returns nil for srcs that should not be rewritten (URLs with a
    /// scheme, fragment refs, protocol-relative `//host` refs, empty values).
    ///
    /// Like the app's `md-asset` scheme, `../` paths and absolute filesystem
    /// paths resolve (#488). Files outside the document folder must have an
    /// image type, so a previewed file can't pull arbitrary files into the page.
    private static func resolveRelative(src attribute: String, baseDirectory: URL) -> URL? {
        // The renderer escapes `&` in attributes (`a&b.png` → `a&amp;b.png`).
        // WebKit would read the unescaped value, so resolve that one.
        let src = decodingCharacterReferences(attribute)
        guard !src.isEmpty else { return nil }
        if src.hasPrefix("#") || src.hasPrefix("//") { return nil }
        if hasURLScheme(src) { return nil }
        let isAbsolute = src.hasPrefix("/")

        // CommonMark renderers percent-encode spaces in image targets;
        // FileManager wants real paths.
        let decoded = src.removingPercentEncoding ?? src
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("#") || decoded.hasPrefix("//") { return nil }
        // Decoding must not turn a relative src into an absolute one.
        if decoded.hasPrefix("/") != isAbsolute { return nil }
        if hasURLScheme(decoded) { return nil }

        let base = baseDirectory.standardizedFileURL
        let candidate = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
        guard isDescendantOrSame(candidate, of: base) || isImageFile(candidate) else { return nil }
        return candidate
    }

    /// Decodes the character references an attribute value can carry:
    /// the XML named ones (case-sensitive, as in HTML) and decimal or hex
    /// numeric ones. Anything else, such as a bare `&` in raw HTML, stays
    /// as written.
    private static func decodingCharacterReferences(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let nsValue = value as NSString
        var output = ""
        var cursor = 0
        for match in characterReferenceRegex.matches(
            in: value,
            range: NSRange(location: 0, length: nsValue.length)
        ) {
            let body = nsValue.substring(with: match.range(at: 1))
            let decoded: String?
            switch body {
            case "amp", "AMP": decoded = "&"
            case "lt", "LT": decoded = "<"
            case "gt", "GT": decoded = ">"
            case "quot", "QUOT": decoded = "\""
            case "apos": decoded = "'"
            case _ where body.hasPrefix("#"):
                let isHex = body.hasPrefix("#x") || body.hasPrefix("#X")
                let digits = body.dropFirst(isHex ? 2 : 1)
                decoded = UInt32(digits, radix: isHex ? 16 : 10).map(htmlNumericCharacter) ?? "\u{FFFD}"
            default: decoded = nil
            }
            guard let decoded else { continue }
            output += nsValue.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += decoded
            cursor = match.range.location + match.range.length
        }
        output += nsValue.substring(from: cursor)
        return output
    }

    /// HTML reads 0x80–0x9F as Windows-1252 (`&#x80;` is `€`), and NUL,
    /// surrogates, and values past U+10FFFF as U+FFFD.
    private static func htmlNumericCharacter(_ value: UInt32) -> String {
        if (0x80...0x9F).contains(value),
           let character = String(bytes: [UInt8(value)], encoding: .windowsCP1252) {
            return character
        }
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return String(Character(scalar))
    }

    private static let characterReferenceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"&([a-zA-Z]+|#[0-9]+|#[xX][0-9a-fA-F]+);"#)
    }()

    private static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// The name check alone trusts the filename: `x.png` can be a symlink to,
    /// or a rename of, any readable file. Outside the document folder the
    /// bytes must decode as an image too.
    private static func isImageData(_ data: Data, url: URL) -> Bool {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .svg) == true {
            return SVGRootCheck.hasSVGRoot(data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    private static func hasURLScheme(_ value: String) -> Bool {
        // Reject anything that looks like `scheme:` where scheme is
        // `[a-z][a-z0-9+.-]*` (RFC 3986). Stops short of `:` so paths like
        // `images/foo:bar.png` are still treated as relative.
        guard let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { c in
            c.isLetter || c.isNumber || c == "+" || c == "." || c == "-"
        }
    }

    private static func isDescendantOrSame(_ candidate: URL, of baseDirectory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let basePath = baseDirectory.standardizedFileURL.path
        return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
    }
}

/// Parses only up to the first element: an SVG file must have `<svg>` as its
/// root, wherever it sits after the prolog and comments.
private final class SVGRootCheck: NSObject, XMLParserDelegate {
    private var rootName: String?

    static func hasSVGRoot(_ data: Data) -> Bool {
        let check = SVGRootCheck()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = check
        parser.parse()
        guard let name = check.rootName else { return false }
        return name == "svg" || name.hasSuffix(":svg")
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        rootName = elementName
        parser.abortParsing()
    }
}
