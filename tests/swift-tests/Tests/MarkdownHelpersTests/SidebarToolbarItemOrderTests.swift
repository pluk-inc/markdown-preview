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
        defaults.set(SidebarToolbarItemOrder.complete(edited, removedPlacement: .init(index: 0, hasSpacer: true)), forKey: key)
        XCTAssertEqual(defaults.stringArray(forKey: key),
                       ["SidebarMode", spacer, "toggle", "separator", "Print"])
    }

    func testToolbarWithoutPickerStaysCustomizedWithoutPicker() {
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Print"], removedPlacement: nil), ["Print"])
    }

    func testRestoringDefaultSetDoesNotDuplicatePickerOrSpacer() {
        let reset = ["SidebarMode", spacer, "toggle", "Print"]
        XCTAssertEqual(SidebarToolbarItemOrder.complete(reset, removedPlacement: .init(index: 0, hasSpacer: true)), reset)
    }

    func testRemovalOfOtherItemsClampsPlacementAndDoesNotInventSpacer() {
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Print"], removedPlacement: .init(index: 3, hasSpacer: false)),
                       ["Print", "SidebarMode"])
    }
    func testRemovingEarlierItemKeepsPickerBeforeItsSurvivingNeighbor() {
        let placement = SidebarToolbarItemOrder.Placement(
            index: 2, hasSpacer: true,
            identifiers: ["Print", "Share", "SidebarMode", spacer, "Search"]
        )
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Share", "Search"], removedPlacement: placement),
                       ["Share", "SidebarMode", spacer, "Search"])
        XCTAssertEqual(placement.insertionIndex(in: ["Share", "Search"]), 1)
    }

    func testMissingFollowingItemsFallsBackToSurvivingPredecessor() {
        let placement = SidebarToolbarItemOrder.Placement(
            index: 2, hasSpacer: false,
            identifiers: ["Print", "Share", "SidebarMode", "Search"]
        )
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Share"], removedPlacement: placement),
                       ["Share", "SidebarMode"])
    }

    func testUnchangedPrefixPreservesPlacementBeforeRepeatedSpaces() {
        let original = ["Print", "SidebarMode", spacer, spacer, "Search"]
        let placement = SidebarToolbarItemOrder.Placement(index: 1, hasSpacer: true, identifiers: original)
        XCTAssertEqual(SidebarToolbarItemOrder.complete(["Print", spacer, "Search"], removedPlacement: placement), original)
    }

}
