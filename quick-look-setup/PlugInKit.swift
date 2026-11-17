//
//  PlugInKit.swift
//  quick-look-setup
//
//  Runs the system tools that read and change extension elections. This is
//  the reason the helper exists: `pluginkit` refuses every request from a
//  sandboxed process ("unauthorized discovery flag"), so the sandboxed app
//  cannot do this itself.
//

import Foundation

nonisolated enum PlugInKit {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func previewExtensions() throws -> [QuickLookExtension] {
        let output = try run("/usr/bin/pluginkit", ["-m", "-v", "-p", QuickLookExtensionScan.previewExtensionPoint])
        return QuickLookExtensionScan.parse(pluginkitOutput: output)
    }

    static func setElection(_ election: QuickLookExtension.Election, forIdentifier identifier: String) throws {
        try run("/usr/bin/pluginkit", ["-e", election.rawValue, "-i", identifier])
    }

    /// Quick Look keeps its choice of extension while its services run, so a
    /// changed election shows only after they start again. They start on the
    /// next preview. A service that is not running makes `killall` fail,
    /// which is not an error here.
    static func restartQuickLook() {
        _ = try? run("/usr/bin/killall", ["QuickLookUIService", "quicklookd"])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would block the tool forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw Failure(message: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
