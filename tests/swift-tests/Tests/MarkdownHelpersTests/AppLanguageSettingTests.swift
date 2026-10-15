import Foundation
import XCTest
@testable import MarkdownHelpers

final class AppLanguageSettingTests: XCTestCase {
    func testOverridePersistsAndSystemDefaultRemovesOnlyLanguage() {
        let domain = "AppLanguageSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.register(defaults: ["AppleLanguages": ["zh-Hans"]])
        defaults.set(true, forKey: "unrelated")
        let languages = ["en", "zh-Hans"]
        XCTAssertEqual(AppLanguageSetting.selection(defaults: defaults, domain: domain, languages: languages), "")
        AppLanguageSetting.save("zh-Hans", defaults: defaults)
        XCTAssertEqual(AppLanguageSetting.selection(defaults: UserDefaults(suiteName: domain)!, domain: domain, languages: languages), "zh-Hans")
        AppLanguageSetting.save("en", defaults: defaults)
        XCTAssertEqual(AppLanguageSetting.selection(defaults: defaults, domain: domain, languages: languages), "en")
        AppLanguageSetting.save("", defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
        XCTAssertEqual(AppLanguageSetting.selection(defaults: defaults, domain: domain, languages: languages), "")
        XCTAssertTrue(defaults.bool(forKey: "unrelated"))
    }

    func testRegionalPreferenceResolvesToBundledTranslation() {
        let domain = "AppLanguageSettingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["en-GB"], forKey: "AppleLanguages")
        XCTAssertEqual(AppLanguageSetting.selection(defaults: defaults, domain: domain, languages: ["en", "zh-Hans"]), "en")
    }

    func testSystemDefaultResolvesToSystemLanguageOrEnglish() {
        let languages = ["en", "ja", "zh-Hans"]
        XCTAssertEqual(AppLanguageSetting.resolvedLanguage(for: "ja", languages: languages, systemPreferences: ["en-US"]), "ja")
        XCTAssertEqual(AppLanguageSetting.resolvedLanguage(for: "", languages: languages, systemPreferences: ["ja-JP", "en-US"]), "ja")
        XCTAssertEqual(AppLanguageSetting.resolvedLanguage(for: "", languages: languages, systemPreferences: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguageSetting.resolvedLanguage(for: "", languages: languages, systemPreferences: ["de-DE"]), "en")
        XCTAssertEqual(AppLanguageSetting.resolvedLanguage(for: "", languages: languages, systemPreferences: []), "en")
    }

    func testRelaunchIsOfferedOnlyWhenTheLoadedLanguageWouldChange() {
        let languages = ["en", "ja", "zh-Hans"]
        // Launched in English with the system set to Japanese.
        XCTAssertTrue(AppLanguageSetting.relaunchChangesLanguage(selection: "ja", loadedLanguage: "en", languages: languages, systemPreferences: ["ja-JP"]))
        XCTAssertTrue(AppLanguageSetting.relaunchChangesLanguage(selection: "", loadedLanguage: "en", languages: languages, systemPreferences: ["ja-JP"]))
        XCTAssertFalse(AppLanguageSetting.relaunchChangesLanguage(selection: "en", loadedLanguage: "en", languages: languages, systemPreferences: ["ja-JP"]))
        // Launched in Japanese by override: System Default on a Japanese system changes nothing.
        XCTAssertFalse(AppLanguageSetting.relaunchChangesLanguage(selection: "", loadedLanguage: "ja", languages: languages, systemPreferences: ["ja-JP"]))
        XCTAssertTrue(AppLanguageSetting.relaunchChangesLanguage(selection: "zh-Hans", loadedLanguage: "ja", languages: languages, systemPreferences: ["ja-JP"]))
    }
}
