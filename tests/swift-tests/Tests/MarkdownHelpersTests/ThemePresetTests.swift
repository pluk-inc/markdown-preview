import Foundation
import XCTest
@testable import MarkdownHelpers

final class ThemePresetTests: XCTestCase {
    func testOriginalClearsEveryStoredColorOverride() throws {
        let suite = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var customized = ThemeColorsSetting()
        for scheme in ThemeColorScheme.allCases {
            for slot in ThemeColorSlot.allCases {
                customized.setHex("#123456", slot, scheme)
            }
        }
        ThemeColorsSetting.write(customized, to: defaults)
        ThemeColorsSetting.write(ThemePreset.defaultPreset.setting, to: defaults)

        let restored = ThemeColorsSetting.read(from: defaults)
        XCTAssertFalse(restored.isCustomized)
        XCTAssertNil(restored.markdownThemeOverrides)
        for scheme in ThemeColorScheme.allCases {
            XCTAssertFalse(restored.hasWindowBackgroundOverride(for: scheme))
            for slot in ThemeColorSlot.allCases {
                XCTAssertNil(defaults.object(forKey: ThemeColorsSetting.defaultsKey(scheme, slot)))
            }
        }
    }

    func testOtherPresetsKeepTheirPalettesForBothAppearances() {
        for preset in ThemePreset.builtIn where preset != .defaultPreset {
            for scheme in ThemeColorScheme.allCases {
                let palette = scheme == .dark ? (preset.darkPalette ?? preset.palette) : preset.palette
                XCTAssertEqual(preset.setting.hexValue(.windowBackground, scheme), palette.pageBackground)
                XCTAssertEqual(preset.setting.hexValue(.codeBlockBackground, scheme), palette.codeBackground)
                XCTAssertEqual(preset.setting.hexValue(.textColor, scheme), palette.text)
                XCTAssertEqual(preset.setting.hexValue(.linkColor, scheme), palette.accent)
                XCTAssertNil(preset.setting.hexValue(.editorBackground, scheme))
            }
        }
    }
}
