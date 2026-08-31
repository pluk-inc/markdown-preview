//
//  DocumentFontSetting.swift
//  md-preview
//
//  Typeface for rendered Markdown, persisted across launches.
//
//  A curated list of reading faces in the Apple Books style rather than a
//  picker of every installed font. The page's vertical rhythm is *derived*:
//  paragraph spacing, the blank-line gap and the heading scale are all
//  computed from one body size and tuned against one x-height, and the column
//  width is tuned to a comfortable line length at that face. Every face here
//  ships with macOS and sits in the same metric neighbourhood; condensed
//  faces, display faces and variable weight axes at 15px stay out. A short
//  list is also a list every option of which has actually been looked at.
//
//  Stored in the app group rather than `UserDefaults.standard`, so Quick Look
//  renders in the chosen face too — it is a reading surface as much as the
//  document window is, and a preference that reaches one but not the other is
//  worse than either extreme.
//

import Foundation

nonisolated enum DocumentFontSetting: String, CaseIterable, Sendable {
    case system
    case athelas
    case avenirNext
    case charter
    case georgia
    case iowan
    case newYork
    case palatino
    case rounded
    case seravek
    case timesNewRoman
    case monospace

    static let defaultsKey = "MarkdownPreview.documentFont"
    static let defaultSetting: Self = .system

    /// CSS font stack. Each ends in a generic family so macOS's own per-script
    /// cascade can still pick a face for CJK text the named fonts don't cover.
    var fontFamily: String {
        switch self {
        case .system: return MarkdownHTML.bodyFontFamily
        case .athelas: return "Athelas, ui-serif, Georgia, serif"
        case .avenirNext: return "\"Avenir Next\", Avenir, -apple-system, system-ui, sans-serif"
        case .charter: return "Charter, ui-serif, Georgia, serif"
        case .georgia: return "Georgia, ui-serif, serif"
        case .iowan: return "\"Iowan Old Style\", ui-serif, Georgia, serif"
        case .newYork: return "ui-serif, \"New York\", \"Iowan Old Style\", Georgia, serif"
        case .palatino: return "Palatino, \"Palatino Linotype\", ui-serif, Georgia, serif"
        case .rounded: return "ui-rounded, \"SF Pro Rounded\", -apple-system, system-ui, sans-serif"
        case .seravek: return "Seravek, -apple-system, system-ui, sans-serif"
        case .timesNewRoman: return "\"Times New Roman\", Times, serif"
        case .monospace: return MarkdownHTML.codeFontFamily
        }
    }

    /// Whether the face reads as a serif. Drives the code-size correction and
    /// lets UI group the list the way Apple Books does.
    var isSerif: Bool {
        switch self {
        case .athelas, .charter, .georgia, .iowan, .newYork, .palatino,
             .timesNewRoman:
            return true
        case .system, .avenirNext, .rounded, .seravek, .monospace:
            return false
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
        case .monospace: return "1em"
        default: return isSerif ? "0.84em" : "0.88em"
        }
    }

    /// Display names in the Apple Books style. "Original" is the app's own
    /// default look; the generic entries (SF Rounded, Monospace) keep a
    /// character name because their stack is a fallback chain, not a promise
    /// of one installed font.
    var title: String {
        switch self {
        case .system: return NSLocalizedString("Original", comment: "Document font")
        case .athelas: return NSLocalizedString("Athelas", comment: "Document font")
        case .avenirNext: return NSLocalizedString("Avenir Next", comment: "Document font")
        case .charter: return NSLocalizedString("Charter", comment: "Document font")
        case .georgia: return NSLocalizedString("Georgia", comment: "Document font")
        case .iowan: return NSLocalizedString("Iowan", comment: "Document font")
        case .newYork: return NSLocalizedString("New York", comment: "Document font")
        case .palatino: return NSLocalizedString("Palatino", comment: "Document font")
        case .rounded: return NSLocalizedString("SF Rounded", comment: "Document font")
        case .seravek: return NSLocalizedString("Seravek", comment: "Document font")
        case .timesNewRoman: return NSLocalizedString("Times New Roman", comment: "Document font")
        case .monospace: return NSLocalizedString("Monospace", comment: "Document font")
        }
    }

    static var current: Self {
        get { read(from: AppearanceMode.sharedDefaults()) }
        set { write(newValue, to: AppearanceMode.sharedDefaults()) }
    }

    static func read(from defaults: UserDefaults?) -> Self {
        guard let rawValue = defaults?.string(forKey: defaultsKey) else { return defaultSetting }
        // The pre-list "Serif" option used the New York stack; a stored value
        // from that era maps onto its named successor.
        if rawValue == "serif" { return .newYork }
        return Self(rawValue: rawValue) ?? defaultSetting
    }

    static func write(_ setting: Self, to defaults: UserDefaults?) {
        if setting == defaultSetting {
            defaults?.removeObject(forKey: defaultsKey)
        } else {
            defaults?.set(setting.rawValue, forKey: defaultsKey)
        }
    }
}
