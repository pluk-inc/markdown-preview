//
//  QuickLookDefault.swift
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

/// The Quick Look state for the Settings panes, and the two ways to start
/// the helper. One shared object, so a change made from one pane shows in
/// the other, and so the two kinds of launch never overlap: Launch Services
/// hands a second launch to the helper that is already running, which would
/// answer in the mode it was started in.
@Observable
final class QuickLookDefault {
    static let shared = QuickLookDefault()

    /// Nil until the helper answers, and when it cannot answer.
    private(set) var status: QuickLookDefaultStatus?

    private var statusRequest: Task<QuickLookDefaultStatus?, Never>?
    private var setup: Task<Void, Never>?

    private static let helper = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/Quick Look Setup.app")

    /// Asks the helper for the current state, with nothing on screen. While
    /// the helper's dialog is open it cannot answer; the state is read again
    /// when that dialog closes.
    func refresh() async {
        guard setup == nil else { return }
        // A second caller only waits. The caller that started the request
        // is the one that clears it, so a slot is never cleared by a caller
        // that does not own what is in it.
        if let statusRequest {
            _ = await statusRequest.value
            return
        }
        let request = Task { await Self.requestStatus() }
        statusRequest = request
        let answer = await request.value
        statusRequest = nil
        status = answer
    }

    /// Shows the helper's dialog, waits until the helper has quit, and reads
    /// the state again.
    func openSetup() async {
        if let setup {
            await setup.value
            return
        }
        let dialog = Task {
            _ = await statusRequest?.value
            await Self.runSetup()
        }
        setup = dialog
        await dialog.value
        setup = nil
        await refresh()
    }

    private static func runSetup() async {
        do {
            let app = try await NSWorkspace.shared.openApplication(at: helper, configuration: .init())
            // No time limit: the dialog stays open as long as the user
            // leaves it, and the state is read only after it closes.
            await waitForExit(of: app, seconds: .infinity)
        } catch {
            // The helper shows every other failure itself. This is the one
            // it cannot show: it never started.
            let alert = NSAlert()
            alert.messageText = L("The Quick Look extensions could not be changed.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private static func requestStatus() async -> QuickLookDefaultStatus? {
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
            // A cancelled sleep returns at once; without this exit the loop
            // would spin on the main actor until the deadline.
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
        }
    }
}
