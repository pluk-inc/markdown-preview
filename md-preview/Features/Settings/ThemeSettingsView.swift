//
//  ThemeSettingsView.swift
//  md-preview
//
//  The Appearance pane: light/dark choice and the theme gallery, with
//  Customize leading to the same Customize Theme sheet the toolbar popover
//  opens. It carries no controls of its own beyond that — everything here
//  is a second way to reach what the popover offers, for readers who took
//  the "aA" item out of the toolbar in Customize Toolbar.
//
//  The gallery uses ThemePresetCard, the popover's own card, so the two
//  surfaces cannot drift apart.
//

import SwiftUI

struct ThemeSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        let selected = model.selectedPreset
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
                ThemePresetGallery()
                    .padding(.vertical, 4)
            } header: {
                Text(L("Themes"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L("Current theme: %@"),
                                selected.map { L($0.name) } ?? L("Custom colors")))
                    Text(L("A theme fills every color, picks a reading face, and switches the app to its light or dark look."))
                }
            }

            Section {
                LabeledContent(L("Fonts, spacing and colors")) {
                    Button(L("Customize…")) {
                        openCustomizeSheet()
                    }
                }
            } footer: {
                Text(L("The same panel the toolbar's Themes & Settings button opens, with a Reset for the whole look."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    /// The sheet needs a host window. Settings is the one on screen when this
    /// pane is visible, so it hosts the sheet rather than a document window
    /// that may not exist.
    private func openCustomizeSheet() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        CustomizeThemeSheet.present(on: window)
    }
}
