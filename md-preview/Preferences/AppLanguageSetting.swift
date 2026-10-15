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

    /// The bundled language this process loaded its resources in. CFBundle
    /// fixes the main bundle's language list at launch, so this stays the same
    /// however the saved selection changes afterwards.
    static func loadedLanguage(in bundle: Bundle = .main) -> String {
        bundle.preferredLocalizations.first ?? systemDefault
    }

    /// The user's system-wide language list, read from the global domain so
    /// an app override never shadows it.
    static func systemLanguagePreferences(defaults: UserDefaults = .standard) -> [String] {
        defaults.persistentDomain(forName: UserDefaults.globalDomain)?[defaultsKey] as? [String] ?? []
    }

    /// The bundled language a selection loads on the next launch: the override
    /// itself, or the best match for the system's list when there is none.
    static func resolvedLanguage(for selection: String,
                                 languages: [String] = availableLanguages(),
                                 systemPreferences: [String] = systemLanguagePreferences()) -> String {
        guard selection == systemDefault else { return selection }
        return Bundle.preferredLocalizations(from: languages, forPreferences: systemPreferences).first
            ?? languages.first
            ?? systemDefault
    }

    /// True when only a relaunch can show the selection: it loads a language
    /// other than the one this process is showing. Re-selecting the loaded
    /// language, or a System Default that resolves to it, changes nothing.
    static func relaunchChangesLanguage(selection: String,
                                        loadedLanguage: String,
                                        languages: [String] = availableLanguages(),
                                        systemPreferences: [String] = systemLanguagePreferences()) -> Bool {
        resolvedLanguage(for: selection, languages: languages, systemPreferences: systemPreferences)
            != loadedLanguage
    }
}
