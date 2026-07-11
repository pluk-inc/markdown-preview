import Foundation

// MarkdownHTML only needs the vendor URL builder in the pure helper test
// target. The app target uses the real WKURLSchemeHandler implementation.
nonisolated enum MarkdownAssetScheme {
    static func vendorURL(_ filename: String) -> String {
        "md-asset:///__vendor/\(filename)"
    }
}
