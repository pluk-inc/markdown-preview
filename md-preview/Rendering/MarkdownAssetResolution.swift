//
//  MarkdownAssetResolution.swift
//  md-preview
//

import Foundation

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
}
