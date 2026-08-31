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
                LabeledContent {
                    TextSizePicker(selection: $model.textSize)
                } label: {
                    Text(L("Text size"))
                    Text(L("Size of rendered Markdown in document windows."))
                }

                Picker(L("Content width"), selection: $model.contentWidth) {
                    ForEach(ContentWidthSetting.allCases, id: \.self) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
            } header: {
                Text(L("Reading"))
            } footer: {
                Text(L("Text size also applies to Quick Look previews. Zooming a document window with ⌘+ and ⌘− changes it too. Fonts and reading layout live in Appearance settings."))
            }

            Section {
                Toggle(isOn: $model.isAlwaysOnTop) {
                    Text(L("Always on Top"))
                    Text(L("Keeps every Markdown Preview window in front of other apps, including windows you open later. A window in full screen is left alone until it comes back out."))
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
                Text(L("Editing"))
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
            } header: {
                Text(L("Hand-off"))
            } footer: {
                Text(L("The app the Open button in the document toolbar uses first. Its menu still offers every other installed app."))
            }

            Section {
                LabeledContent(L("Command line tools")) {
                    Button(L("Install…")) {
                        appDelegate?.installCommandLineToolsFromSettings()
                    }
                }
            } footer: {
                Text(L("Adds mdp, md-preview, and markdown-preview to your PATH. Run it again after updating the app to refresh the commands."))
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
