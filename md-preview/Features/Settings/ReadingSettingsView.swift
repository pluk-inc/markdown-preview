// Reading preferences shared with the existing menu and preview settings.
// Moving these controls does not change their persistence or rendering scope.

import SwiftUI

struct ReadingSettingsView: View {
    @AppStorage("MarkdownPreview.outlineFollowsPointer") private var outlineFollowsPointer = false
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            LabeledContent(columnLabel("Text size")) {
                TextSizePicker(selection: $model.textSize)
            }

            Picker(columnLabel("Content width"), selection: $model.contentWidth) {
                ForEach(ContentWidthSetting.allCases, id: \.self) { setting in
                    Text(setting.title).tag(setting)
                }
            }
            .fixedSize()

            Picker(columnLabel("Text alignment"), selection: $model.textAlignment) {
                ForEach(TextAlignmentSetting.allCases, id: \.self) { setting in
                    Text(setting.title).tag(setting)
                }
            }
            .fixedSize()
            SettingsCaption(L("Text size also applies to Quick Look previews. Zooming a document window with ⌘+ and ⌘− changes it too. Fonts and reading layout live in Appearance settings."))
                .settingsGroupGap()

            LabeledContent(columnLabel("Markdown")) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(L("Strict line breaks"), isOn: $model.strictLineBreaks)
                    SettingsCaption(L("Turn this off to keep every line break as written."))
                        .padding(.leading, 20)
                }
            }
            .settingsGroupGap()

            LabeledContent(columnLabel("Outline")) {
                Toggle(L("Highlight outline section under the pointer"), isOn: $outlineFollowsPointer)
            }
        }
        .formStyle(.columns)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }
}
