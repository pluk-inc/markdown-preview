import Foundation

nonisolated enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case automatic
    case light
    case dark

    static let defaultsKey = "MarkdownPreview.appearance"
    static let appGroupInfoKey = "MarkdownPreviewAppGroupIdentifier"
    static let defaultMode: Self = .automatic

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
        // Automatic is an explicit choice, not an unmigrated preference.
        // Removing it lets the next launch resurrect a legacy Light/Dark value.
        defaults?.set(mode.rawValue, forKey: defaultsKey)
    }

    @discardableResult
    static func migrateLegacyValue(
        from legacyDefaults: UserDefaults = .standard,
        to sharedDefaults: UserDefaults? = sharedDefaults()
    ) -> Self {
        if let rawValue = sharedDefaults?.string(forKey: defaultsKey),
           let sharedMode = Self(rawValue: rawValue) {
            return sharedMode
        }

        let legacyMode = read(from: legacyDefaults)
        write(legacyMode, to: sharedDefaults)
        return legacyMode
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
