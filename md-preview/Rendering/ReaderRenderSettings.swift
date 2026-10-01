import Foundation

/// Reader settings that are baked into a page when it renders. A page or a
/// saved image made under other settings must not be shown as current.
@MainActor
struct ReaderRenderSettings: Equatable {
    let contentWidth: ContentWidthSetting
    let documentFont: DocumentFontSetting
    let textAlignment: TextAlignmentSetting
    let strictLineBreaks: Bool
    let readerLayout: ReaderLayoutSetting
    let themeOverrides: MarkdownHTML.ThemeOverrides?

    static var current: ReaderRenderSettings {
        ReaderRenderSettings(contentWidth: .current,
                             documentFont: .current,
                             textAlignment: .current,
                             strictLineBreaks: StrictLineBreaksSetting.current,
                             readerLayout: .current,
                             themeOverrides: ThemeColorsSetting.current.markdownThemeOverrides)
    }

    /// A stable text form for saving next to a file on disk.
    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let layout = (try? encoder.encode(readerLayout)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [contentWidth.rawValue, documentFont.rawValue, textAlignment.rawValue, layout, String(strictLineBreaks), themeOverrides?.css ?? ""]
            .joined(separator: "|")
    }
}
