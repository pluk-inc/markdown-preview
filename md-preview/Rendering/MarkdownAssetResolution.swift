//
//  MarkdownAssetResolution.swift
//  md-preview
//

import Foundation
import Markdown

/// Pure-Foundation path logic for the `md-asset` custom scheme, shared by
/// the scheme handler (asset serving) and the web view's navigation
/// delegate (link clicks). WebKit-free so it can be unit-tested in the
/// SPM helper package.
///
/// The rendered page's `<base>` mirrors the document folder's absolute
/// filesystem path, so WebKit resolves relative references — including
/// `../` links into parent folders — before they ever reach the app. An
/// `md-asset` URL's path therefore *is* the absolute path of the file it
/// names. Reads outside the document folder are covered by the app's
/// read-only absolute-path sandbox exception.
nonisolated enum MarkdownAssetResolution {

    static let scheme = "md-asset"

    /// Base href used when the document has no file location (unsaved
    /// documents, the vendor warmup page): relative references cannot
    /// resolve to files, while vendor scripts — absolute
    /// `md-asset:///__vendor/…` URLs — still load.
    static let rootBaseHref = "\(scheme):///"

    /// `<base href>` value for a document folder: an `md-asset` URL whose
    /// percent-encoded path mirrors the folder's absolute path, with a
    /// trailing slash so relative references resolve inside the folder and
    /// `../` has room to climb before hitting the URL root.
    static func baseHref(forFolder folder: URL) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        var path = folder.standardizedFileURL.path
        if !path.hasSuffix("/") { path.append("/") }
        components.path = path
        return components.string ?? rootBaseHref
    }

    /// Maps an `md-asset://…` URL to the file it names. Returns `nil` for
    /// other schemes, for URLs with a host (well-formed `md-asset` URLs have
    /// none — this keeps protocol-relative references like `//host/pic.png`
    /// from aliasing local files), and for paths that don't name a
    /// filesystem location (empty, or the bare root).
    static func fileURL(for assetURL: URL) -> URL? {
        guard assetURL.scheme == scheme else { return nil }
        if let host = assetURL.host, !host.isEmpty { return nil }
        let path = assetURL.path
        guard path.count > 1, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    // MARK: - Image storage helpers

    /// Directory for images pasted into a Markdown file.
    static func picturesDirectory(forMarkdownFile fileURL: URL) -> URL {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-pictures", isDirectory: true)
    }

    /// Returns the next integer name without reusing a number already present
    /// in the pictures directory, regardless of its image extension.
    static func nextIntegerFileName(
        in directory: URL,
        extension fileExtension: String
    ) -> String {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let numbers = contents.compactMap { fileName -> Int? in
            let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
            guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { return nil }
            return Int(stem)
        }
        return "\((numbers.max() ?? 0) + 1).\(fileExtension)"
    }

    static func savePastedImage(_ data: Data, forMarkdownFile fileURL: URL) throws -> URL {
        let directory = picturesDirectory(forMarkdownFile: fileURL)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let imageURL = directory.appendingPathComponent(
            nextIntegerFileName(in: directory, extension: "png")
        )
        try atomicWrite(data, to: imageURL)
        return imageURL
    }

    /// Returns a URL-safe relative Markdown destination.
    static func markdownPath(for imageURL: URL, from markdownFile: URL) -> String? {
        guard let path = relativePath(from: markdownFile, to: imageURL), !path.isEmpty else {
            return nil
        }
        return encodedMarkdownPath(path)
    }

    fileprivate static func encodedMarkdownPath(_ path: String) -> String {
        // Parentheses are valid URL path characters but can terminate an
        // unbracketed Markdown destination when a filename contains only one
        // side of the pair.
        let allowedCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "()"))
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map {
                String($0).addingPercentEncoding(withAllowedCharacters: allowedCharacters)
                    ?? String($0)
            }
            .joined(separator: "/")
    }

    /// Rewrites inline image destinations while leaving alt text and titles
    /// untouched. This is intentionally scoped to image syntax, not arbitrary
    /// prose or code containing the same path.
    static func replacingImagePath(in markdown: String,
                                   from oldPath: String,
                                   to newPath: String) -> String? {
        var collector = MarkdownImageRangeCollector(source: markdown, matching: oldPath)
        collector.visit(Document(parsing: markdown))
        guard !collector.ranges.isEmpty else { return nil }

        let nsMarkdown = markdown as NSString
        let destinationRanges = collector.ranges.compactMap {
            imageDestinationRange(in: markdown, imageRange: $0)
        }.sorted { $0.location < $1.location }
        guard !destinationRanges.isEmpty else { return nil }

        var result = ""
        result.reserveCapacity(markdown.count)
        var cursor = 0
        for pathRange in destinationRanges {
            result += nsMarkdown.substring(with: NSRange(
                location: cursor,
                length: pathRange.location - cursor
            ))
            result += newPath
            cursor = pathRange.location + pathRange.length
        }
        result += nsMarkdown.substring(from: cursor)
        return result
    }

    private static func imageDestinationRange(in markdown: String,
                                              imageRange: NSRange) -> NSRange? {
        guard let range = Range(imageRange, in: markdown) else { return nil }
        var index = range.lowerBound
        guard index < range.upperBound, markdown[index] == "!" else { return nil }
        index = markdown.index(after: index)
        guard index < range.upperBound, markdown[index] == "[" else { return nil }
        index = markdown.index(after: index)

        var labelDepth = 1
        while index < range.upperBound, labelDepth > 0 {
            switch markdown[index] {
            case "\\":
                index = markdown.index(after: index)
                if index < range.upperBound {
                    index = markdown.index(after: index)
                }
            case "[":
                labelDepth += 1
                index = markdown.index(after: index)
            case "]":
                labelDepth -= 1
                index = markdown.index(after: index)
            default:
                index = markdown.index(after: index)
            }
        }
        guard labelDepth == 0,
              index < range.upperBound,
              markdown[index] == "(" else { return nil }
        index = markdown.index(after: index)
        while index < range.upperBound, markdown[index].isWhitespace {
            index = markdown.index(after: index)
        }
        guard index < range.upperBound else { return nil }

        if markdown[index] == "<" {
            let destinationStart = markdown.index(after: index)
            index = destinationStart
            while index < range.upperBound {
                if markdown[index] == "\\" {
                    index = markdown.index(after: index)
                    if index < range.upperBound {
                        index = markdown.index(after: index)
                    }
                } else if markdown[index] == ">" {
                    return NSRange(destinationStart..<index, in: markdown)
                } else if markdown[index].isNewline {
                    return nil
                } else {
                    index = markdown.index(after: index)
                }
            }
            return nil
        }

        let destinationStart = index
        var parenthesisDepth = 0
        while index < range.upperBound {
            switch markdown[index] {
            case "\\":
                index = markdown.index(after: index)
                if index < range.upperBound {
                    index = markdown.index(after: index)
                }
            case "(":
                parenthesisDepth += 1
                index = markdown.index(after: index)
            case ")":
                guard parenthesisDepth > 0 else {
                    return NSRange(destinationStart..<index, in: markdown)
                }
                parenthesisDepth -= 1
                index = markdown.index(after: index)
            default:
                guard !markdown[index].isWhitespace else {
                    return NSRange(destinationStart..<index, in: markdown)
                }
                index = markdown.index(after: index)
            }
        }
        return nil
    }

    /// Computes the relative path from one file URL to another.
    static func relativePath(from source: URL, to destination: URL) -> String? {
        guard source.isFileURL, destination.isFileURL else { return nil }
        let sourceComponents = source.standardizedFileURL.pathComponents
        let destinationComponents = destination.standardizedFileURL.pathComponents
        let commonLength = zip(sourceComponents, destinationComponents)
            .prefix { $0.0 == $0.1 }
            .count
        let levelsUp = sourceComponents.count - commonLength - 1
        guard levelsUp >= 0 else { return nil }
        return (Array(repeating: "..", count: levelsUp)
            + Array(destinationComponents.dropFirst(commonLength)))
            .joined(separator: "/")
    }

    @discardableResult
    static func atomicWrite(_ data: Data, to fileURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

nonisolated private struct MarkdownImageRangeCollector: MarkupWalker {
    let source: String
    let matchingSource: String
    private let lineStartOffsets: [Int]
    private(set) var ranges: [NSRange] = []

    init(source: String, matching matchingSource: String) {
        self.source = source
        self.matchingSource = matchingSource
        var offsets = [0]
        for (offset, byte) in source.utf8.enumerated() where byte == 0x0A {
            offsets.append(offset + 1)
        }
        lineStartOffsets = offsets
    }

    mutating func visitImage(_ image: Image) {
        guard let imageSource = image.source,
              MarkdownAssetResolution.encodedMarkdownPath(imageSource) == matchingSource,
              let sourceRange = image.range,
              let lower = index(for: sourceRange.lowerBound),
              let upper = index(for: sourceRange.upperBound),
              lower <= upper else { return }
        ranges.append(NSRange(lower..<upper, in: source))
    }

    private func index(for location: SourceLocation) -> String.Index? {
        guard location.line > 0,
              location.line <= lineStartOffsets.count,
              location.column > 0 else { return nil }
        let offset = lineStartOffsets[location.line - 1] + location.column - 1
        guard let utf8Index = source.utf8.index(
            source.utf8.startIndex,
            offsetBy: offset,
            limitedBy: source.utf8.endIndex
        ) else { return nil }
        return String.Index(utf8Index, within: source)
    }
}
