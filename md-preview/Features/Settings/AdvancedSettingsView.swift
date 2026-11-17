//
//  AdvancedSettingsView.swift
//  md-preview
//
//  Tools most people set once or never: the command line tools, the Quick
//  Look extension choice, and the app link approvals.
//

import SwiftUI

struct AdvancedSettingsView: View {
    var body: some View {
        Form {
            LabeledContent(columnLabel("Command line tools")) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L("Install…")) {
                        appDelegate?.installCommandLineToolsFromSettings()
                    }
                    SettingsCaption(L("Adds mdp, md-preview, and markdown-preview to your PATH. Run it again after updating the app to refresh the commands."))
                }
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("Quick Look")) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L("Use for Markdown Files…")) {
                        Task { await QuickLookSetupLauncher.open() }
                    }
                    SettingsCaption(L("Turns off other Quick Look extensions that preview Markdown files, so Finder shows the Markdown Preview preview. Open it again to turn them back on."))
                }
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("App links")) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(L("Reset App Link Approvals")) {
                        ExternalLinkPolicy.reset(defaults: AppearanceMode.sharedDefaults())
                    }
                    SettingsCaption(L("Ask again before opening custom app links. Approvals are saved per URL scheme and shared with Quick Look."))
                }
            }
        }
        .formStyle(.columns)
    }
}
