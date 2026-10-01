import Foundation

/// Uses macOS's per-app language preference so nibs, menus, and Foundation
/// resolve the same localization on the next launch. Never writes global defaults
/// or the shared Quick Look suite.
enum AppLanguageSetting {
    static let systemDefault = ""
    static let defaultsKey = "AppleLanguages"

    /// Lists bundled translations, excluding the Base interface resources.
    static func availableLanguages(in bundle: Bundle = .main) -> [String] {
        bundle.localizations.filter { $0 != "Base" }.sorted()
    }

    /// Autonyms remain recognizable even when the current UI language is unfamiliar.
    static func displayName(for language: String) -> String {
        Locale(identifier: language).localizedString(forIdentifier: language) ?? language
    }

    /// Resolves an app-specific override to a bundled language, or System Default.
    static func selection(defaults: UserDefaults = .standard,
                          domain: String? = Bundle.main.bundleIdentifier,
                          languages: [String] = availableLanguages()) -> String {
        // Reading stringArray(forKey:) would also see the system's inherited list
        // and incorrectly present it as an explicit app override.
        guard let domain else { return systemDefault }
        let preferred = defaults.persistentDomain(forName: domain)?[defaultsKey] as? [String] ?? []
        guard !preferred.isEmpty else { return systemDefault }
        return Bundle.preferredLocalizations(from: languages, forPreferences: preferred).first ?? systemDefault
    }

    /// Persists the next-launch language, removing the override for System Default.
    static func save(_ language: String, defaults: UserDefaults = .standard) {
        if language == systemDefault {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set([language], forKey: defaultsKey)
        }
    }
}
