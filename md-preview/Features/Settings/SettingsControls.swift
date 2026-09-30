//
 //  SettingsControls.swift
 //  md-preview
 //

import SwiftUI

// MARK: - Text size

/// Stepper-based text size control with +/- buttons and current size display.
/// Steps through the same discrete zoom stops used by ⌘+/⌘−, pinch, and the toolbar.
struct TextSizeStepper: View {
    @Binding var selection: TextSizeSetting

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if selection.canStepDown {
                    selection = selection.steppedDown()
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!selection.canStepDown)
            .accessibilityLabel(L("Decrease text size"))
            .accessibilityHint(L("Steps to the next smaller preset size"))

            Text(selection.displayString)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 56)
                .accessibilityLabel(String.localizedStringWithFormat(L("Current text size: %@"), selection.displayString))

            Button {
                if selection.canStepUp {
                    selection = selection.steppedUp()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(!selection.canStepUp)
            .accessibilityLabel(L("Increase text size"))
            .accessibilityHint(L("Steps to the next larger preset size"))
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