import Foundation
import XCTest
@testable import MarkdownHelpers

final class ReaderLayoutSettingTests: XCTestCase {

    // A fresh install renders exactly as it did before the setting existed:
    // no custom properties, so the stylesheet's tuned values stand.
    func testDefaultsEmitNoCSS() {
        XCTAssertEqual(ReaderLayoutSetting().cssVariables, "")
    }

    func testBoldTextEmitsAWeightOnlyWhenOn() {
        var setting = ReaderLayoutSetting()
        setting.boldText = true
        XCTAssertTrue(setting.cssVariables.contains("--mdp-body-weight: 600;"))

        setting.boldText = false
        XCTAssertFalse(setting.cssVariables.contains("--mdp-body-weight"))
    }

    // The Customize switch is the gate: slider positions persist while it is
    // off, but the page keeps the tuned defaults.
    func testSlidersOnlyApplyWhileCustomizeIsOn() {
        var setting = ReaderLayoutSetting()
        setting.lineSpacing = 1.8
        setting.characterSpacingPercent = 4
        setting.wordSpacingPercent = 6
        setting.marginsPercent = 50

        XCTAssertEqual(setting.cssVariables, "")
        XCTAssertEqual(setting.effective.lineSpacing, ReaderLayoutSetting.defaultLineSpacing)
        XCTAssertEqual(setting.pageInset, 0)

        setting.isCustomized = true
        let css = setting.cssVariables
        XCTAssertTrue(css.contains("--mdp-line-height: 1.800;"))
        XCTAssertTrue(css.contains("--mdp-letter-spacing: 0.040em;"))
        XCTAssertTrue(css.contains("--mdp-word-spacing: 0.060em;"))
        XCTAssertTrue(css.contains("--mdp-page-inset:"))
        XCTAssertEqual(setting.effective.lineSpacing, 1.8)
        XCTAssertGreaterThan(setting.pageInset, 0)
    }

    // Only values that differ from the stylesheet get a custom property, so a
    // reader who turns Customize on without moving a slider changes nothing.
    func testCustomizeWithUntouchedSlidersEmitsNoCSS() {
        var setting = ReaderLayoutSetting()
        setting.isCustomized = true
        XCTAssertEqual(setting.cssVariables, "")
    }

    func testValuesRoundTripAndDefaultsClearTheirKeys() throws {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var setting = ReaderLayoutSetting()
        setting.boldText = true
        setting.isCustomized = true
        setting.lineSpacing = 1.75
        setting.characterSpacingPercent = 3
        setting.wordSpacingPercent = -4
        setting.marginsPercent = 20
        ReaderLayoutSetting.write(setting, to: defaults)
        XCTAssertEqual(ReaderLayoutSetting.read(from: defaults), setting)

        ReaderLayoutSetting.write(ReaderLayoutSetting(), to: defaults)
        XCTAssertEqual(defaults.dictionaryRepresentation()
            .keys
            .filter { $0.hasPrefix("MarkdownPreview.readerLayout") },
                       [])
        XCTAssertEqual(ReaderLayoutSetting.read(from: defaults), ReaderLayoutSetting())
    }

    // Stored values are clamped on read: a hand-edited plist cannot push the
    // page to an unreadable line height or a zero-width column.
    func testStoredValuesAreClampedOnRead() throws {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(99.0, forKey: "MarkdownPreview.readerLayout.lineSpacing")
        defaults.set(-500.0, forKey: "MarkdownPreview.readerLayout.characterSpacing")
        defaults.set(999.0, forKey: "MarkdownPreview.readerLayout.margins")
        let setting = ReaderLayoutSetting.read(from: defaults)

        XCTAssertEqual(setting.lineSpacing, ReaderLayoutSetting.lineSpacingRange.upperBound)
        XCTAssertEqual(setting.characterSpacingPercent,
                       ReaderLayoutSetting.characterSpacingRange.lowerBound)
        XCTAssertEqual(setting.marginsPercent, ReaderLayoutSetting.marginsRange.upperBound)
    }

    // The decimals are written for CSS, not for the reader's locale — a comma
    // separator would make the declaration invalid.
    func testCSSNumbersUseAPeriodRegardlessOfLocale() {
        var setting = ReaderLayoutSetting()
        setting.isCustomized = true
        setting.lineSpacing = 1.4
        XCTAssertTrue(setting.cssVariables.contains("1.400"))
        XCTAssertFalse(setting.cssVariables.contains(","))
    }

    func testRenderedHTMLCarriesTheLayoutVariables() {
        var setting = ReaderLayoutSetting()
        setting.boldText = true
        setting.isCustomized = true
        setting.lineSpacing = 1.9
        let html = MarkdownHTML.makeHTML(from: "Body text.", readerLayout: setting)

        XCTAssertTrue(html.contains("--mdp-body-weight: 600;"))
        XCTAssertTrue(html.contains("--mdp-line-height: 1.900;"))
        // The stylesheet keeps literal fallbacks, so a page rendered with the
        // defaults still has a weight, leading and column width.
        XCTAssertTrue(html.contains("font-weight: var(--mdp-body-weight, 400);"))
        XCTAssertTrue(html.contains("line-height: var(--mdp-line-height,"))
        XCTAssertTrue(html.contains("padding-left: var(--mdp-page-inset,"))
    }
}
