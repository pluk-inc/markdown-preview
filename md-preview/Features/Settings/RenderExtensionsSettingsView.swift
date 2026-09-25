//
//  RenderExtensionsSettingsView.swift
//  md-preview
//

import SwiftUI

extension SettingsPaneIcon {
    var extensionTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.4, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 20, height: 20)
            Image(systemName: "puzzlepiece.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

struct RenderExtensionsSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                ForEach(MarkdownHTML.renderExtensions, id: \.id) { renderExtension in
                    Toggle(
                        MarkdownHTML.renderExtensionTitle(for: renderExtension.id),
                        isOn: Binding(
                            get: { model.isRenderExtensionEnabled(renderExtension.id) },
                            set: { model.setRenderExtensionEnabled($0, id: renderExtension.id) }
                        )
                    )
                }
            } header: {
                Text(L("Markdown rendering"))
            } footer: {
                Text(L("These settings apply to document windows and Quick Look previews."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }
}
