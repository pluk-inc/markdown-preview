// Reading preferences shared with the existing menu and preview settings.
// Moving these controls does not change their persistence or rendering scope.

import SwiftUI

struct ReadingSettingsView: View {
    @AppStorage("MarkdownPreview.outlineFollowsPointer") private var outlineFollowsPointer = false
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

                Picker(L("Text alignment"), selection: $model.textAlignment) {
                    ForEach(TextAlignmentSetting.allCases, id: \.self) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
            } header: {
                Text(L("Text & layout"))
            } footer: {
                Text(L("Text size also applies to Quick Look previews. Zooming a document window with ⌘+ and ⌘− changes it too. Fonts and reading layout live in Appearance settings."))
                Text(L("Alignment applies to prose in reading view and Quick Look. Automatic follows the document. Code, tables and explicit HTML alignment are preserved."))
            }

            Section {
                Toggle(isOn: $model.strictLineBreaks) {
                    Text(L("Strict line breaks"))
                    Text(L("Join ordinary source lines into flowing paragraphs. Turn this off to preserve every line break. Applies to reading view and Quick Look previews."))
                }
                .accessibilityLabel(L("Strict line breaks"))
            } header: {
                Text(L("Markdown"))
            }

            Section {
                Toggle(L("Highlight outline section under the pointer"), isOn: $outlineFollowsPointer)
            } header: {
                Text(L("Outline"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }
}
