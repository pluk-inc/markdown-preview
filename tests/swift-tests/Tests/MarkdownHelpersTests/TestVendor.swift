import Foundation
@testable import MarkdownHelpers

/// Access to production assets and fixtures in the repository checkout.
/// MarkdownHelpers also bundles Vendor resources so renderer bootstrap paths
/// (including KaTeX and Mermaid) are the same in tests and the app.
enum TestVendor {
    /// Repository root, derived from this file's location at
    /// `tests/swift-tests/Tests/MarkdownHelpersTests/` (five levels deep).
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Points the render-time highlighter at the repository's grammar bundle.
    /// CodeHighlighter has its own app-bundle lookup; install the same
    /// grammar explicitly for tests that exercise render-time highlighting.
    /// Call from `class func setUp()` in every suite that asserts on
    /// highlighted or `data-hljs-done` output.
    static func installHighlighterGrammar() {
        guard let source = try? String(
            contentsOf: repositoryRoot.appendingPathComponent("md-preview/Vendor/Highlight/highlight.min.js"),
            encoding: .utf8
        ) else { return }
        CodeHighlighter.useGrammar(source: source)
    }

    /// Repo-relative vendored JS escaped for an inline `<script>` block.
    static func script(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        .replacingOccurrences(of: "</script", with: "<\\/script")
    }
}
