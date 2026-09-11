import Foundation

/// Markdown source for the page shown when a Quick Look preview cannot read
/// its file. Rendering the page through the normal `MarkdownHTML` pipeline
/// keeps the app's theme; showing the concrete error (description, domain,
/// code) plus a hint turns a blank pane into something the user can act on.
enum QuickLookErrorPage {

    static func makeMarkdown(for error: Error, fileURL: URL) -> String {
        let title = NSLocalizedString(
            "Couldn't preview this file",
            comment: "Quick Look error page title"
        )
        let lead = NSLocalizedString(
            "couldn't be read for preview.",
            comment: "Quick Look error page lead-in after the file name"
        )
        let errorLabel = NSLocalizedString(
            "Error",
            comment: "Quick Look error page label for the error description"
        )
        let domainLabel = NSLocalizedString(
            "Domain",
            comment: "Quick Look error page label for the error domain"
        )
        let pathLabel = NSLocalizedString(
            "Path",
            comment: "Quick Look error page label for the file path"
        )

        let nsError = error as NSError
        let lines: [String] = [
            "# \(title)",
            "",
            "**\(escaped(fileURL.lastPathComponent))** \(lead)",
            "",
            "- **\(errorLabel):** \(escaped(error.localizedDescription))",
            "- **\(domainLabel):** \(escaped(nsError.domain)) (\(nsError.code))",
            "- **\(pathLabel):** \(escaped(fileURL.path))",
            "",
            "> \(hint(for: fileURL))",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Advice tailored to where the file lives. Files inside another app's
    /// sandbox container (`~/Library/Containers/<bundle-id>/…`, e.g. WeChat
    /// downloads) are off-limits to Quick Look extensions on macOS — no app
    /// can change that, so the page says so instead of failing silently.
    private static func hint(for fileURL: URL) -> String {
        if fileURL.path.contains("/Library/Containers/") {
            return NSLocalizedString(
                "This file is inside another app's sandbox container, which macOS keeps off-limits to Quick Look. Double-click the file to open it in Markdown Preview, or copy it to a regular folder and preview the copy.",
                comment: "Quick Look error page hint for files in an app container"
            )
        }
        return NSLocalizedString(
            "Double-click the file to open it in Markdown Preview. If that also fails, check the file's permissions with Finder's Get Info (⌘I).",
            comment: "Quick Look error page hint for unreadable files"
        )
    }

    /// Backslash-escapes every ASCII punctuation character so interpolated
    /// values (file names, localized error descriptions) can never light up
    /// markdown syntax or inline HTML once rendered.
    static func escaped(_ text: String) -> String {
        var escaped = String()
        escaped.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if escapableCharacters.contains(scalar) {
                escaped.append("\\")
            }
            escaped.append(Character(scalar))
        }
        return escaped
    }

    // CommonMark only honors backslash escapes for ASCII punctuation, so
    // escaping that full set is both necessary and sufficient.
    private static let escapableCharacters: Set<Unicode.Scalar> = Set(
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars
    )
}
