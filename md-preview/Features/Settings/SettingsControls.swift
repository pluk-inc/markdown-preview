//
//  SettingsControls.swift
//  md-preview
//

import SwiftUI

// MARK: - Text size

/// Three "Aa" samples drawn at the sizes they select.
///
/// Hand-built rather than a segmented `Picker` for two reasons: the segmented
/// style renders every item in the control's own font, which flattens the size
/// ramp that makes this control readable at a glance, and its optional-tag
/// matching selects the wrong segment. Nothing is highlighted when the stored
/// zoom sits between the stops.
struct TextSizePicker: View {
    @Binding var selection: TextSizeSetting?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TextSizeSetting.allCases, id: \.self) { size in
                Button {
                    selection = size
                } label: {
                    Text(verbatim: "Aa")
                        .font(.system(size: size.sampleFontSize))
                        .frame(width: 36, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == size
                                      ? Color.primary.opacity(0.1)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(size.title)
                .accessibilityAddTraits(selection == size ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Appearance thumbnails

extension AppearanceMode {
    var settingsTitle: String {
        switch self {
        case .automatic: return L("Automatic")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

/// Miniature window drawn in each appearance, the way System Settings previews
/// the choice instead of listing it in a pop-up.
struct AppearanceOptionView: View {
    let title: String
    let mode: AppearanceMode
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                switch mode {
                case .automatic:
                    HStack(spacing: 0) {
                        thumbnail(isDark: false).frame(width: 40).clipped()
                        thumbnail(isDark: true).frame(width: 40).clipped()
                    }
                case .light:
                    thumbnail(isDark: false)
                case .dark:
                    thumbnail(isDark: true)
                }
            }
            .frame(width: 80, height: 52)
            .clipShape(.rect(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(isDark: Bool) -> some View {
        let windowBackground = isDark ? Color(white: 0.15) : Color(white: 0.92)
        let pageBackground = isDark ? Color(white: 0.1) : Color.white
        let textColor = isDark ? Color(white: 0.28) : Color(white: 0.75)

        ZStack(alignment: .topLeading) {
            Rectangle().fill(windowBackground)

            HStack(spacing: 0) {
                // Sidebar, matching the document window's outline pane.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(textColor)
                            .frame(width: 14, height: 3)
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.leading, 4)
                .frame(width: 22)

                // Rendered Markdown: a heading rule over body lines.
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(textColor)
                        .frame(width: 26, height: 5)
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(textColor.opacity(0.6))
                            .frame(height: 2)
                    }
                    Spacer()
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(pageBackground))
                .padding(.top, 10)
                .padding(.trailing, 3)
                .padding(.bottom, 3)
            }

            HStack(spacing: 1.5) {
                Circle().fill(Color.red).frame(width: 4, height: 4)
                Circle().fill(Color.yellow).frame(width: 4, height: 4)
                Circle().fill(Color.green).frame(width: 4, height: 4)
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        }
    }
}
