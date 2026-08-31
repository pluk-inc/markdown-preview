//
//  ThemePreset.swift
//  md-preview
//
//  Named built-in theme presets. A preset is a fixed palette written into
//  every ThemeColorsSetting slot; applying one also switches the app's
//  appearance to the preset's flavor so the native chrome (sidebar,
//  toolbar) matches. A `.system` preset keeps the Automatic appearance and
//  carries a separate dark palette, so both schemes stay readable while
//  the app keeps tracking the system look. The accent color maps to the
//  link slot — syntax highlighting keeps its own colors.
//

import Foundation

nonisolated struct ThemePreset: Identifiable, Equatable, Sendable {

    /// One scheme's colors ("#RRGGBB" each).
    struct Palette: Equatable, Sendable {
        /// Page background — window, gutters, and (via fallback) the
        /// editor page.
        let pageBackground: String
        /// Code block background.
        let codeBackground: String
        /// Body text.
        let text: String
        /// Accent — the link color, and the card sample's highlight.
        let accent: String
    }

    /// What applying the preset does to the app appearance: pin light,
    /// pin dark, or keep Automatic (`.system`).
    enum Flavor: Sendable {
        case light
        case dark
        case system
    }

    /// Display name; also the localization key.
    let name: String
    let flavor: Flavor
    /// The reading face the preset applies. A preset is a whole reading
    /// look, not only a palette — Books' themes carry a typeface too, and
    /// the gallery card draws its "Aa" in this face so the cards differ the
    /// way the pages will.
    let font: DocumentFontSetting
    /// Whether the preset reads in a heavier body weight.
    let boldText: Bool
    /// The palette; for a `.system` preset, the light-scheme palette.
    let palette: Palette
    /// Dark-scheme palette for `.system` presets. Nil reuses `palette`,
    /// which is right for presets that pin their flavor.
    let darkPalette: Palette?
    /// The preset expanded into slot values for both schemes. Precomputed:
    /// the settings pane compares the stored colors against it on every
    /// update, and expansion sanitizes each value through a regex.
    let setting: ThemeColorsSetting

    init(name: String, flavor: Flavor, palette: Palette, darkPalette: Palette? = nil,
         font: DocumentFontSetting = .system, boldText: Bool = false) {
        self.name = name
        self.flavor = flavor
        self.font = font
        self.boldText = boldText
        self.palette = palette
        self.darkPalette = darkPalette
        var setting = ThemeColorsSetting()
        for scheme in ThemeColorScheme.allCases {
            let colors = scheme == .dark ? (darkPalette ?? palette) : palette
            setting.setHex(colors.pageBackground, .windowBackground, scheme)
            // The editor follows the window color through the fallback
            // chain; a separate editor override is deliberately not exposed
            // yet, and any stored value is cleared so it cannot go stale.
            setting.setHex(nil, .editorBackground, scheme)
            setting.setHex(colors.codeBackground, .codeBlockBackground, scheme)
            setting.setHex(colors.text, .textColor, scheme)
            setting.setHex(colors.accent, .linkColor, scheme)
        }
        self.setting = setting
    }

    var id: String { name }

    /// The default theme: Reset Colors returns to it, and it leads the
    /// gallery.
    static var defaultPreset: ThemePreset { builtIn[0] }

    /// The built-in starter set, in gallery order — three rows of three:
    /// the Apple Books set (Original, Quiet, Paper / Bold, Calm, Focus)
    /// first, then the remaining dark themes. Original leads — it is the
    /// default theme.
    ///
    /// Display names are single evocative words in the Apple Books style.
    /// Quiet, Paper, Bold, and Focus are sampled from Apple Books' theme
    /// cards; the entries marked "Bear" are sampled from Bear's themes
    /// (editor page, inline-code pill, body text, link color) so the two
    /// apps render the same look side by side.
    static let builtIn: [ThemePreset] = [
        // The default: native macOS blue accents (light systemBlue
        // #007AFF, dark #0A84FF) on plain white / near-black pages. The
        // values are deliberately pinned — not derived from the stock
        // stylesheet — and follow the system appearance, so Reset returns
        // to the system look.
        ThemePreset(name: "Original", flavor: .system,
                    palette: Palette(pageBackground: "#FFFFFF", codeBackground: "#F2F2F2",
                                     text: "#000000", accent: "#007AFF"),
                    darkPalette: Palette(pageBackground: "#1E1E1E", codeBackground: "#2A2828",
                                         text: "#F5F5F7", accent: "#0A84FF")),
        // Apple Books "Quiet": soft dark gray with bright ink — sampled from
        // a reading page, not from the gallery card, whose label is muted.
        ThemePreset(name: "Quiet", flavor: .dark,
                    palette: Palette(pageBackground: "#4A4A4D", codeBackground: "#59595D",
                                     text: "#EBEBF4", accent: "#99B7C4")),
        // Apple Books "Paper": neutral light gray, softened ink, serif.
        ThemePreset(name: "Paper", flavor: .light,
                    palette: Palette(pageBackground: "#EEEDED", codeBackground: "#E3E1E1",
                                     text: "#262626", accent: "#DE4A4F"),
                    font: .charter),
        // Apple Books "Bold": plain white with heavy near-black text.
        ThemePreset(name: "Bold", flavor: .light,
                    palette: Palette(pageBackground: "#FFFFFF", codeBackground: "#F2F2F2",
                                     text: "#1C1C1E", accent: "#007AFF"),
                    boldText: true),
        // Bear "Solarized Light", with Books' serif reading face.
        ThemePreset(name: "Calm", flavor: .light,
                    palette: Palette(pageBackground: "#FDF6E3", codeBackground: "#F6EDDB",
                                     text: "#313D45", accent: "#A0630F"),
                    font: .georgia),
        // Apple Books "Focus": warm cream, high-contrast ink, serif.
        ThemePreset(name: "Focus", flavor: .light,
                    palette: Palette(pageBackground: "#FFFCF5", codeBackground: "#F5F1E4",
                                     text: "#14120B", accent: "#A0630F"),
                    font: .newYork),
        // Bear "Dark Graphite"
        ThemePreset(name: "Graphite", flavor: .dark,
                    palette: Palette(pageBackground: "#1D1E1F", codeBackground: "#2E2F30",
                                     text: "#E0E1E0", accent: "#42A2E6")),
        // Bear "Solarized Dark", with the body text lifted from Bear's own
        // #9BA7A4: that reads at about 4.8:1 on this page, the one theme
        // here below 7:1. #C3CFCC keeps the Solarized cast at ~7.9:1.
        ThemePreset(name: "Dusk", flavor: .dark,
                    palette: Palette(pageBackground: "#0C3742", codeBackground: "#103E49",
                                     text: "#C3CFCC", accent: "#299385")),
        // Bear "Dracula"
        ThemePreset(name: "Midnight", flavor: .dark,
                    palette: Palette(pageBackground: "#363846", codeBackground: "#313343",
                                     text: "#FFFFFF", accent: "#8BE9FD")),
    ]
}
