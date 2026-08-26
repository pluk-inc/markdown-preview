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
            Section {
                Toggle(L("Send anonymous crash reports"), isOn: $model.sendsCrashReports)
            } footer: {
                Text(L("Crash reports contain diagnostic details such as stack traces and OS and app versions. They may include technical file paths; Markdown Preview does not deliberately attach document contents or personal information."))
            }

            Section {
                Toggle(L("Share anonymous usage analytics"),
                       isOn: $model.sharesAnonymousUsageAnalytics)
            } footer: {
                Text(L("When enabled, Markdown Preview sends at most one event per day when the app becomes active, linked to a random installation identifier. It also sends the app version, macOS major version, processor architecture, and locale country or region. This is used only to count daily and monthly active installations and understand basic platform compatibility. It does not send document contents, file names or paths, actions, screens, precise location, personal information, or advertising identifiers."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }
}
