//
//  ReaderLayoutSetting.swift
//  md-preview
//
//  Reading-layout preferences from the Customize Theme panel: bold body
//  text, and — behind an explicit Customize switch, the way Apple Books
//  gates them — line spacing, character spacing, word spacing and margins.
//
//  Stored in the app group next to DocumentFontSetting so Quick Look reads
//  with the same layout the document windows do. Values at their defaults
//  are removed from storage; a fresh install stores nothing.
//

import Foundation

nonisolated struct ReaderLayoutSetting: Equatable, Sendable {

    var boldText = false
    /// The Books-style gate: sliders only take effect while this is on, and
    /// switching it off restores the tuned defaults without losing the
    /// slider positions.
    var isCustomized = false
    var lineSpacing = defaultLineSpacing
    var characterSpacingPercent = 0.0
    var wordSpacingPercent = 0.0
    var marginsPercent = 0.0

    /// The stylesheet's own tuned value; the slider starts here.
    static let defaultLineSpacing = Double(MarkdownHTML.bodyLineHeight)
    static let lineSpacingRange = 1.0...2.0
    static let characterSpacingRange = -5.0...12.0
    static let wordSpacingRange = -10.0...25.0
    static let marginsRange = 0.0...100.0

    // MARK: - Effective values

    /// What the page actually renders: the sliders only count while the
    /// Customize switch is on, so their positions persist without applying.
    /// Bold text is not gated — it is its own switch.
    var effective: Self {
        isCustomized ? self : Self(boldText: boldText)
    }

    /// Symmetric inset added inside the reading column, in points. Applied as
    /// padding rather than by shrinking `max-width`: the column measure is
    /// `ContentWidthSetting`'s to own, and a `max-width` here would do
    /// nothing in Full Width and sit off-centre in the app's normal mode,
    /// where the article is host-centered with `margin-left: 0`.
    var pageInset: Int {
        Int(0.9 * effective.marginsPercent)
    }

    /// CSS custom-property declarations for the page `:root`. Only values
    /// that differ from the stylesheet's defaults are emitted — an empty
    /// string means the page renders exactly as before this setting existed.
    var cssVariables: String {
        let applied = effective
        var lines: [String] = []
        if applied.boldText {
            lines.append("--mdp-body-weight: 600;")
        }
        if applied.lineSpacing != Self.defaultLineSpacing {
            lines.append("--mdp-line-height: \(Self.format(applied.lineSpacing));")
        }
        if applied.characterSpacingPercent != 0 {
            lines.append("--mdp-letter-spacing: \(Self.format(applied.characterSpacingPercent / 100))em;")
        }
        if applied.wordSpacingPercent != 0 {
            lines.append("--mdp-word-spacing: \(Self.format(applied.wordSpacingPercent / 100))em;")
        }
        if applied.marginsPercent != 0 {
            lines.append("--mdp-page-inset: \(pageInset)px;")
        }
        return lines.joined(separator: "\n    ")
    }

    /// The whole `:root` rule for the page's reader-layout element, empty
    /// when nothing differs from the stylesheet's tuned defaults.
    var pageCSS: String {
        let variables = cssVariables
        guard !variables.isEmpty else { return "" }
        return ":root {\n    \(variables)\n}"
    }

    /// Rewrites the page's reader-layout element in place. Cheap enough to
    /// run on every slider tick, which is what makes the document itself the
    /// preview rather than the sheet's approximation of it.
    static func styleUpdateScript(css: String) -> String {
        let literal = MarkdownHTML.javaScriptStringLiteral(css)
        return """
        (function () {
            var el = document.getElementById('\(MarkdownHTML.readerLayoutStyleElementID)');
            if (!el) {
                el = document.createElement('style');
                el.id = '\(MarkdownHTML.readerLayoutStyleElementID)';
                document.head.appendChild(el);
            }
            el.textContent = \(literal);
        })();
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    // MARK: - Storage

    private enum Key {
        static let boldText = "MarkdownPreview.readerLayout.boldText"
        static let isCustomized = "MarkdownPreview.readerLayout.customized"
        static let lineSpacing = "MarkdownPreview.readerLayout.lineSpacing"
        static let characterSpacing = "MarkdownPreview.readerLayout.characterSpacing"
        static let wordSpacing = "MarkdownPreview.readerLayout.wordSpacing"
        static let margins = "MarkdownPreview.readerLayout.margins"
    }

    static var current: Self {
        get { read(from: AppearanceMode.sharedDefaults()) }
        set { write(newValue, to: AppearanceMode.sharedDefaults()) }
    }

    /// The numeric settings, each with the key it persists under, its
    /// default and its range. `read` and `write` loop over this rather than
    /// naming every field twice more.
    private static var numericFields: [(key: String,
                                       path: WritableKeyPath<Self, Double>,
                                       defaultValue: Double,
                                       range: ClosedRange<Double>)] {
        [
            (Key.lineSpacing, \.lineSpacing, defaultLineSpacing, lineSpacingRange),
            (Key.characterSpacing, \.characterSpacingPercent, 0, characterSpacingRange),
            (Key.wordSpacing, \.wordSpacingPercent, 0, wordSpacingRange),
            (Key.margins, \.marginsPercent, 0, marginsRange)
        ]
    }

    static func read(from defaults: UserDefaults?) -> Self {
        guard let defaults else { return Self() }
        var setting = Self()
        setting.boldText = defaults.bool(forKey: Key.boldText)
        setting.isCustomized = defaults.bool(forKey: Key.isCustomized)
        for field in numericFields {
            guard let stored = defaults.object(forKey: field.key) as? NSNumber else { continue }
            setting[keyPath: field.path] = clamp(stored.doubleValue, to: field.range)
        }
        return setting
    }

    static func write(_ setting: Self, to defaults: UserDefaults?) {
        guard let defaults else { return }
        store(setting.boldText ? true : nil, forKey: Key.boldText, in: defaults)
        store(setting.isCustomized ? true : nil, forKey: Key.isCustomized, in: defaults)
        for field in numericFields {
            let value = setting[keyPath: field.path]
            store(value == field.defaultValue ? nil : value, forKey: field.key, in: defaults)
        }
    }

    private static func store(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
