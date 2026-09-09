import Foundation
@testable import MarkdownHelpers

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
    /// Points the render-time highlighter at the repository's grammar bundle.
    /// The test package has no app bundle, so without this `CodeHighlighter`
    /// reports itself unavailable and fences render for the deferred pass.
    /// Call from `class func setUp()` in every suite that asserts on
    /// highlighted or `data-hljs-done` output.
    static func installHighlighterGrammar() {
        guard let source = try? String(
            contentsOf: repositoryRoot.appendingPathComponent("md-preview/Vendor/Highlight/highlight.min.js"),
            encoding: .utf8
        ) else { return }
        CodeHighlighter.useGrammar(source: source)
    }

    static func script(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        .replacingOccurrences(of: "</script", with: "<\\/script")
    }
}
