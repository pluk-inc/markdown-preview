// swift-tools-version:6.0
//
// Test scaffold for rendering, WebKit layout, and helpers from the app and the
// Quick Look extension. The Xcode project is the source of truth — source
// files live under `quick-look/` and `md-preview/` and are symlinked into
// `Sources/<Target>/` so SPM can compile them without duplication.
//
// Run: `swift test --package-path tests/swift-tests`
//
import PackageDescription

let package = Package(
    name: "MdPreviewHelperTests",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-markdown.git",
            from: "0.7.3"
        ),
    ],
    targets: [
        .target(name: "QuickLookHelpers"),
        .testTarget(
            name: "QuickLookHelperTests",
            dependencies: ["QuickLookHelpers", "MarkdownHelpers"]
        ),
        .target(
            name: "MarkdownHelpers",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // Copy real child directories; copying the Vendor symlink itself
            // leaves a dangling relative link with SwiftPM's native build system.
            resources: ["CodeMirror", "DOMPurify", "Highlight", "KaTeX", "Mermaid", "Morphdom"]
                .map { .copy("Vendor/\($0)") }
        ),
        .testTarget(
            name: "MarkdownHelpersTests",
            dependencies: ["MarkdownHelpers"]
        ),
    ]
)
