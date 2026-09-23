import Foundation
import XCTest
@testable import MarkdownHelpers

final class ThemePresetTests: XCTestCase {
    func testOriginalDarkBackgroundMatchesRequestedRGB() {
        XCTAssertEqual(ThemeColorsSetting.hexString(from: ThemeColorsSetting.defaultColor(.windowBackground, .dark)), "#1C1C1C")
        XCTAssertEqual(ThemeColorsSetting.hexString(from: ThemeColorsSetting.defaultColor(.editorBackground, .dark)), "#1C1C1C")
        XCTAssertEqual(ThemePreset.defaultPreset.darkPalette?.pageBackground, "#1C1C1C")
        XCTAssertFalse(ThemePreset.defaultPreset.setting.isCustomized)
    }

    func testEveryFixedPresetLocksItsAppearanceAndOriginalRemainsAdjustable() {
        let light = Set(["Paper", "Bold", "Calm", "Focus"])
        let dark = Set(["Quiet", "Graphite", "Dusk", "Midnight"])
        for preset in ThemePreset.builtIn {
            let required = preset.requiredAppearance
            if light.contains(preset.name) { XCTAssertEqual(required, .light, preset.name) }
            else if dark.contains(preset.name) { XCTAssertEqual(required, .dark, preset.name) }
            else { XCTAssertEqual(preset.name, "Original"); XCTAssertNil(required) }
        }
    }

    func testThemeIdentityDoesNotDependOnCustomColors() throws {
        let suite = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let graphite = try XCTUnwrap(ThemePreset.builtIn.first { $0.name == "Graphite" })
        ThemeColorsSetting.write(graphite.setting, to: defaults)
        XCTAssertEqual(ThemePreset.applied(in: defaults), .defaultPreset)
        XCTAssertNil(ThemePreset.applied(in: defaults).requiredAppearance)
        defaults.set(graphite.id, forKey: ThemePreset.appliedPresetKey)
        ThemeColorsSetting.write(ThemeColorsSetting(), to: defaults)
        XCTAssertEqual(ThemePreset.applied(in: defaults).requiredAppearance, .dark)
    }

    func testSavedLooksSurviveSwitchingAndReopeningDefaults() throws {
        let suite = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ThemePreset.defaultPreset
        let graphite = try XCTUnwrap(ThemePreset.builtIn.first { $0.name == "Graphite" })
        var look = original.restoredLook(in: defaults)
        XCTAssertEqual(look.appearance, .automatic)
        look.appearance = .light
        look.colors = graphite.setting // A matching custom palette is still Original.
        look.layout.isCustomized = true
        look.layout.marginsPercent = 25
        look.font = try XCTUnwrap(DocumentFontSetting.allCases.last)
        original.save(look, in: defaults)
        var darkLook = graphite.restoredLook(in: defaults)
        darkLook.layout.lineSpacing = 1.8
        darkLook.appearance = .light // Fixed themes must reconcile obsolete saved values.
        graphite.save(darkLook, in: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(original.restoredLook(in: reopened), look)
        XCTAssertEqual(graphite.restoredLook(in: reopened).appearance, .dark)
        XCTAssertEqual(graphite.restoredLook(in: reopened).layout.lineSpacing, 1.8)
        let reset = ThemePreset.SavedLook(colors: original.setting, font: original.font,
                                         layout: ReaderLayoutSetting(), appearance: .automatic)
        original.save(reset, in: reopened)
        XCTAssertEqual(original.restoredLook(in: defaults), reset)
        XCTAssertEqual(graphite.restoredLook(in: defaults).layout.lineSpacing, 1.8)
    }

    func testOriginalLeavesPageBackgroundToNativeWindow() throws {
        let original = ThemePreset.defaultPreset.setting
        XCTAssertFalse(original.isCustomized)
        XCTAssertNil(original.markdownThemeOverrides)
        XCTAssertEqual(EditorHTML.Configuration().lightPageBackground, "transparent")
        XCTAssertEqual(EditorHTML.Configuration().darkPageBackground, "transparent")
        XCTAssertEqual(original.editorOverrideCSS.components(separatedBy: "background: transparent").count - 1, 2)
        for preset in ThemePreset.builtIn where preset != .defaultPreset {
            XCTAssertEqual(preset.setting.markdownThemeOverrides?.darkPageBackground,
                           preset.setting.hexValue(.windowBackground, .dark))
            for scheme in ThemeColorScheme.allCases {
                let background = try XCTUnwrap(preset.setting.hexValue(.windowBackground, scheme))
                XCTAssertTrue(preset.setting.editorOverrideCSS.contains("background: \(background)"))
            }
        }
    }

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
