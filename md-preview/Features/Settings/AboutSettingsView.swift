//
//  AboutSettingsView.swift
//  md-preview
//

import Sparkle
import SwiftUI

// MARK: - About

struct AboutSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            LabeledContent(columnLabel("Version")) {
                HStack(spacing: 12) {
                    Text(versionNumber)
                        .textSelection(.enabled)
                    Button(L("Check for Updates")) {
                        appDelegate?.updaterController.updater.checkForUpdates()
                    }
                }
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("Updates")) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("Automatically check for updates"),
                           isOn: $model.checksForUpdatesAutomatically)
                    Toggle(L("Automatically download updates"),
                           isOn: $model.downloadsUpdatesAutomatically)
                        .disabled(!model.checksForUpdatesAutomatically)
                    SettingsCaption(L("Downloaded updates install the next time you quit Markdown Preview."))
                }
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("Last checked")) {
                Text(lastCheckedSummary).foregroundStyle(.secondary)
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("Links")) {
                VStack(alignment: .leading, spacing: 6) {
                    Link(L("GitHub Project"), destination: URL(string: "https://github.com/pluk-inc/markdown-preview")!)
                    Link(L("Discord Community"), destination: URL(string: "https://discord.com/invite/NUtNMK7re2")!)
                    Link(L("Buy Me a Coffee"), destination: BuyMeACoffee.url)
                }
            }
        }
        .formStyle(.columns)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    /// "0.0.69 (73)": the label already says Version.
    private var versionNumber: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(marketing) (\(build))"
    }

    private var lastCheckedSummary: String {
        guard let date = model.lastUpdateCheckDate else {
            return L("Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
