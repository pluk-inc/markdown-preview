//
//  SettingsSupport.swift
//  md-preview
//
//  Shared helpers for the Settings pane files.
//

import SwiftUI

func L(_ key: String, default value: String? = nil) -> String {
    let localized = NSLocalizedString(key, comment: "")
    if let value, localized == key {
        return value
    }
    return localized
}

var appDelegate: AppDelegate? {
    NSApp.delegate as? AppDelegate
}

// MARK: - Column layout

/// Width of every Settings pane, so switching tabs only changes the height.
let settingsPaneWidth: CGFloat = 640

/// A trailing-colon label for the leading column, as in Safari's Settings.
func columnLabel(_ key: String) -> String {
    String(format: L("%@:"), L(key))
}

/// Gray explanation under a control in the trailing column.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 360, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// The blank space Safari leaves between groups of settings.
    func settingsGroupGap() -> some View {
        padding(.bottom, 12)
    }
}

/// An ⓘ button that shows the full explanation in a popover, for settings
/// whose caption would otherwise run to several lines.
struct SettingsInfoButton: View {
    let text: String
    @State private var isShown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Details"))
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            Text(text)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}
