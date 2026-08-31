//
//  ThemePresetCard.swift
//  md-preview
//
//  One card in the theme gallery: "Aa" in the preset's own page color, ink
//  and reading face, with the name below it. Shared by the toolbar popover
//  and the Appearance settings pane so the two galleries stay identical —
//  the pane is the way in for anyone who removed the toolbar button.
//

import SwiftUI

struct ThemePresetCard: View {
    let preset: ThemePreset
    let isSelected: Bool
    let action: () -> Void

    /// Fixed so a card reads the same in the popover's 3-column grid and the
    /// wider settings pane.
    static let height: CGFloat = 70
    private static let cornerRadius: CGFloat = 16

    var body: some View {
        let page = Self.color(hex: preset.palette.pageBackground)
        let text = Self.color(hex: preset.palette.text)

        return Button(action: action) {
            VStack(spacing: 4) {
                Text(verbatim: "Aa")
                    // The preset's own reading face, so the gallery shows
                    // the typeface each theme applies.
                    .font(preset.font.font(size: 24))
                    .fontWeight(preset.boldText ? .heavy : .semibold)
                    .foregroundStyle(text)
                Text(L(preset.name))
                    .font(.system(size: 11))
                    .foregroundStyle(text.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(page)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L(preset.name)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Palette colours resolved once for the whole gallery. Parsing a hex
    /// string compiles a regex, and a body pass would otherwise do it twice
    /// per card — 18 times for the built-in set, on every text-size tap.
    private static let resolved: [String: Color] = {
        let hexes = ThemePreset.builtIn.flatMap { preset -> [String] in
            let palettes = [preset.palette, preset.darkPalette].compactMap { $0 }
            return palettes.flatMap { [$0.pageBackground, $0.text] }
        }
        return Dictionary(hexes.map { ($0, parse(hex: $0)) },
                          uniquingKeysWith: { first, _ in first })
    }()

    private static func color(hex: String) -> Color {
        resolved[hex] ?? parse(hex: hex)
    }

    private static func parse(hex: String) -> Color {
        guard let nsColor = ThemeColorsSetting.color(fromHex: hex) else {
            return .primary
        }
        return Color(nsColor: nsColor)
    }
}
