//
//  MarkdownAssetSchemeHandler.swift
//  md-preview
//

import Foundation
import UniformTypeIdentifiers
import WebKit

/// Custom URL scheme handler that serves files relative to the document's
/// parent folder. The host process holds the security-scoped extension for
/// the folder, so FileManager reads succeed even though the WKWebView's
/// content process is sandboxed separately.
nonisolated final class MarkdownAssetScheme: NSObject, WKURLSchemeHandler {

    nonisolated static let scheme = "md-asset"
    /// URL path prefix reserved for app-bundled vendor scripts (lazy-loaded).
    nonisolated static let vendorPathPrefix = "/__vendor/"

    /// Builds an `md-asset:///__vendor/<filename>` URL string for use in
    /// `<script src=…>` tags emitted by the lazy renderer wirings.
    nonisolated static func vendorURL(_ filename: String) -> String {
        "\(scheme)://\(vendorPathPrefix)\(filename)"
    }

    /// Vendor-file byte cache. Populated lazily by `serve(...)` on first
    /// request — vendor bundles never change for the lifetime of the app
    /// process, and WKWebView's NSURLCache doesn't cover custom-scheme
    /// responses, so without this cache every `<script src>` re-reads the
    /// 3 MB Mermaid blob from disk.
    private nonisolated static let vendorDataCache = VendorDataCache()

    private let queue = DispatchQueue(label: "doc.md-preview.asset-scheme", qos: .userInitiated)
    private let lock = NSLock()
    private var _baseURL: URL?

    func setBaseURL(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        _baseURL = url
    }

    private func currentBaseURL() -> URL? {
        lock.lock(); defer { lock.unlock() }
        return _baseURL
    }

    /// Resolves an `md-asset://…` URL against `base`, rejecting path-traversal
    /// that escapes the granted folder. Returns `nil` for malformed input.
    nonisolated static func resolve(_ assetURL: URL, against base: URL) -> URL? {
        var path = assetURL.path
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }

        let candidate = base.appendingPathComponent(path).standardizedFileURL
        let basePath = base.standardizedFileURL.path
        // Lexical check (catches .. traversal)
        guard candidate.path == basePath
                || candidate.path.hasPrefix(basePath + "/") else {
            return nil
        }
        // Physical check (catches symlinks pointing outside base)
        let physical = candidate.resolvingSymlinksInPath()
        let physicalBase = base.standardizedFileURL.resolvingSymlinksInPath()
        guard physical.path == physicalBase.path
                || physical.path.hasPrefix(physicalBase.path + "/") else {
            return nil
        }
        return candidate
    }

    /// Resolves a `/__vendor/<file>` URL to a file inside the app bundle's
    /// `Vendor/<Renderer>/` subfolder. Returns `nil` if the filename isn't on
    /// the allow-list — keeps the scheme from leaking other bundle resources.
    nonisolated static func resolveVendor(_ url: URL) -> URL? {
        let path = url.path
        guard path.hasPrefix(vendorPathPrefix) else { return nil }
        let filename = String(path.dropFirst(vendorPathPrefix.count))

        // Allow-list mapping: <url filename> -> (resource name, ext, subdir)
        let mapping: [String: (name: String, ext: String, subdir: String)] = [
            "katex.min.js":     ("katex.min",     "js",  "Vendor/KaTeX"),
            "copy-tex.min.js":  ("copy-tex.min",  "js",  "Vendor/KaTeX"),
            "mermaid.min.js":   ("mermaid.min",   "js",  "Vendor/Mermaid"),
            "highlight.min.js": ("highlight.min", "js",  "Vendor/Highlight"),
            "purify.min.js":    ("purify.min",    "js",  "Vendor/DOMPurify"),
        ]
        guard let entry = mapping[filename] else { return nil }

        let bundles = [Bundle.main, Bundle(for: MarkdownAssetScheme.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: entry.name,
                                    withExtension: entry.ext,
                                    subdirectory: entry.subdir) {
                return url
            }
            if let url = bundle.url(forResource: entry.name,
                                    withExtension: entry.ext) {
                return url
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        let base = currentBaseURL()
        let wrapper = TaskWrapper(task: urlSchemeTask)

        queue.async {
            guard let requestURL = request.url else {
                wrapper.task.didFailWithError(URLError(.badURL))
                return
            }

            // Vendor scripts are served from the app bundle and do not depend
            // on the user-file base URL — they must load even before/without
            // sandbox access to the user's folder.
            if let vendorURL = Self.resolveVendor(requestURL) {
                Self.serve(file: vendorURL, requestURL: requestURL, task: wrapper.task, cacheable: true)
                return
            }

            guard let base,
                  let resolved = Self.resolve(requestURL, against: base) else {
                wrapper.task.didFailWithError(URLError(.badURL))
                return
            }
            Self.serve(file: resolved, requestURL: requestURL, task: wrapper.task, cacheable: false)
        }
    }

    private nonisolated static func serve(file resolved: URL,
                                          requestURL: URL,
                                          task: any WKURLSchemeTask,
                                          cacheable: Bool) {
        let data: Data
        if cacheable, let cached = vendorDataCache.data(for: resolved) {
            data = cached
        } else {
            guard let read = try? Data(contentsOf: resolved) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            if cacheable {
                vendorDataCache.set(read, for: resolved)
            }
            data = read
        }
        let mime = mimeType(for: resolved)
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(data.count),
                "Access-Control-Allow-Origin": "null"
            ]
        ) ?? URLResponse(url: requestURL,
                         mimeType: mime,
                         expectedContentLength: data.count,
                         textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    // `WKURLSchemeTask` is an Objective-C protocol without useful Sendable
    // annotations. The handler immediately moves work onto its private serial
    // queue and reports results for the same task from there, which matches
    // WKURLSchemeHandler's callback-style contract.
    private struct TaskWrapper: @unchecked Sendable {
        let task: any WKURLSchemeTask
    }

    // `NSCache` is internally synchronized but is not annotated Sendable by
    // Foundation. Keep that unchecked assumption behind a tiny value API so the
    // rest of the scheme handler never shares the cache object directly.
    private final class VendorDataCache: @unchecked Sendable {
        private let cache = NSCache<NSURL, NSData>()

        nonisolated func data(for url: URL) -> Data? {
            cache.object(forKey: url as NSURL) as Data?
        }

        nonisolated func set(_ data: Data, for url: URL) {
            cache.setObject(data as NSData, forKey: url as NSURL)
        }
    }

    private nonisolated static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
