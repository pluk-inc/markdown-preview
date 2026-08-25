//
//  ThemeColorsSetting.swift
//  md-preview
//
//  User-chosen theme color overrides. Each color is stored per appearance
//  (light/dark) as a "#RRGGBB" hex string in the shared app-group defaults —
//  the same suite AppearanceMode uses — and the key is removed at the default
//  value, so "not customized" and "default" stay one state. The slots are a
//  deliberately small first set; presets and more slots build on top of the
//  same storage.
//

import AppKit

nonisolated enum ThemeColorScheme: String, CaseIterable, Sendable {
    case light
    case dark
}

nonisolated enum ThemeColorSlot: String, CaseIterable, Sendable {
    /// The whole document window: the native window background, the surface
    /// behind the rendered page, and the gutters beside the centered column.
    case windowBackground
    /// The edit-mode page background.
    case editorBackground
    /// Code blocks, inline code, and the surfaces that derive from
    /// `--code-bg` (mermaid figures, frontmatter card).
    case codeBlockBackground
    /// Body text in the preview and the editor — the `--text` variable.
    /// Headings and secondary text derive from it; syntax highlighting
    /// keeps its own colors.
    case textColor
    /// Links in the preview and the editor — the `--link` variable. This is
    /// the theme's primary accent.
    case linkColor
}

nonisolated struct ThemeColorsSetting: Equatable, Sendable {

    /// "#RRGGBB" per scheme and slot. A missing entry means the default.
    private var values: [ThemeColorScheme: [ThemeColorSlot: String]] = [:]

    init() {}

    // MARK: - Persistence

    static func defaultsKey(_ scheme: ThemeColorScheme, _ slot: ThemeColorSlot) -> String {
        "MarkdownPreview.themeColor.\(scheme.rawValue).\(slot.rawValue)"
    }

    /// Shared with the Quick Look extension's suite so previews can adopt the
    /// same colors later; falls back to standard defaults outside the group.
    private static var defaults: UserDefaults? {
        AppearanceMode.sharedDefaults() ?? .standard
    }

    static var current: Self {
        get { read(from: defaults) }
        set { write(newValue, to: defaults) }
    }

    static func read(from defaults: UserDefaults?) -> Self {
        var setting = Self()
        guard let defaults else { return setting }
        for scheme in ThemeColorScheme.allCases {
            for slot in ThemeColorSlot.allCases {
                guard let raw = defaults.string(forKey: defaultsKey(scheme, slot)),
                      let hex = MarkdownHTML.ThemeOverrides.sanitizedHexColor(raw) else { continue }
                setting.values[scheme, default: [:]][slot] = hex
            }
        }
        return setting
    }

    static func write(_ setting: Self, to defaults: UserDefaults?) {
        guard let defaults else { return }
        for scheme in ThemeColorScheme.allCases {
            for slot in ThemeColorSlot.allCases {
                let key = defaultsKey(scheme, slot)
                if let hex = setting.hexValue(slot, scheme) {
                    defaults.set(hex, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }

    // MARK: - Values

    var isCustomized: Bool {
        values.values.contains { !$0.isEmpty }
    }

    /// True when either scheme overrides the window background. UI-level
    /// checks (Settings rows, preset equality) use this; chrome treatment
    /// must use the per-scheme variant below so a light-only override does
    /// not activate broken dark chrome.
    var hasWindowBackgroundOverride: Bool {
        hexValue(.windowBackground, .light) != nil
            || hexValue(.windowBackground, .dark) != nil
    }

    /// The chrome gate: whether the ACTIVE scheme has a window background
    /// override. Suppressing system chrome without a tint to replace it
    /// exposes the stock fills.
    func hasWindowBackgroundOverride(for scheme: ThemeColorScheme) -> Bool {
        hexValue(.windowBackground, scheme) != nil
    }

    func hexValue(_ slot: ThemeColorSlot, _ scheme: ThemeColorScheme) -> String? {
        values[scheme]?[slot]
    }

    func color(_ slot: ThemeColorSlot, _ scheme: ThemeColorScheme) -> NSColor? {
        hexValue(slot, scheme).flatMap(Self.color(fromHex:))
    }

    /// Stores a sanitized hex value directly — the preset path. Unlike
    /// `setColor`, a value equal to the default is kept; presets pin their
    /// palette explicitly.
    mutating func setHex(_ hex: String?,
                         _ slot: ThemeColorSlot,
                         _ scheme: ThemeColorScheme) {
        guard let sanitized = MarkdownHTML.ThemeOverrides.sanitizedHexColor(hex) else {
            values[scheme]?[slot] = nil
            return
        }
        values[scheme, default: [:]][slot] = sanitized
    }

    /// Stores a picked color; picking the default color clears the override
    /// so the slot follows the app defaults again.
    mutating func setColor(_ color: NSColor,
                           _ slot: ThemeColorSlot,
                           _ scheme: ThemeColorScheme) {
        guard let hex = Self.hexString(from: color) else { return }
        if hex == Self.hexString(from: Self.defaultColor(slot, scheme)) {
            values[scheme]?[slot] = nil
        } else {
            values[scheme, default: [:]][slot] = hex
        }
    }

    /// What the slot renders as when no override is stored — shown as the
    /// color well's initial swatch.
    static func defaultColor(_ slot: ThemeColorSlot, _ scheme: ThemeColorScheme) -> NSColor {
        switch (slot, scheme) {
        case (.windowBackground, .light):
            // DocumentBackgroundView paints the light page white.
            return .white
        case (.windowBackground, .dark):
            return resolvedWindowBackground(dark: true)
        case (.editorBackground, .light):
            // The editor page background is CSS `Canvas`.
            return .white
        case (.editorBackground, .dark):
            return NSColor(srgbRed: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
        case (.codeBlockBackground, .light):
            // --code-bg in MarkdownHTML.stylesheet: #f5f5f7 / #2A2828.
            return NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
        case (.codeBlockBackground, .dark):
            return NSColor(srgbRed: 42 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1)
        case (.textColor, .light):
            // --text in MarkdownHTML.stylesheet: #1d1d1f / #f5f5f7.
            return NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1)
        case (.textColor, .dark):
            return NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
        case (.linkColor, .light):
            // --link in MarkdownHTML.stylesheet: #0066cc / #2997ff.
            return NSColor(srgbRed: 0, green: 102 / 255, blue: 204 / 255, alpha: 1)
        case (.linkColor, .dark):
            return NSColor(srgbRed: 41 / 255, green: 151 / 255, blue: 255 / 255, alpha: 1)
        }
    }

    private static func resolvedWindowBackground(dark: Bool) -> NSColor {
        var resolved = NSColor.windowBackgroundColor
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        appearance?.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: NSColor.windowBackgroundColor.cgColor)
                ?? NSColor.windowBackgroundColor
        }
        return resolved
    }

    // MARK: - Rendered-surface overrides

    /// Overrides handed to `MarkdownHTML.render` for the preview page.
    var markdownThemeOverrides: MarkdownHTML.ThemeOverrides? {
        let lightCode = hexValue(.codeBlockBackground, .light)
        let darkCode = hexValue(.codeBlockBackground, .dark)
        let lightPage = hexValue(.windowBackground, .light)
        let darkPage = hexValue(.windowBackground, .dark)
        let lightText = hexValue(.textColor, .light)
        let darkText = hexValue(.textColor, .dark)
        let lightLink = hexValue(.linkColor, .light)
        let darkLink = hexValue(.linkColor, .dark)
        guard lightCode != nil || darkCode != nil
                || lightPage != nil || darkPage != nil
                || lightText != nil || darkText != nil
                || lightLink != nil || darkLink != nil else { return nil }
        return MarkdownHTML.ThemeOverrides(
            lightCodeBackground: lightCode,
            darkCodeBackground: darkCode,
            lightPageBackground: lightPage,
            darkPageBackground: darkPage,
            lightText: lightText,
            darkText: darkText,
            lightLink: lightLink,
            darkLink: darkLink
        )
    }

    /// Override stylesheet for the edit-mode page. The editor themes through
    /// `prefers-color-scheme` only (no host color-scheme attribute), so two
    /// media buckets cover it.
    var editorOverrideCSS: String {
        func rules(for scheme: ThemeColorScheme) -> String {
            var lines: [String] = []
            if let code = sanitizedHex(.codeBlockBackground, scheme) {
                lines.append(":root { --code-bg: \(code); }")
            }
            if let text = sanitizedHex(.textColor, scheme) {
                lines.append(":root { --text: \(text); }")
            }
            if let link = sanitizedHex(.linkColor, scheme) {
                lines.append(":root { --link: \(link); }")
            }
            // The editor follows the window color unless it has its own
            // override — one picked color themes both modes. Always emitted
            // (Canvas when unthemed): the page template bakes the value
            // present at load time into its base stylesheet, and a reset
            // must override that baked value on the live page too.
            let page = sanitizedHex(.editorBackground, scheme)
                ?? sanitizedHex(.windowBackground, scheme)
                ?? "Canvas"
            lines.append("html, body { background: \(page); }")
            return lines.joined(separator: "\n")
        }
        let light = rules(for: .light)
        let dark = rules(for: .dark)
        var css = light
        if !dark.isEmpty {
            css += (css.isEmpty ? "" : "\n")
                + "@media (prefers-color-scheme: dark) {\n\(dark)\n}"
        }
        return css
    }

    private func sanitizedHex(_ slot: ThemeColorSlot, _ scheme: ThemeColorScheme) -> String? {
        MarkdownHTML.ThemeOverrides.sanitizedHexColor(hexValue(slot, scheme))
    }

    /// Script that installs or refreshes the theme override `<style>` element
    /// in an already-loaded preview or editor page.
    static func styleUpdateScript(css: String) -> String {
        let literal = MarkdownHTML.javaScriptStringLiteral(css)
        return """
        (function () {
            var el = document.getElementById('\(MarkdownHTML.themeStyleElementID)');
            if (!el) {
                el = document.createElement('style');
                el.id = '\(MarkdownHTML.themeStyleElementID)';
                document.head.appendChild(el);
            }
            el.textContent = \(literal);
        })();
        """
    }

    // MARK: - Hex conversion

    static func hexString(from color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        let blue = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    static func color(fromHex hex: String) -> NSColor? {
        guard let sanitized = MarkdownHTML.ThemeOverrides.sanitizedHexColor(hex) else { return nil }
        let digits = String(sanitized.dropFirst())
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value) else { return nil }
        // #RRGGBBAA carries alpha in the low byte (CSS order).
        let alpha: CGFloat
        if digits.count == 8 {
            alpha = CGFloat(value & 0xFF) / 255
            value >>= 8
        } else {
            alpha = 1
        }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
