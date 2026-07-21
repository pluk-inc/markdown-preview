import Foundation

/// Access to the repository checkout for tests that need real vendored JS —
/// the SPM test bundle carries no vendor resources, so WKWebView harnesses
/// inject them from the source tree instead.
enum TestVendor {
    /// Repository root, derived from this file's location at
    /// `tests/swift-tests/Tests/MarkdownHelpersTests/` (five levels deep).
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Contents of a repo-relative vendored JS file, escaped for embedding
    /// inside an inline `<script>` block.
    static func script(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        .replacingOccurrences(of: "</script", with: "<\\/script")
    }
}
