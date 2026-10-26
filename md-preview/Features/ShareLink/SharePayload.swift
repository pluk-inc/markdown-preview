//
//  SharePayload.swift
//  md-preview
//
//  The JSON document inside a share envelope (docs/share-link-plan.md §2).
//  Everything decoded here is hostile input: anyone can build an envelope
//  without the app. Kept free of AppKit so the SPM helper tests can
//  exercise it without a GUI host.
//

import Foundation

nonisolated struct SharePayload: Codable, Equatable, Sendable {

    struct Asset: Codable, Equatable, Sendable {
        /// Relative to the document, `/`-separated, e.g. `img/diagram.png`.
        let path: String
        /// MIME type; one of `allowedAssetTypes`.
        let type: String
        /// Encoded as base64 in the JSON.
        let data: Data
        /// For an image from the web, the address the document uses for it
        /// (docs/share-link-plan.md §2). Absent for a local image.
        var source: String? = nil
    }

    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidAssetPath(String)
        case invalidAssetSource(String)
        case unsupportedAssetType(String)
        case duplicateAssetPath(String)
    }

    static let currentVersion = 1
    static let allowedAssetTypes = Set(ShareLinkAssets.mediaTypes.values)
    private static let maxTitleLength = 200

    let version: Int
    let title: String
    let markdown: String
    /// Body rendered by `MarkdownHTML` at upload time. Only the web viewer
    /// uses it, and only after sanitizing; the app renders `markdown`.
    let html: String
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case version = "v", title, markdown, html, assets
    }

    init(title: String, markdown: String, html: String, assets: [Asset]) {
        self.version = Self.currentVersion
        self.title = title
        self.markdown = markdown
        self.html = html
        self.assets = assets
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decodes and validates: known version, confined asset paths, allowed
    /// asset types, web sources only for web images, no duplicate paths.
    /// Asset paths come back normalized.
    static func decode(_ data: Data) throws -> SharePayload {
        let raw = try JSONDecoder().decode(SharePayload.self, from: data)
        guard raw.version == currentVersion else {
            throw Failure.unsupportedVersion(raw.version)
        }

        var seen = Set<String>()
        let assets = try raw.assets.map { asset in
            guard let path = normalizedAssetPath(asset.path) else {
                throw Failure.invalidAssetPath(asset.path)
            }
            guard allowedAssetTypes.contains(asset.type.lowercased()) else {
                throw Failure.unsupportedAssetType(asset.type)
            }
            if let source = asset.source, !isWebSource(source) {
                throw Failure.invalidAssetSource(source)
            }
            guard seen.insert(path).inserted else { throw Failure.duplicateAssetPath(path) }
            return Asset(path: path, type: asset.type.lowercased(), data: asset.data, source: asset.source)
        }
        return SharePayload(title: raw.title, markdown: raw.markdown, html: raw.html, assets: assets)
    }

    /// An `http` or `https` address with a host, at most 4096 characters.
    static func isWebSource(_ source: String) -> Bool {
        // UTF-16 units, as the viewer's `source.length` counts them.
        guard source.utf16.count <= 4096, let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(), components.host?.isEmpty == false
        else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The title safe to show in a window title or a file name stem:
    /// control characters and path separators removed, length capped.
    var displayTitle: String {
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":"
        })).trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(Self.maxTitleLength))
    }

    /// A relative path with `.` and empty segments dropped. Nil for an
    /// absolute path, a `..` segment, a backslash, a NUL, or nothing left.
    static func normalizedAssetPath(_ path: String) -> String? {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            return nil
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        guard !segments.isEmpty, !segments.contains("..") else { return nil }
        return segments.joined(separator: "/")
    }

    /// Where an asset goes when a share is unpacked into `directory`. Nil
    /// when the path is invalid or would land outside `directory`.
    static func fileURL(forAssetPath path: String, in directory: URL) -> URL? {
        guard let normalized = normalizedAssetPath(path) else { return nil }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(normalized).standardizedFileURL
        return url != root && url.isDescendantOrSame(of: root) ? url : nil
    }

    /// APFS names hold 255 bytes of UTF-8; a title of 100 Japanese
    /// characters is 300. Cut at a character boundary, leaving room for a
    /// number and the ".md" this adds.
    static func fittingFileName(_ title: String, maxBytes: Int = 240) -> String {
        guard title.utf8.count > maxBytes else { return title }
        var fitted = ""
        for character in title {
            guard fitted.utf8.count + character.utf8.count <= maxBytes else { break }
            fitted.append(character)
        }
        return fitted.trimmingCharacters(in: .whitespaces)
    }

    /// Writes the share into `shareFolder`, replacing what was there. The
    /// Markdown and its assets go in a subfolder named after the title, so
    /// a files sidebar shows the title. Returns the Markdown file, which is
    /// written last, so a half-written folder never opens.
    func unpack(into shareFolder: URL) throws -> URL {
        var name = Self.fittingFileName(displayTitle)
        if name.isEmpty || name.hasPrefix(".") {
            name = NSLocalizedString("Shared Document", comment: "File name for a shared document without a title")
        }
        let folder = shareFolder.appending(path: (name as NSString).deletingPathExtension,
                                           directoryHint: .isDirectory)
        if !ProjectFileIndex.markdownExtensions.contains((name as NSString).pathExtension.lowercased()) {
            name += ".md"
        }
        // An asset folder can carry the Markdown file's own name; number
        // the file instead of failing to write it.
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var number = 1
        while assets.contains(where: { $0.path == name || $0.path.hasPrefix(name + "/") }) {
            number += 1
            name = "\(stem) \(number).\(fileExtension)"
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: shareFolder.path) {
            try fileManager.removeItem(at: shareFolder)
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        // Web images stay out: the Markdown names them by their web address,
        // not by a file in this folder.
        for asset in assets where asset.source == nil {
            guard let url = Self.fileURL(forAssetPath: asset.path, in: folder) else { continue }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try asset.data.write(to: url)
        }

        let file = folder.appending(path: name, directoryHint: .notDirectory)
        try Data(markdown.utf8).write(to: file)
        return file
    }
}
