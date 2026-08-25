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
            Section {
                HStack(spacing: 16) {
                    if let appIcon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Markdown Preview"))
                            .font(.title)
                            .fontWeight(.medium)

                        Text(versionSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)

                Button(L("Check for Updates")) {
                    appDelegate?.updaterController.updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Section {
                Toggle(L("Automatically check for updates"),
                       isOn: $model.checksForUpdatesAutomatically)
                Toggle(L("Automatically download updates"),
                       isOn: $model.downloadsUpdatesAutomatically)
                    .disabled(!model.checksForUpdatesAutomatically)
                LabeledContent(L("Last checked")) {
                    Text(lastCheckedSummary).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L("Downloaded updates install the next time you quit Markdown Preview."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    private var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return String(format: L("Version %@ (%@)"), marketing, build)
    }

    private var lastCheckedSummary: String {
        guard let date = model.lastUpdateCheckDate else {
            return L("Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
