//
//  ThemePreset.swift
//  md-preview
//
//  Named built-in theme presets. A preset is a
//  fixed palette written into every ThemeColorsSetting slot for BOTH
//  appearance schemes, so the look holds whatever the system appearance is;
//  applying one also switches the app's appearance to the preset's flavor
//  so the native chrome (sidebar, toolbar) matches. The accent color maps
//  to the link slot — syntax highlighting keeps its own colors.
//

import Foundation

nonisolated struct ThemePreset: Identifiable, Equatable, Sendable {
    /// Display name; also the localization key.
    let name: String
    /// The appearance flavor: applying the preset sets the app appearance
    /// to dark or light accordingly.
    let isDark: Bool
    /// Page background — window, gutters, and (via fallback) the editor
    /// page ("#RRGGBB").
    let pageBackground: String
    /// Code block background ("#RRGGBB").
    let codeBackground: String
    /// Body text ("#RRGGBB").
    let text: String
    /// Accent — the link color, and the card sample's highlight ("#RRGGBB").
    let accent: String

    var id: String { name }

    /// The preset expanded into slot values for both schemes.
    var setting: ThemeColorsSetting {
        var setting = ThemeColorsSetting()
        for scheme in ThemeColorScheme.allCases {
            setting.setHex(pageBackground, .windowBackground, scheme)
            // The editor follows the window color through the fallback
            // chain; a separate editor override is deliberately not exposed
            // yet, and any stored value is cleared so it cannot go stale.
            setting.setHex(nil, .editorBackground, scheme)
            setting.setHex(codeBackground, .codeBlockBackground, scheme)
            setting.setHex(text, .textColor, scheme)
            setting.setHex(accent, .linkColor, scheme)
        }
        return setting
    }

    /// The built-in starter set, in gallery order: light themes in the
    /// left column, their dark counterparts on the right.
    static let builtIn: [ThemePreset] = [
        ThemePreset(name: "Red Graphite", isDark: false,
                    pageBackground: "#FFFFFF", codeBackground: "#F4F4F4",
                    text: "#3F3F3F", accent: "#DA4B41"),
        ThemePreset(name: "Dark Graphite", isDark: true,
                    pageBackground: "#16181D", codeBackground: "#22252C",
                    text: "#E8E8E8", accent: "#57A8F5"),
        ThemePreset(name: "High Contrast", isDark: false,
                    pageBackground: "#FFFFFF", codeBackground: "#F2F2F2",
                    text: "#000000", accent: "#4A90D9"),
        ThemePreset(name: "Charcoal", isDark: true,
                    pageBackground: "#2E3136", codeBackground: "#26282C",
                    text: "#C6C8CA", accent: "#9FA8B2"),
        // Text is far darker/brighter than the canonical Solarized base
        // tones (#586E75 / #93A1A1), which read washed out at body sizes:
        // slate charcoal text, amber accent.
        ThemePreset(name: "Solarized Light", isDark: false,
                    pageBackground: "#FDF6E3", codeBackground: "#EEE8D5",
                    text: "#3A474D", accent: "#A5722B"),
        ThemePreset(name: "Solarized Dark", isDark: true,
                    pageBackground: "#002B36", codeBackground: "#073642",
                    text: "#BFC9C9", accent: "#2AA198"),
    ]
}
