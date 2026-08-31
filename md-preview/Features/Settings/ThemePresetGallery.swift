//
//  ThemePresetGallery.swift
//  md-preview
//
//  The theme gallery: the built-in presets as a grid of ThemePresetCards.
//  Both the toolbar popover and the Appearance settings pane show it, so
//  selection and the apply call live here rather than being written twice.
//

import SwiftUI

struct ThemePresetGallery: View {
    /// Gap between cards. The popover runs tighter than the settings pane.
    var spacing: CGFloat = 10
    /// Inset applied to each card inside its grid cell, so the cards read as
    /// tiles rather than a wall-to-wall grid.
    var cardInset: CGFloat = 0

    @Bindable private var model = SettingsModel.shared

    var body: some View {
        let selected = model.selectedPreset
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing),
                                 count: 3),
                  spacing: spacing) {
            ForEach(ThemePreset.builtIn) { preset in
                ThemePresetCard(preset: preset, isSelected: selected == preset) {
                    model.applyPreset(preset)
                }
                .padding(.horizontal, cardInset)
            }
        }
    }
}
