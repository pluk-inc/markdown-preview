import Foundation

/// A global reading preference, independent of each theme's saved look.
/// Shared app-group defaults also make it available to Quick Look.
nonisolated enum TextAlignmentSetting: String, CaseIterable {
    case automatic, left, center, right, justified

    static let defaultsKey = "MarkdownPreview.textAlignment"

    static var current: Self {
        get { read(from: AppearanceMode.sharedDefaults()) }
        set { write(newValue, to: AppearanceMode.sharedDefaults()) }
    }

    static func read(from defaults: UserDefaults?) -> Self {
        defaults?.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    static func write(_ value: Self, to defaults: UserDefaults?) {
        if value == .automatic {
            defaults?.removeObject(forKey: defaultsKey)
        } else {
            defaults?.set(value.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .automatic: NSLocalizedString("Automatic", comment: "Text alignment")
        case .left: NSLocalizedString("Left", comment: "Text alignment")
        case .center: NSLocalizedString("Center", comment: "Text alignment")
        case .right: NSLocalizedString("Right", comment: "Text alignment")
        case .justified: NSLocalizedString("Justified", comment: "Text alignment")
        }
    }

    var styleBlock: String {
        guard self != .automatic else { return "" }
        let alignment = self == .justified ? "justify" : rawValue
        // Only prose blocks participate. Exclude authored alignment on the
        // block or its ancestors, and rich content that owns its own layout.
        return """
        <style>
        article.markdown-body :is(p, li, dt, dd, h1, h2, h3, h4, h5, h6):not(
            center *, [align], [align] *, [style*="text-align" i], [style*="text-align" i] *,
            table *, pre *, .mermaid *, .katex *
        ) {
            text-align: \(alignment);
            text-align-last: auto;
        }
        /* A fenced block nested inside an aligned list must not inherit it. */
        article.markdown-body :is(pre, .md-code-wrap):not(center *, [align], [align] *, [style*="text-align" i], [style*="text-align" i] *) {
            text-align: start;
            text-align-last: auto;
        }
        </style>
        """
    }
}
