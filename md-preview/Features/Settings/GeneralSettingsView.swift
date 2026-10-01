//
//  GeneralSettingsView.swift
//  md-preview
//

import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: $model.appLanguage) {
                    Text(L("System Default")).tag(AppLanguageSetting.systemDefault)
                    ForEach(AppLanguageSetting.availableLanguages(), id: \.self) { language in
                        Text(verbatim: AppLanguageSetting.displayName(for: language)).tag(language)
                    }
                }
            } header: {
                Text(L("Language"))
            } footer: {
                Text(L("Quit and reopen Markdown Preview to apply language changes. This setting only affects the app, not Quick Look previews."))
            }

            Section {
                Toggle(isOn: $model.isAlwaysOnTop) {
                    Text(L("Always on Top"))
                    Text(L("Keeps every Markdown Preview window in front of other apps, including windows you open later. A window in full screen is left alone until it comes back out."))
                }

                Toggle(isOn: $model.opensMarkdownLinksInNewWindows) {
                    Text(L("Open Markdown links in new windows"))
                    Text(L("Clicking a link to another Markdown file opens it in a separate window. Turn this off to open it in the current window."))
                }

                Toggle(isOn: $model.opensDocumentsInTabs) {
                    Text(L("Open documents in tabs"))
                    Text(L("A file opened from Finder joins the front window as a tab instead of getting one of its own — Open in New Window still opens a window."))
                }
            } header: {
                Text(L("Windows"))
            }

            Section {
                LabeledContent {
                    Picker("", selection: $model.autoSaveIntervalMinutes) {
                        Text(L("Never")).tag(AutoSaveSetting.disabledMinutes)
                        Text(L("30 seconds")).tag(AutoSaveSetting.thirtySeconds)
                        Text(L("1 minute")).tag(1)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                            Text(String(format: L("%d minutes"), minutes))
                                .tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } label: {
                    Text(L("Automatic saving"))
                    Text(L("Save edited documents periodically."))
                }
            } header: {
                Text(L("Saving"))
            } footer: {
                Text(L("Automatic saving runs while a document has unsaved edits."))
            }

            Section {
                if model.openTargets.isEmpty {
                    LabeledContent(L("Open documents in")) {
                        Text(L("No apps available")).foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L("Open documents in"), selection: $model.openTargetID) {
                        aiAppItems
                        editorItems
                    }
                }

                LabeledContent(L("Command line tools")) {
                    Button(L("Install…")) {
                        appDelegate?.installCommandLineToolsFromSettings()
                    }
                }
            } header: {
                Text(L("External apps & tools"))
            } footer: {
                Text(L("The app the Open button in the document toolbar uses first. Its menu still offers every other installed app."))
                Text(L("Adds mdp, md-preview, and markdown-preview to your PATH. Run it again after updating the app to refresh the commands."))
            }

            Section {
                Button(L("Reset App Link Approvals")) {
                    ExternalLinkPolicy.reset(defaults: AppearanceMode.sharedDefaults())
                }
            } header: {
                Text(L("App links"))
            } footer: {
                Text(L("Ask again before opening custom app links. Approvals are saved per URL scheme and shared with Quick Look."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
            model.reloadOpenTargets()
        }
    }

    @ViewBuilder
    private var aiAppItems: some View {
        let apps = model.openTargets.filter(\.isAIApp)
        if !apps.isEmpty {
            Section(L("AI apps")) {
                ForEach(apps) { choice in
                    openTargetRow(choice)
                }
            }
        }
    }

    @ViewBuilder
    private var editorItems: some View {
        let editors = model.openTargets.filter { !$0.isAIApp }
        if !editors.isEmpty {
            Section(L("Editors")) {
                ForEach(editors) { choice in
                    openTargetRow(choice)
                }
            }
        }
    }

    private func openTargetRow(_ choice: OpenTargetChoice) -> some View {
        HStack {
            Image(nsImage: choice.icon)
            Text(choice.title)
        }
        .tag(choice.id)
    }
}
