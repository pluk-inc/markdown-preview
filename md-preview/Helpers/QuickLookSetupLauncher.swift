//
//  QuickLookSetupLauncher.swift
//  md-preview
//
//  Starts the embedded Quick Look Setup helper, which makes the Markdown
//  Preview extension the one Quick Look uses for Markdown files. The work
//  is in a separate app because the tool that reads and changes extension
//  elections refuses sandboxed callers. An app opened through Launch
//  Services does not inherit this app's sandbox.
//

import AppKit

/// What the helper found. Names are app names, for display.
struct QuickLookDefaultStatus: Equatable {
    /// Apps whose Quick Look extension competes with ours for Markdown
    /// files. Empty when ours is the only one turned on.
    let competitors: [String]
    /// Apps whose extension the helper turned off, and can turn back on.
    let turnedOff: [String]
}

enum QuickLookSetupLauncher {
    private static let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Quick Look Setup.app")

    /// Shows the helper's dialog and returns when the helper has quit.
    static func open() async {
        do {
            let app = try await NSWorkspace.shared.openApplication(at: helper, configuration: .init())
            await waitForExit(of: app, seconds: 600)
        } catch {
            // The helper shows every other failure itself. This is the one
            // it cannot show: it never started.
            let alert = NSAlert()
            alert.messageText = L("The Quick Look extensions could not be changed.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Asks the helper for the current state, with nothing on screen.
    /// Returns nil when the helper could not answer.
    static func status() async -> QuickLookDefaultStatus? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let asked = Date()
        // Launch arguments from a sandboxed app are dropped, so a URL to
        // open is the signal for "answer and quit". The helper's scheme is
        // its bundle id.
        guard let identifier = Bundle(url: helper)?.bundleIdentifier,
              let request = URL(string: "\(identifier)://status"),
              let app = try? await NSWorkspace.shared.open(
                  [request], withApplicationAt: helper, configuration: configuration
              )
        else { return nil }
        await waitForExit(of: app, seconds: 10)

        // The helper is not sandboxed, so its Application Support is in the
        // real home folder, not in this app's container.
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) else { return nil }
        let file = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/\(identifier)/status.plist")
        // An answer older than the question is from an earlier run: the
        // helper did not write one this time.
        guard let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              written >= asked.addingTimeInterval(-1),
              let answer = NSDictionary(contentsOf: file) as? [String: [String]]
        else { return nil }
        return QuickLookDefaultStatus(competitors: answer["competitors"] ?? [], turnedOff: answer["turnedOff"] ?? [])
    }

    private static func waitForExit(of app: NSRunningApplication, seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !app.isTerminated, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
