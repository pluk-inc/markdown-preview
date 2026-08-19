import AppKit
import XCTest
@testable import QuickLookHelpers

final class QuickLookEditingCommandsTests: XCTestCase {

    private let command = NSEvent.ModifierFlags.command.rawValue
    private let shift = NSEvent.ModifierFlags.shift.rawValue
    private let option = NSEvent.ModifierFlags.option.rawValue
    private let control = NSEvent.ModifierFlags.control.rawValue
    private let capsLock = NSEvent.ModifierFlags.capsLock.rawValue

    // The helper stays Foundation-only, so it mirrors the AppKit bit
    // values instead of importing them. Pin the mirror to the real thing.
    func testMasksMatchAppKit() {
        XCTAssertEqual(
            QuickLookEditingCommands.commandKeyMask,
            NSEvent.ModifierFlags.command.rawValue
        )
        XCTAssertEqual(
            QuickLookEditingCommands.capsLockKeyMask,
            NSEvent.ModifierFlags.capsLock.rawValue
        )
        XCTAssertEqual(
            QuickLookEditingCommands.deviceIndependentModifierMask,
            NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
        )
    }

    // MARK: - Mapping

    func testCommandASelectsAll() {
        XCTAssertEqual(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "a",
                modifierFlags: command
            ),
            .selectAll
        )
    }

    func testCommandCCopies() {
        XCTAssertEqual(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "c",
                modifierFlags: command
            ),
            .copy
        )
    }

    func testCapsLockDoesNotBlockTheChord() {
        XCTAssertEqual(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "A",
                modifierFlags: command | capsLock
            ),
            .selectAll
        )
        XCTAssertEqual(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "C",
                modifierFlags: command | capsLock
            ),
            .copy
        )
    }

    func testDeviceDependentBitsAreIgnored() {
        // Hardware/left-right key bits live below bit 16 and must not
        // disqualify the chord.
        let deviceDependentNoise: UInt = 0x0000_0108
        XCTAssertEqual(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "a",
                modifierFlags: command | deviceDependentNoise
            ),
            .selectAll
        )
    }

    // MARK: - Non-matches stay with WebKit

    func testOtherKeysAreNotClaimed() {
        for characters in ["b", "v", "x", "z", " ", ""] {
            XCTAssertNil(
                QuickLookEditingCommands.command(
                    forCharactersIgnoringModifiers: characters,
                    modifierFlags: command
                ),
                "⌘\(characters) must not be claimed"
            )
        }
        XCTAssertNil(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: nil,
                modifierFlags: command
            )
        )
    }

    func testExtraModifiersAreNotClaimed() {
        for extra in [shift, option, control] {
            XCTAssertNil(
                QuickLookEditingCommands.command(
                    forCharactersIgnoringModifiers: "a",
                    modifierFlags: command | extra
                )
            )
            XCTAssertNil(
                QuickLookEditingCommands.command(
                    forCharactersIgnoringModifiers: "c",
                    modifierFlags: command | extra
                )
            )
        }
    }

    func testMissingCommandKeyIsNotClaimed() {
        XCTAssertNil(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "a",
                modifierFlags: 0
            )
        )
        XCTAssertNil(
            QuickLookEditingCommands.command(
                forCharactersIgnoringModifiers: "c",
                modifierFlags: control
            )
        )
    }
}
