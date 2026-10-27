//
//  PrivacySettingsView.swift
//  md-preview
//

import SwiftUI

// MARK: - Privacy

struct PrivacySettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            LabeledContent(columnLabel("Crash reports")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Toggle(L("Send anonymous crash reports"), isOn: $model.sendsCrashReports)
                        SettingsInfoButton(L("Crash reports contain diagnostic details such as stack traces and OS and app versions. They may include technical file paths; Markdown Preview does not deliberately attach document contents or personal information."))
                    }
                    SettingsCaption(L("Contains technical details, not document contents."))
                        .padding(.leading, 20)
                }
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("Analytics")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Toggle(L("Share anonymous usage analytics"),
                               isOn: $model.sharesAnonymousUsageAnalytics)
                        SettingsInfoButton(L("When enabled, Markdown Preview sends at most one event per day when the app becomes active, linked to a random installation identifier. It also sends the app version, macOS major version, processor architecture, and locale country or region. This is used only to count daily and monthly active installations and understand basic platform compatibility. It does not send document contents, file names or paths, actions, screens, precise location, personal information, or advertising identifiers."))
                    }
                    SettingsCaption(L("At most one event a day, to count active installations."))
                        .padding(.leading, 20)
                }
            }
        }
        .formStyle(.columns)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }
}
