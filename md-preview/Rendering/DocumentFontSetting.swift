//
//  DocumentFontSetting.swift
//  md-preview
//
//  Typeface for rendered Markdown, persisted across launches.
//
//  Four named faces rather than a picker of every installed font. The page's
//  vertical rhythm is *derived*: paragraph spacing, the blank-line gap and the
//  heading scale are all computed from one body size and tuned against one
//  x-height, and the column width is tuned to a comfortable line length at that
//  face. Those numbers survive a swap between faces in the same metric
//  neighbourhood; they do not survive a condensed face, a display face, or a
//  variable weight axis at 15px. A short list is also a list every option of
//  which has actually been looked at.
//
//  Stored in the app group rather than `UserDefaults.standard`, so Quick Look
//  renders in the chosen face too — it is a reading surface as much as the
//  document window is, and a preference that reaches one but not the other is
//  worse than either extreme.
//

import Foundation

nonisolated enum DocumentFontSetting: String, CaseIterable, Sendable {
    case system
    case serif
    case rounded
    case monospace

    static let defaultsKey = "MarkdownPreview.documentFont"
    static let defaultSetting: Self = .system

    /// CSS font stack. Each ends in a generic family so macOS's own per-script
    /// cascade can still pick a face for CJK text the named fonts don't cover.
    var fontFamily: String {
        switch self {
        case .system: return MarkdownHTML.bodyFontFamily
        case .serif: return "ui-serif, \"New York\", \"Iowan Old Style\", Georgia, serif"
        case .rounded: return "ui-rounded, \"SF Pro Rounded\", -apple-system, system-ui, sans-serif"
        case .monospace: return MarkdownHTML.codeFontFamily
        }
    }

    /// Code stays monospaced whatever the document font is — alignment,
    /// diffs and whitespace fidelity are the reason it is monospaced at all,
    /// and the document face does not get a vote on that. What does move is
    /// the size it sits at: `0.88em` is tuned against the system face's
    /// x-height, and the same declaration reads *larger* than its surroundings
    /// against a serif's smaller one. Monospace documents take `1em`, where
    /// code at 0.88em would read as the same font at a slightly wrong size;
    /// the background chip is what marks it as code there.
    var codeFontSize: String {
        switch self {
        case .system, .rounded: return "0.88em"
        case .serif: return "0.84em"
        case .monospace: return "1em"
        }
    }

    /// Named for the reading character, not the face: the stack is a fallback
    /// chain, so naming a font would promise one that may not be installed.
    var title: String {
        switch self {
        case .system: return NSLocalizedString("System", comment: "Document font")
        case .serif: return NSLocalizedString("Serif", comment: "Document font")
        case .rounded: return NSLocalizedString("Rounded", comment: "Document font")
        case .monospace: return NSLocalizedString("Monospace", comment: "Document font")
        }
    }

    static var current: Self {
        get { read(from: AppearanceMode.sharedDefaults()) }
        set { write(newValue, to: AppearanceMode.sharedDefaults()) }
    }

    static func read(from defaults: UserDefaults?) -> Self {
        guard let rawValue = defaults?.string(forKey: defaultsKey),
              let setting = Self(rawValue: rawValue) else { return defaultSetting }
        return setting
    }

    static func write(_ setting: Self, to defaults: UserDefaults?) {
        if setting == defaultSetting {
            defaults?.removeObject(forKey: defaultsKey)
        } else {
            defaults?.set(setting.rawValue, forKey: defaultsKey)
        }
    }
}
