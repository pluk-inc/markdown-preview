//
//  ThemeSettingsView.swift
//  md-preview
//

import SwiftUI

// MARK: - Theme

/// Color overrides, one row per surface with a Light and a Dark well. A
/// deliberately small first set — presets and more surfaces come later on
/// the same storage.
struct ThemeSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        // Resolved once per pass: the footer, the Reset button, and every
        // card compare against it.
        let selected = selectedPreset
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("Appearance"))
                        .fixedSize()
                    Spacer(minLength: 16)
                    HStack(spacing: 16) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Button {
                                model.appearance = mode
                            } label: {
                                AppearanceOptionView(
                                    title: mode.settingsTitle,
                                    mode: mode,
                                    isSelected: model.appearance == mode
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode.settingsTitle)
                            .accessibilityAddTraits(
                                model.appearance == mode ? [.isSelected] : []
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(L("Appearance also applies to Quick Look previews."))
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(ThemePreset.builtIn) { preset in
                        presetCard(preset, isSelected: selected == preset)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("Presets"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L("Current theme: %@"),
                                selected.map { L($0.name) } ?? L("Custom colors")))
                    Text(L("A preset fills every color and switches the app to its light or dark look. Adjust individual colors below afterwards."))
                }
            }

            Section {
                colorRow(L("Window background"), slot: .windowBackground)
                colorRow(L("Code block background"), slot: .codeBlockBackground)
                colorRow(L("Text"), slot: .textColor)
                colorRow(L("Link"), slot: .linkColor)
            } header: {
                Text(L("Colors"))
            } footer: {
                Text(model.appearance == .automatic
                    ? L("Each color has a separate value for the Light and Dark appearance. Picking the default color removes the override.")
                    : L("Colors apply to the current appearance. Choose the Automatic appearance to set Light and Dark separately."))
            }

            Section {
                LabeledContent(L("Custom colors")) {
                    Button(L("Reset Colors")) {
                        model.resetThemeColors()
                    }
                    .disabled(selected == ThemePreset.defaultPreset)
                }
            } footer: {
                Text(L("Restores the default Normal theme."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    /// The preset the stored colors correspond to. Colors that were never
    /// customized count as the default preset — the app treats "no
    /// overrides" as the default theme, so the gallery always marks an
    /// active card. Hand-edited colors that match no preset return nil
    /// ("Custom colors").
    private var selectedPreset: ThemePreset? {
        if let match = ThemePreset.builtIn.first(where: { model.themeColors == $0.setting }) {
            return match
        }
        return model.themeColors.isCustomized ? nil : .defaultPreset
    }

    private func presetCard(_ preset: ThemePreset, isSelected: Bool) -> some View {
        let page = Self.color(hex: preset.palette.pageBackground)
        let text = Self.color(hex: preset.palette.text)
        let accent = Self.color(hex: preset.palette.accent)
        let badge: (symbol: String, color: Color) = switch preset.flavor {
        case .light: ("sun.max.fill", .orange)
        case .dark: ("moon.fill", .indigo)
        case .system: ("circle.lefthalf.filled", .secondary)
        }
        return Button {
            model.applyPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(L(preset.name))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(text)
                    Spacer(minLength: 4)
                    Image(systemName: badge.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(badge.color)
                }
                (Text("Lorem ipsum ").foregroundStyle(text.opacity(0.85))
                    + Text("dolor").bold().foregroundStyle(text)
                    + Text(" sit amet, ").foregroundStyle(text.opacity(0.85))
                    + Text("semper").foregroundStyle(accent)
                    + Text(" pharetra.").foregroundStyle(text.opacity(0.85)))
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(page)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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

    /// One well while the appearance is pinned (it edits the look on
    /// screen); separate labeled Light/Dark wells only in Automatic, where
    /// both schemes are reachable. Two always-visible wells confused more
    /// than they helped.
    private func colorRow(_ title: String, slot: ThemeColorSlot) -> some View {
        LabeledContent {
            HStack(spacing: 16) {
                switch model.appearance {
                case .light:
                    colorWell(L("Light"), slot: slot, scheme: .light,
                              showsLabel: false)
                case .dark:
                    colorWell(L("Dark"), slot: slot, scheme: .dark,
                              showsLabel: false)
                case .automatic:
                    colorWell(L("Light"), slot: slot, scheme: .light)
                    colorWell(L("Dark"), slot: slot, scheme: .dark)
                }
            }
        } label: {
            Text(title)
        }
    }

    private func colorWell(_ label: String,
                           slot: ThemeColorSlot,
                           scheme: ThemeColorScheme,
                           showsLabel: Bool = true) -> some View {
        HStack(spacing: 6) {
            if showsLabel {
                Text(label)
                    .foregroundStyle(.secondary)
            }
            ColorPicker(label, selection: colorBinding(slot: slot, scheme: scheme),
                        supportsOpacity: false)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }

    private func colorBinding(slot: ThemeColorSlot,
                              scheme: ThemeColorScheme) -> Binding<Color> {
        Binding(
            get: {
                let model = SettingsModel.shared
                let nsColor = model.themeColors.color(slot, scheme)
                    ?? ThemeColorsSetting.defaultColor(slot, scheme)
                return Color(nsColor: nsColor)
            },
            set: { newValue in
                SettingsModel.shared.setThemeColor(
                    NSColor(newValue), slot: slot, scheme: scheme
                )
            }
        )
    }
}
