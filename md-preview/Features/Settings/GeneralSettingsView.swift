//
//  GeneralSettingsView.swift
//  md-preview
//

import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable private var model = SettingsModel.shared
    @AppStorage("MarkdownPreview.coffeeRowClosed") private var coffeeRowClosed = false

    var body: some View {
        VStack(spacing: 18) {
            if !coffeeRowClosed {
                BuyMeACoffeeCard { coffeeRowClosed = true }
            }

            Form {
                Section {
                    Picker(columnLabel("Language"), selection: $model.appLanguage) {
                        Text(L("System Default")).tag(AppLanguageSetting.systemDefault)
                        ForEach(AppLanguageSetting.availableLanguages(), id: \.self) { language in
                            Text(verbatim: AppLanguageSetting.displayName(for: language)).tag(language)
                        }
                    }
                    .fixedSize()
                    SettingsCaption(L("Takes effect after you reopen Markdown Preview."))
                        .settingsGroupGap()
                }

                Section {
                    LabeledContent(columnLabel("Opening files")) {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(L("Open documents in tabs"), isOn: $model.opensDocumentsInTabs)
                            Toggle(L("Open Markdown links in new windows"), isOn: $model.opensMarkdownLinksInNewWindows)
                        }
                    }
                    .settingsGroupGap()

                    LabeledContent(columnLabel("Windows")) {
                        Toggle(L("Always on Top"), isOn: $model.isAlwaysOnTop)
                    }
                    .settingsGroupGap()
                }

                Section {
                    Picker(columnLabel("Automatic saving"), selection: $model.autoSaveIntervalMinutes) {
                        Text(L("Never")).tag(AutoSaveSetting.disabledMinutes)
                        Text(L("Instant")).tag(AutoSaveSetting.instant)
                        Text(L("30 seconds")).tag(AutoSaveSetting.thirtySeconds)
                        Text(L("1 minute")).tag(1)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                            Text(String(format: L("%d minutes"), minutes))
                                .tag(minutes)
                        }
                    }
                    .fixedSize()
                    .settingsGroupGap()

                    if model.openTargets.isEmpty {
                        LabeledContent(columnLabel("Open documents in")) {
                            Text(L("No apps available")).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker(columnLabel("Open documents in"), selection: $model.openTargetID) {
                            aiAppItems
                            editorItems
                        }
                        .fixedSize()
                    }
                }
            }
            .formStyle(.columns)
        }
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
