import AppKit
import XCTest
@testable import MarkdownHelpers

final class SidebarToolbarItemOrderTests: XCTestCase {
    private let spacer = NSToolbarItem.Identifier.flexibleSpace.rawValue

    func testCollapsedCustomizationPersistsPickerAndNewItemAcrossReload() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let key = "toolbar"
        defer { defaults.removeObject(forKey: key) }
        let edited = ["toggle", "separator", "Print"]
        defaults.set(SidebarToolbarItemOrder.complete(edited, removedPlacement: (0, true)), forKey: key)
        XCTAssertEqual(defaults.stringArray(forKey: key),
                       ["SidebarMode", spacer, "toggle", "separator", "Print"])
    }

    func testToolbarWithoutPickerStaysCustomizedWithoutPicker() {
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Print"], removedPlacement: nil), ["Print"])
    }

    func testRestoringDefaultSetDoesNotDuplicatePickerOrSpacer() {
        let reset = ["SidebarMode", spacer, "toggle", "Print"]
        XCTAssertEqual(SidebarToolbarItemOrder.complete(reset, removedPlacement: (0, true)), reset)
    }

    func testRemovalOfOtherItemsClampsPlacementAndDoesNotInventSpacer() {
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Print"], removedPlacement: (3, false)),
                       ["Print", "SidebarMode"])
    }
}
