import Foundation

/// Shared by document previews and Quick Look. Preserve source newlines by
/// default; strict mode lets ordinary source wraps flow into one paragraph.
nonisolated enum StrictLineBreaksSetting {
    static let defaultsKey = "MarkdownPreview.strictLineBreaks"

    static var current: Bool {
        get { read(from: AppearanceMode.sharedDefaults()) }
        set { write(newValue, to: AppearanceMode.sharedDefaults()) }
    }

    static func read(from defaults: UserDefaults?) -> Bool {
        defaults?.bool(forKey: defaultsKey) ?? false
    }

    static func write(_ enabled: Bool, to defaults: UserDefaults?) {
        if enabled {
            defaults?.set(true, forKey: defaultsKey)
        } else {
            defaults?.removeObject(forKey: defaultsKey)
        }
    }
}
