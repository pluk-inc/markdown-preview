//
//  ThemeSettingsView.swift
//  md-preview
//
//  The Appearance pane. Its controls write the settings directly; the
//  toolbar popover's Customize Theme sheet edits the same values through a
//  draft instead. The themes use the popover's own ThemePresetCard, in one
//  row that scrolls sideways.
//

import SwiftUI

/// The Appearance pane, laid out like Xcode's: the appearance choice, a
/// live sample page, and a segmented control that picks which part of the
/// reading look the controls below it edit. Every control writes through to
/// the settings at once, so the sample and the open documents follow along.
struct ThemeSettingsView: View {
    @Bindable private var model = SettingsModel.shared
    @AppStorage("MarkdownPreview.appearancePaneSection") private var section = Section.themes

    enum Section: String, CaseIterable {
        case themes, font, layout, colors

        var title: String {
            switch self {
            case .themes: L("Themes")
            case .font: L("Font")
            case .layout: L("Layout")
            case .colors: L("Colors")
            }
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Appearance"))
                    SettingsCaption(model.isAppearanceLocked
                        ? L("This theme uses a fixed appearance. Choose Original to change it.")
                        : L("Appearance also applies to Quick Look previews."))
                        .lineLimit(3, reservesSpace: true)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                Spacer(minLength: 16)
                appearancePicker
            }
            .padding(14)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            ThemeSamplePage(readerLayout: model.readerLayout,
                            documentFont: model.documentFont,
                            themeColors: model.themeColors,
                            columns: [ThemeSampleProse.columns[0]],
                            titleSize: 30,
                            bodySize: 14,
                            sampleHeight: 96,
                            pageHeight: 170) {
                // Top margin inside the page, so it takes the page color. The
                // page height is fixed: each theme's face sets "Aa" and the
                // prose at a different height, and a pane that changed height
                // would resize the window and shift everything below it.
                Color.clear.frame(height: 2)
            }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator))

            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .fixedSize()

            // Every section stays laid out and only the selected one shows,
            // so the pane keeps the tallest section's height and switching
            // sections never resizes the window.
            ZStack(alignment: .top) {
                ForEach(Section.allCases, id: \.self) { candidate in
                    sectionContent(candidate)
                        .opacity(candidate == section ? 1 : 0)
                        .allowsHitTesting(candidate == section)
                        // Hidden sections stay laid out; keep them out of
                        // keyboard focus too.
                        .disabled(candidate != section)
                        .accessibilityHidden(candidate != section)
                }
                // Colors has one layout for Automatic and another for a
                // fixed appearance. The other one is laid out too, never
                // shown, so a theme change cannot change the height and move
                // Reset Theme below.
                colorsSection(automatic: model.appearance != .automatic)
                    .hidden()
                    .disabled(true)
            }
            .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                Button(L("Reset Theme"), role: .destructive) { resetTheme() }
                    .disabled(isDefaultLook)
            }
        }
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    // MARK: - Appearance

    private var appearancePicker: some View {
        HStack(spacing: 16) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                Button {
                    model.appearance = mode
                } label: {
                    AppearanceOptionView(title: mode.settingsTitle,
                                         mode: mode,
                                         isSelected: model.appearance == mode)
                }
                .buttonStyle(.plain)
                .disabled(model.isAppearanceLocked)
                .accessibilityLabel(mode.settingsTitle)
                .accessibilityAddTraits(model.appearance == mode ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sectionContent(_ section: Section) -> some View {
        switch section {
        case .themes: themesSection
        case .font: fontSection
        case .layout: layoutSection
        case .colors: colorsSection(automatic: model.appearance == .automatic)
        }
    }

    private var themesSection: some View {
        // Spaced so the last visible card is cut off at the edge, which
        // shows the row scrolls.
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(ThemePreset.builtIn) { preset in
                    ThemePresetCard(preset: preset, isSelected: model.selectedPreset == preset) {
                        model.applyPreset(preset)
                    }
                    .frame(width: 104)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var fontSection: some View {
        Form {
            Picker(columnLabel("Font"), selection: $model.documentFont) {
                ForEach(DocumentFontSetting.allCases, id: \.self) { setting in
                    Text(setting.title).tag(setting)
                }
            }
            .fixedSize()
            Toggle(L("Bold Text"), isOn: $model.readerLayout.boldText)
        }
        .formStyle(.columns)
    }

    private var layoutSection: some View {
        Form {
            LabeledContent(columnLabel("Spacing")) {
                Toggle(L("Customize"), isOn: $model.readerLayout.isCustomized)
            }
            Group {
                slider("Line Spacing", value: $model.readerLayout.lineSpacing,
                       range: ReaderLayoutSetting.lineSpacingRange,
                       display: { String(format: "%.2f", $0) })
                slider("Character Spacing", value: $model.readerLayout.characterSpacingPercent,
                       range: ReaderLayoutSetting.characterSpacingRange)
                slider("Word Spacing", value: $model.readerLayout.wordSpacingPercent,
                       range: ReaderLayoutSetting.wordSpacingRange)
                slider("Margins", value: $model.readerLayout.marginsPercent,
                       range: ReaderLayoutSetting.marginsRange)
            }
            .disabled(!model.readerLayout.isCustomized)
        }
        .formStyle(.columns)
    }

    private func colorsSection(automatic: Bool) -> some View {
        Form {
            colorRow("Window background", slot: .windowBackground, automatic: automatic)
            colorRow("Code block background", slot: .codeBlockBackground, automatic: automatic)
            colorRow("Text", slot: .textColor, automatic: automatic)
            colorRow("Link", slot: .linkColor, automatic: automatic)
            SettingsCaption(automatic
                ? L("Each color has a separate value for the Light and Dark appearance. Picking the default color removes the override.")
                : L("Colors apply to the current appearance. Start with Original and choose Automatic to set Light and Dark separately."))
        }
        .formStyle(.columns)
    }

    // MARK: - Rows

    private func slider(_ titleKey: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        display: @escaping (Double) -> String = { "\(Int($0))%" }) -> some View {
        LabeledContent(columnLabel(titleKey)) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .frame(width: 220)
                Text(display(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }

    /// One well while the appearance is pinned; separate Light and Dark
    /// wells only in Automatic, where both schemes are reachable.
    private func colorRow(_ titleKey: String, slot: ThemeColorSlot, automatic: Bool) -> some View {
        LabeledContent(columnLabel(titleKey)) {
            HStack(spacing: 16) {
                if automatic {
                    colorWell(L("Light"), slot: slot, scheme: .light)
                    colorWell(L("Dark"), slot: slot, scheme: .dark)
                } else {
                    // One unlabeled well; the label names it for VoiceOver.
                    if model.appearance == .dark {
                        colorWell(L("Dark"), slot: slot, scheme: .dark, showsLabel: false)
                    } else {
                        colorWell(L("Light"), slot: slot, scheme: .light, showsLabel: false)
                    }
                }
            }
        }
    }

    private func colorWell(_ label: String, slot: ThemeColorSlot,
                           scheme: ThemeColorScheme, showsLabel: Bool = true) -> some View {
        HStack(spacing: 6) {
            if showsLabel {
                Text(label).foregroundStyle(.secondary)
            }
            ColorPicker(label, selection: Binding(
                get: {
                    Color(nsColor: model.themeColors.color(slot, scheme)
                        ?? ThemeColorsSetting.defaultColor(slot, scheme))
                },
                set: { model.setThemeColor(NSColor($0), slot: slot, scheme: scheme) }
            ), supportsOpacity: false)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reset

    private var isDefaultLook: Bool {
        model.readingLook == model.appliedPresetLook
    }

    private func resetTheme() {
        model.applyReadingLook(model.appliedPresetLook)
    }
}
