//
//  ThemesPopoverView.swift
//  md-preview
//
//  Content of the toolbar's "aA" popover: text size, appearance, and the
//  theme preset gallery in one place, with Customize leading to the full
//  Appearance settings pane. A compact mirror of ThemeSettingsView driven
//  by the same SettingsModel, so a preset or appearance picked here reaches
//  every open window exactly like a change made in the Settings window.
//

import SwiftUI

struct ThemesPopoverView: View {
    @Bindable private var model = SettingsModel.shared

    private let decreaseTextSize: () -> Void
    private let increaseTextSize: () -> Void
    private let openCustomize: () -> Void

    init(decreaseTextSize: @escaping () -> Void,
         increaseTextSize: @escaping () -> Void,
         openCustomize: @escaping () -> Void) {
        self.decreaseTextSize = decreaseTextSize
        self.increaseTextSize = increaseTextSize
        self.openCustomize = openCustomize
    }

    var body: some View {
        let selected = model.selectedPreset
        VStack(spacing: 12) {
            Text(L("Themes & Settings"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 8) {
                textSizeControl
                appearanceButton
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: 3),
                      spacing: 8) {
                ForEach(ThemePreset.builtIn) { preset in
                    presetCard(preset, isSelected: selected == preset)
                }
            }

            Button(action: openCustomize) {
                Label(L("Customize"), systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .accessibilityLabel(L("Customize"))
        }
        .padding(14)
        .frame(width: 312)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    // MARK: - Text size

    /// The old toolbar zoom pair, relocated: a smaller and a larger "A"
    /// driving the same document zoom actions.
    private var textSizeControl: some View {
        HStack(spacing: 0) {
            textSizeButton(sampleSize: 12, title: L("Zoom Out"),
                           action: decreaseTextSize)
            Divider()
                .padding(.vertical, 9)
            textSizeButton(sampleSize: 17, title: L("Zoom In"),
                           action: increaseTextSize)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func textSizeButton(sampleSize: CGFloat,
                                title: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: "A")
                .font(.system(size: sampleSize, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - Appearance

    /// One button cycling Automatic → Light → Dark, shown as the current
    /// mode's symbol. The three-thumbnail picker stays in Settings; the
    /// popover only needs the quick flip.
    private var appearanceButton: some View {
        let title = String(format: L("Appearance: %@"),
                           model.appearance.settingsTitle)
        return Button(action: cycleAppearance) {
            Image(systemName: appearanceSymbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 56, height: 36)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(title)
        .accessibilityLabel(title)
    }

    private var appearanceSymbol: String {
        switch model.appearance {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private func cycleAppearance() {
        let modes = AppearanceMode.allCases
        guard let index = modes.firstIndex(of: model.appearance) else { return }
        model.appearance = modes[(index + 1) % modes.count]
    }

    // MARK: - Presets

    private func presetCard(_ preset: ThemePreset, isSelected: Bool) -> some View {
        let page = Self.color(hex: preset.palette.pageBackground)
        let text = Self.color(hex: preset.palette.text)
        return Button {
            model.applyPreset(preset)
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: "Aa")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(text)
                Text(L(preset.name))
                    .font(.system(size: 10))
                    .foregroundStyle(text.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(page)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L(preset.name)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func color(hex: String) -> Color {
        guard let nsColor = ThemeColorsSetting.color(fromHex: hex) else {
            return .primary
        }
        return Color(nsColor: nsColor)
    }
}
