import Foundation
import XCTest
@testable import MarkdownHelpers

final class EditExitPolicyTests: XCTestCase {
    private typealias Policy = EditExitPolicy

    func testChangedSourceAsksBeforeLeavingEditMode() {
        XCTAssertTrue(Policy.needsExitPrompt(currentSource: "edited", savedSource: "saved",
                                             exitsSilently: false))
    }

    // Typing and then undoing it leaves nothing to decide about, even though
    // the editor still reports that it changed.
    func testSourceMatchingTheSavedVersionLeavesWithoutAsking() {
        XCTAssertFalse(Policy.needsExitPrompt(currentSource: "saved", savedSource: "saved",
                                              exitsSilently: false))
    }

    func testTheSilentSettingNeverAsks() {
        XCTAssertFalse(Policy.needsExitPrompt(currentSource: "edited", savedSource: "saved",
                                              exitsSilently: true))
    }

    func testAnUnknownSavedVersionAsks() {
        XCTAssertTrue(Policy.needsExitPrompt(currentSource: "edited", savedSource: nil,
                                             exitsSilently: false))
    }

    // Return answers the first button and must never discard anything;
    // Escape must neither discard nor write.
    func testReturnSavesAndEscapeKeepsTheDraft() {
        XCTAssertEqual(Policy.exitButtonOrder.first, .save)
        XCTAssertEqual(Policy.escapeChoice, .continueUnsaved)
        XCTAssertNotEqual(Policy.exitButtonOrder.first, .revert)
        XCTAssertNotEqual(Policy.escapeChoice, .revert)
    }

    func testButtonIndicesMapBackToTheirChoices() {
        for (index, choice) in Policy.exitButtonOrder.enumerated() {
            XCTAssertEqual(Policy.exitChoice(forButtonAt: index), choice)
        }
        XCTAssertEqual(Policy.exitButtonOrder.count, 3)
    }

    func testAnUnexpectedResponseKeepsTheDraftAndWritesNothing() {
        XCTAssertEqual(Policy.exitChoice(forButtonAt: -1), .continueUnsaved)
        XCTAssertEqual(Policy.exitChoice(forButtonAt: 99), .continueUnsaved)
    }

    // Leaving edit mode can keep unsaved changes as a draft. File › Save and
    // ⌘S used to be disabled at that point although the save itself handled
    // it, so the draft could only be written by closing the window.
    func testSaveIsAvailableForUnsavedChanges() {
        XCTAssertTrue(Policy.isSaveCommandEnabled(hasUnsavedChanges: true))
    }

    // In edit mode or out of it: with nothing to save, Save is not offered.
    func testSaveIsNotOfferedWithNothingToSave() {
        XCTAssertFalse(Policy.isSaveCommandEnabled(hasUnsavedChanges: false))
    }

    func testRevertNeedsUnsavedChangesAndAFileToGoBackTo() {
        XCTAssertTrue(Policy.isRevertCommandEnabled(hasUnsavedChanges: true, hasFile: true))
        XCTAssertFalse(Policy.isRevertCommandEnabled(hasUnsavedChanges: false, hasFile: true))
    }

    func testAnUntitledDocumentHasNothingToRevertTo() {
        XCTAssertFalse(Policy.isRevertCommandEnabled(hasUnsavedChanges: true, hasFile: false))
    }

    // Save As… writes a copy, so it is offered whether or not anything changed.
    func testSaveAsIsAvailableForAnyOpenDocument() {
        XCTAssertTrue(Policy.isSaveAsCommandEnabled(hasDocument: true))
    }

    func testSaveAsNeedsADocument() {
        XCTAssertFalse(Policy.isSaveAsCommandEnabled(hasDocument: false))
    }

    func testThePromptIsOnWhenNothingHasBeenStored() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(Policy.read(from: defaults))
        XCTAssertFalse(Policy.read(from: nil))
    }

    func testTheSettingRoundTripsAndClearsItsKeyWhenOff() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        Policy.write(true, to: defaults)
        XCTAssertTrue(Policy.read(from: defaults))

        Policy.write(false, to: defaults)
        XCTAssertFalse(Policy.read(from: defaults))
        XCTAssertNil(defaults.object(forKey: Policy.defaultsKey))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
