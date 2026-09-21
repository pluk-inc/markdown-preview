import AppKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class FullscreenToolbarThemeTests: XCTestCase {
    private func makePocket() throws -> NSView {
        guard #available(macOS 26.0, *),
              let cls = NSClassFromString("NSScrollPocket") as? NSView.Type else {
            throw XCTSkip("Full-screen scroll pockets require macOS 26 AppKit")
        }
        return cls.init(frame: .zero)
    }

    func testThemeChangeAndResetRestoreOriginalPocketState() throws {
        let pocket = try makePocket()
        pocket.setValue(NSColor.green, forKey: "captureColor")
        pocket.setValue(false, forKey: "prefersSolidColorHardPocket")
        let theme = FullscreenToolbarTheme()
        theme.apply(to: pocket, color: .red)
        XCTAssertEqual(pocket.value(forKey: "captureColor") as? NSColor, .red)
        XCTAssertEqual(pocket.value(forKey: "prefersSolidColorHardPocket") as? Bool, true)
        theme.apply(to: pocket, color: .blue)
        theme.apply(to: pocket, color: .blue)
        XCTAssertEqual(pocket.value(forKey: "captureColor") as? NSColor, .blue)
        theme.apply(to: pocket, color: nil)
        XCTAssertEqual(pocket.value(forKey: "captureColor") as? NSColor, .green)
        XCTAssertEqual(pocket.value(forKey: "prefersSolidColorHardPocket") as? Bool, false)
    }

    func testRebuiltToolbarRestoresOldPocketAndOnlyColorsNewSubtree() throws {
        let root = NSView()
        let old = try makePocket()
        let replacement = try makePocket()
        let unrelated = try makePocket()
        root.addSubview(NSView())
        root.subviews[0].addSubview(old)
        let theme = FullscreenToolbarTheme()
        theme.apply(to: root, color: .red)
        old.removeFromSuperview()
        root.addSubview(replacement)
        theme.apply(to: root, color: .blue)
        XCTAssertNil(old.value(forKey: "captureColor"))
        XCTAssertEqual(old.value(forKey: "prefersSolidColorHardPocket") as? Bool, false)
        XCTAssertEqual(replacement.value(forKey: "captureColor") as? NSColor, .blue)
        XCTAssertNil(unrelated.value(forKey: "captureColor"))
        theme.restore()
        XCTAssertNil(replacement.value(forKey: "captureColor"))
    }

    func testNormalWindowRestoresOverridesAndLeavesContentUntouched() throws {
        let pocket = try makePocket()
        let theme = FullscreenToolbarTheme()
        theme.apply(to: pocket, color: .red)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pocket
        theme.update(window: window, color: .blue)
        XCTAssertNil(pocket.value(forKey: "captureColor"))
        XCTAssertEqual(pocket.value(forKey: "prefersSolidColorHardPocket") as? Bool, false)
    }
}
