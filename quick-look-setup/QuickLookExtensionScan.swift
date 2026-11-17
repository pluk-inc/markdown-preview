//
//  QuickLookExtensionScan.swift
//  quick-look-setup
//
//  Reads the list of Quick Look preview extensions that `pluginkit` prints,
//  and works out which of them compete with ours for Markdown files.
//
//  macOS has no setting for which extension wins when several claim one file
//  type. The only lever is the per-extension election (`pluginkit -e`), so
//  "make ours the preview" means "turn the other claimants off".
//

import Foundation

nonisolated struct QuickLookExtension: Equatable, Sendable {
    /// The user's election for an extension, as `pluginkit -m` marks it in
    /// the first column of each line. The raw value is the word
    /// `pluginkit -e` takes to set it.
    enum Election: String, Sendable {
        /// `+`: turned on by the user.
        case use
        /// `-`: turned off by the user.
        case ignore
        /// No mark: the user made no choice, and the extension is on.
        case automatic = "default"
    }

    let identifier: String
    let election: Election
    /// Path of the `.appex` bundle.
    let path: String

    /// The name to show for the extension: the app that contains it, or the
    /// extension's own file name when it is not inside an app (system
    /// frameworks ship some).
    var displayName: String {
        let components = (path as NSString).pathComponents
        let bundle = components.last { $0.hasSuffix(".app") } ?? components.last ?? identifier
        return (bundle as NSString).deletingPathExtension
    }
}

nonisolated enum QuickLookExtensionScan {
    /// The extension point every Quick Look preview extension registers for.
    static let previewExtensionPoint = "com.apple.quicklook.preview"

    /// Parses `pluginkit -m -v -p com.apple.quicklook.preview`. Each line is
    /// a mark column, then tab-separated `identifier(version)`, UUID, date,
    /// and path. Lines in another shape (the trailing count, for one) are
    /// skipped.
    static func parse(pluginkitOutput: String) -> [QuickLookExtension] {
        pluginkitOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4, let path = fields.last, path.hasPrefix("/") else { return nil }

            let election: QuickLookExtension.Election
            switch line.first {
            case "+": election = .use
            case "-": election = .ignore
            default: election = .automatic
            }

            var name = fields[0].dropFirst().trimmingCharacters(in: .whitespaces)
            if let versionStart = name.lastIndex(of: "(") {
                name = String(name[..<versionStart])
            }
            guard !name.isEmpty else { return nil }
            return QuickLookExtension(identifier: name, election: election, path: String(path))
        }
    }

    /// The extensions that are on and claim at least one of the content
    /// types ours claims. An extension that claims only a parent type, such
    /// as plain text, is not a competitor: Quick Look prefers the claim on
    /// the more specific type.
    static func competitors(
        in extensions: [QuickLookExtension],
        ownIdentifier: String,
        ownContentTypes: Set<String>,
        contentTypes: (QuickLookExtension) -> [String]
    ) -> [QuickLookExtension] {
        var seen = Set<String>()
        return extensions.filter { candidate in
            candidate.identifier != ownIdentifier
                && candidate.election != .ignore
                && !ownContentTypes.isDisjoint(with: contentTypes(candidate))
                && seen.insert(candidate.identifier).inserted
        }
    }

    /// The `QLSupportedContentTypes` an extension declares in its Info.plist.
    static func supportedContentTypes(ofExtensionAt path: String) -> [String] {
        let attributes = extensionInfo(at: path)?["NSExtensionAttributes"] as? [String: Any]
        return attributes?["QLSupportedContentTypes"] as? [String] ?? []
    }

    /// Whether the bundle at `path` is a Quick Look preview extension.
    static func isPreviewExtension(at path: String) -> Bool {
        extensionInfo(at: path)?["NSExtensionPointIdentifier"] as? String == previewExtensionPoint
    }

    /// The `NSExtension` dictionary of the Info.plist of an `.appex` bundle.
    private static func extensionInfo(at path: String) -> [String: Any]? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["NSExtension"] as? [String: Any]
    }
}
