//
//  ShareLink.swift
//  md-preview
//
//  Builds and parses share links:
//
//      https://<share-domain>/s/<id>#<key>
//      https://<share-domain>/s/<id>#p.<key>      (password-protected)
//      md-preview://share/<id>#<key>
//
//  The key lives only in the fragment, which browsers never send to the
//  server. See docs/share-link-plan.md §2. Kept free of AppKit so the SPM
//  helper tests can exercise it without a GUI host.
//

import Foundation

nonisolated struct ShareLink: Equatable, Sendable {

    static let idByteCount = 16
    static let appHost = "share"
    private static let passwordPrefix = "p."

    /// base64url of 16 server-chosen random bytes.
    let id: String
    /// 32 random bytes chosen by the app.
    let key: Data
    /// Tells the reader to ask for a password before fetching. The
    /// envelope's own (authenticated) flag is what `open` trusts.
    let hasPassword: Bool

    init?(id: String, key: Data, hasPassword: Bool) {
        guard Base64URL.decode(id)?.count == Self.idByteCount,
              key.count == ShareLinkCrypto.keyByteCount
        else { return nil }
        self.id = id
        self.key = key
        self.hasPassword = hasPassword
    }

    var fragment: String {
        (hasPassword ? Self.passwordPrefix : "") + Base64URL.encode(key)
    }

    /// `base` is the share domain's origin, e.g. `https://mdshare.link`.
    func webURL(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = basePath + "/s/" + id
        components.fragment = fragment
        return components.url!
    }

    var appURL: URL {
        URL(string: "\(ExternalOpenScheme.scheme)://\(Self.appHost)/\(id)#\(fragment)")!
    }

    /// Accepts the web form under `webBase` and the md-preview:// form.
    /// Returns nil for anything else, including a link without a valid key.
    static func parse(_ url: URL, webBase: URL?) -> ShareLink? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        let idComponents: ArraySlice<String>
        if scheme == ExternalOpenScheme.scheme {
            guard url.host?.lowercased() == appHost else { return nil }
            idComponents = url.pathComponents.dropFirst()
        } else if let webBase,
                  scheme == webBase.scheme?.lowercased(),
                  url.host?.lowercased() == webBase.host?.lowercased(),
                  url.port == webBase.port {
            let prefix = webBase.pathComponents.filter { $0 != "/" } + ["s"]
            let path = url.pathComponents.filter { $0 != "/" }
            guard path.starts(with: prefix) else { return nil }
            idComponents = path.dropFirst(prefix.count)
        } else {
            return nil
        }

        guard idComponents.count == 1, let id = idComponents.first,
              var fragment = url.fragment
        else { return nil }

        // Chat and social apps append tracking parameters to the fragment.
        if let ampersand = fragment.firstIndex(of: "&") {
            fragment = String(fragment[..<ampersand])
        }
        let hasPassword = fragment.hasPrefix(passwordPrefix)
        if hasPassword { fragment.removeFirst(passwordPrefix.count) }

        guard let key = Base64URL.decode(fragment) else { return nil }
        return ShareLink(id: id, key: key, hasPassword: hasPassword)
    }
}

/// RFC 4648 §5 base64url without padding.
nonisolated enum Base64URL {

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Rejects padding, the standard alphabet's `+` and `/`, and
    /// non-canonical trailing bits, so each value has one spelling.
    static func decode(_ string: String) -> Data? {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), encode(data) == string else { return nil }
        return data
    }
}
