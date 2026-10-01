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
}
