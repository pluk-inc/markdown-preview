//
//  GeneralSettingsView.swift
//  md-preview
//

import SwiftUI

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable private var model = SettingsModel.shared
    @AppStorage("MarkdownPreview.coffeeRowClosed") private var coffeeRowClosed = false
    /// Nil until the helper answers, and when it cannot answer.
    @State private var quickLookStatus: QuickLookDefaultStatus?

    var body: some View {
        VStack(spacing: 18) {
            if !coffeeRowClosed {
                BuyMeACoffeeCard { coffeeRowClosed = true }
            }

            // Shown only while another app's extension competes for Markdown
            // files, like the default browser row in Safari. It sits above
            // the form because the sentence is wider than the form's
            // trailing column.
            if quickLookStatus?.competitors.isEmpty == false {
                HStack {
                    Text(L("Markdown Preview is not your default Quick Look preview for Markdown files."))
                    Button(L("Set Default…")) {
                        Task {
                            await QuickLookSetupLauncher.open()
                            quickLookStatus = await QuickLookSetupLauncher.status()
                        }
                    }
                }
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
        .task {
            quickLookStatus = await QuickLookSetupLauncher.status()
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
