import Foundation
import XCTest
@testable import MarkdownHelpers

final class BundleIdentifierMigrationTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    private let oldID = BundleIdentifierMigration.oldPrefix
    private var oldLibrary: URL { root.appendingPathComponent("old/Library", isDirectory: true) }
    private var oldSupport: URL { oldLibrary.appendingPathComponent("Application Support", isDirectory: true) }
    private var newSupport: URL { root.appendingPathComponent("new/Application Support", isDirectory: true) }
    private var handlers: URL { root.appendingPathComponent("handlers.plist") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdp-id-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "doc.md-preview.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testOldIdentifierKeepsTheSuffix() {
        XCTAssertEqual(BundleIdentifierMigration.oldIdentifier(for: "sh.pluk.md-preview"), "doc.md-preview")
        XCTAssertEqual(BundleIdentifierMigration.oldIdentifier(for: "sh.pluk.md-preview.dev"), "doc.md-preview.dev")
        XCTAssertNil(BundleIdentifierMigration.oldIdentifier(for: "sh.pluk.md-previewer"))
        XCTAssertNil(BundleIdentifierMigration.oldIdentifier(for: "doc.md-preview"))
    }

    func testCopiesSettingsAndSupportFiles() throws {
        try writeOldSettings(["MarkdownPreview.appearance": "dark", "Sidebar.Mode": 1])
        try write("[]", to: oldSupport.appendingPathComponent("SharedLinks/links.json"))

        migrate()

        XCTAssertEqual(defaults.string(forKey: "MarkdownPreview.appearance"), "dark")
        XCTAssertEqual(defaults.integer(forKey: "Sidebar.Mode"), 1)
        XCTAssertEqual(try String(contentsOf: newSupport.appendingPathComponent("SharedLinks/links.json"),
                                  encoding: .utf8), "[]")
        XCTAssertTrue(defaults.bool(forKey: BundleIdentifierMigration.doneKey))
    }

    func testKeepsWhatTheNewIdentifierAlreadyHas() throws {
        try writeOldSettings(["MarkdownPreview.appearance": "dark"])
        try write("old", to: oldSupport.appendingPathComponent("SharedLinks/links.json"))
        defaults.set("light", forKey: "MarkdownPreview.appearance")
        try write("new", to: newSupport.appendingPathComponent("SharedLinks/links.json"))

        migrate()

        XCTAssertEqual(defaults.string(forKey: "MarkdownPreview.appearance"), "light")
        XCTAssertEqual(try String(contentsOf: newSupport.appendingPathComponent("SharedLinks/links.json"),
                                  encoding: .utf8), "new")
    }

    func testLeavesBookmarksCrashFilesAndLinkedFoldersBehind() throws {
        try writeOldSettings(["ProjectNavigator.WriteAccessBookmarks": ["/tmp": Data([1])]])
        try write("x", to: oldSupport.appendingPathComponent("CrashReporter/report.plist"))
        try FileManager.default.createSymbolicLink(
            at: oldSupport.appendingPathComponent("AddressBook"), withDestinationURL: root)

        migrate()

        XCTAssertNil(defaults.object(forKey: "ProjectNavigator.WriteAccessBookmarks"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newSupport.appendingPathComponent("CrashReporter").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newSupport.appendingPathComponent("AddressBook").path))
    }

    func testOffersTheDefaultAppAgainOnlyWhenTheOldIdentifierWasChosen() throws {
        let key = BundleIdentifierMigration.defaultHandlerOfferKey
        try writeOldSettings([key: true])
        try writeHandlers([["LSHandlerContentType": "public.markdown", "LSHandlerRoleAll": "Doc.MD-Preview"]])
        migrate()
        XCTAssertFalse(defaults.bool(forKey: key))

        defaults.removePersistentDomain(forName: suiteName)
        // A URL scheme entry is not a choice of default app for a file type.
        try writeHandlers([["LSHandlerURLScheme": "md-preview", "LSHandlerRoleAll": "doc.md-preview"]])
        migrate()
        XCTAssertTrue(defaults.bool(forKey: key))
    }

    func testAsksForTheCommandLineToolCheckOnlyForTheReleaseApp() throws {
        try writeOldSettings([:])
        migrate()
        XCTAssertTrue(defaults.bool(forKey: BundleIdentifierMigration.commandLineToolCheckKey))

        defaults.removePersistentDomain(forName: suiteName)
        try writeOldSettings([:], identifier: "doc.md-preview.dev")
        migrate(oldIdentifier: "doc.md-preview.dev")
        XCTAssertFalse(defaults.bool(forKey: BundleIdentifierMigration.commandLineToolCheckKey))
    }

    func testANewInstallIsMarkedDoneWithNothingCopied() {
        migrate()
        XCTAssertTrue(defaults.bool(forKey: BundleIdentifierMigration.doneKey))
        XCTAssertFalse(defaults.bool(forKey: BundleIdentifierMigration.commandLineToolCheckKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newSupport.path))
    }

    func testUnreadableSettingsLeaveTheRunForTheNextLaunch() throws {
        try write("not a property list", to: oldLibrary.appendingPathComponent("Preferences/\(oldID).plist"))
        migrate()
        XCTAssertFalse(defaults.bool(forKey: BundleIdentifierMigration.doneKey))
    }

    func testAFileThatDoesNotCopyIsTriedAgainBeforeTheSettingsMove() throws {
        try writeOldSettings(["MarkdownPreview.appearance": "dark"])
        let source = oldSupport.appendingPathComponent("SharedLinks/links.json")
        try write("[]", to: source)
        // Unreadable: the copy of the folder fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }

        migrate()
        XCTAssertFalse(defaults.bool(forKey: BundleIdentifierMigration.doneKey))
        XCTAssertNil(defaults.string(forKey: "MarkdownPreview.appearance"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newSupport.appendingPathComponent("SharedLinks").path))

        // Readable at the next launch: the whole folder arrives.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        migrate()
        XCTAssertTrue(defaults.bool(forKey: BundleIdentifierMigration.doneKey))
        XCTAssertEqual(defaults.string(forKey: "MarkdownPreview.appearance"), "dark")
        XCTAssertEqual(try String(contentsOf: newSupport.appendingPathComponent("SharedLinks/links.json"),
                                  encoding: .utf8), "[]")
    }

    func testTheSettingsMoveAfterTheLastAttempt() throws {
        try writeOldSettings(["MarkdownPreview.appearance": "dark"])
        let source = oldSupport.appendingPathComponent("SharedLinks/links.json")
        try write("[]", to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path) }

        for _ in 0..<BundleIdentifierMigration.maximumAttempts { migrate() }

        XCTAssertTrue(defaults.bool(forKey: BundleIdentifierMigration.doneKey))
        XCTAssertEqual(defaults.string(forKey: "MarkdownPreview.appearance"), "dark")
        XCTAssertNil(defaults.object(forKey: BundleIdentifierMigration.attemptsKey))
    }

    func testFindsACommandThatStartsTheOldIdentifier() throws {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try write("#!/bin/sh\nexec open -b \"sh.pluk.md-preview\" \"$@\"\n", to: bin.appendingPathComponent("md-preview"))
        XCTAssertFalse(BundleIdentifierMigration.hasOutdatedCommandLineTool(in: [bin, root]))
        try write("#!/bin/sh\nexec open -b \"doc.md-preview\" \"$@\"\n", to: bin.appendingPathComponent("md-preview"))
        XCTAssertTrue(BundleIdentifierMigration.hasOutdatedCommandLineTool(in: [root, bin]))
    }

    // MARK: - Helpers

    private func migrate(oldIdentifier: String = BundleIdentifierMigration.oldPrefix) {
        BundleIdentifierMigration.run(oldIdentifier: oldIdentifier,
                                      oldLibrary: oldLibrary,
                                      defaults: defaults,
                                      domainName: suiteName,
                                      applicationSupport: newSupport,
                                      launchServicesPreferences: handlers)
    }

    private func writeOldSettings(_ settings: [String: Any], identifier: String = BundleIdentifierMigration.oldPrefix) throws {
        let url = oldLibrary.appendingPathComponent("Preferences/\(identifier).plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0).write(to: url)
    }

    private func writeHandlers(_ handlers: [[String: Any]]) throws {
        try PropertyListSerialization.data(fromPropertyList: ["LSHandlers": handlers], format: .binary, options: 0)
            .write(to: self.handlers)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
