//
//  ExternalOpenScheme.swift
//  md-preview
//
//  Resolves md-preview:// URLs — the custom scheme browsers and other apps
//  use to hand the app a file or folder to open, mirroring the shape of
//  cursor://file/<absolute path>. Kept free of AppKit so the SPM helper
//  tests can exercise it without a GUI host.
//

import Foundation

enum ExternalOpenScheme {
    static let scheme = "md-preview"

    static func isSchemeURL(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
    }

    /// Accepted forms:
    ///
    ///     md-preview://file/Users/me/README.md
    ///     md-preview:///Users/me/README.md
    ///
    /// Percent-encoding in the path is decoded (`My%20Notes` → `My Notes`).
    /// Returns nil for any other host, a relative path, or an empty path, so
    /// the caller can tell a malformed link apart from one it can open.
    static func fileURL(from url: URL) -> URL? {
        guard isSchemeURL(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let host = components.host ?? ""
        guard host.isEmpty || host.caseInsensitiveCompare("file") == .orderedSame
        else { return nil }

        let path = components.path
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
