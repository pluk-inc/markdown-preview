import Foundation

/// Which editing style edit mode shows: the formatted live preview (default)
/// or the plain Markdown source. Edit mode reopens in the style used last.
enum EditorSourceModeSetting {
    static let defaultsKey = "MarkdownPreview.editorSourceMode"

    static var current: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
