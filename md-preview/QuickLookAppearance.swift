import Foundation

nonisolated enum QuickLookAppearanceMode: String, CaseIterable, Sendable {
    case automatic
    case light
    case dark

    static let defaultsKey = "MarkdownPreview.quickLookAppearance"
    static let appGroupInfoKey = "MarkdownPreviewAppGroupIdentifier"
    static let defaultMode: Self = .light

    static var current: Self {
        get { read(from: sharedDefaults()) }
        set { write(newValue, to: sharedDefaults()) }
    }

    static func sharedDefaults(bundle: Bundle = .main) -> UserDefaults? {
        guard let identifier = bundle.object(
            forInfoDictionaryKey: appGroupInfoKey
        ) as? String,
              !identifier.isEmpty else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    static func read(from defaults: UserDefaults?) -> Self {
        guard let rawValue = defaults?.string(forKey: defaultsKey),
              let mode = Self(rawValue: rawValue) else { return defaultMode }
        return mode
    }

    static func write(_ mode: Self, to defaults: UserDefaults?) {
        defaults?.set(mode.rawValue, forKey: defaultsKey)
    }

    func resolvedColorScheme(systemIsDark: Bool) -> MarkdownHTML.ColorScheme {
        switch self {
        case .automatic:
            return systemIsDark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
