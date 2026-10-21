// swift-tools-version:6.0
//
// Test scaffold for rendering, WebKit layout, and helpers from the app and the
// Quick Look extension. The Xcode project is the source of truth — source
// files live under `quick-look/` and `md-preview/` and are symlinked into
// `Sources/<Target>/` so SPM can compile them without duplication.
//
// Run: `swift test --package-path tests/swift-tests`. To see how long each
// test takes, set MDP_TEST_TIMING to a file path and pass that file to
// `tests/test-timing-report.py`.
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
        // Logs each test's start and end when MDP_TEST_TIMING is set.
        .target(name: "TestTiming", publicHeadersPath: "."),
        .testTarget(
            name: "QuickLookHelperTests",
            dependencies: ["QuickLookHelpers", "TestTiming"]
        ),
        .target(
            name: "MarkdownHelpers",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // Copy real child directories; copying the Vendor symlink itself
            // leaves a dangling relative link with SwiftPM's native build system.
            resources: ["CodeMirror", "DOMPurify", "Highlight", "KaTeX", "Morphdom", "Pele"]
                .map { .copy("Vendor/\($0)") }
        ),
        .testTarget(
            name: "MarkdownHelpersTests",
            dependencies: ["MarkdownHelpers", "TestTiming"]
        ),
    ]
)
