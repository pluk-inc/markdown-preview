//
//  AppRelauncher.swift
//  md-preview
//
//  Relaunches the app through the normal quit path, so unsaved edits prompt
//  as usual and a cancelled quit leaves this instance running alone. Works
//  in the sandbox: the child inherits it, and `open` goes through Launch
//  Services like any other launch.
//

import AppKit

@MainActor
final class AppRelauncher {
    /// Set by `relaunch()` and consumed by the next `applicationShouldTerminate`,
    /// so a request can never outlive the quit attempt it started.
    private var isRequested = false
    /// Whether the termination now in progress relaunches when it completes.
    private var relaunchesOnTermination = false

    /// Quits through `NSApp.terminate`, so the delegate's save handling runs
    /// first. The new instance starts only from `applicationWillTerminate`:
    /// a cancelled quit never gets there.
    func relaunch() {
        isRequested = true
        // Scheduled on the run loop rather than called here: `terminate`
        // spins a nested run loop until the delegate replies, and a nested
        // loop entered from inside a main-queue dispatch block (an alert's
        // completion handler, for one) cannot run further blocks on that
        // queue — which is where the quit path's save completions arrive.
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// Called at the start of every quit attempt. A request that an earlier
    /// attempt moved here and then cancelled is replaced, so a later plain
    /// Quit does not relaunch.
    func terminationIsStarting() {
        relaunchesOnTermination = isRequested
        isRequested = false
    }

    /// Arms the new launch. Called from `applicationWillTerminate`, so every
    /// save prompt has been answered and this process is already past the
    /// point of cancelling.
    ///
    /// The launch itself happens only after this process has exited: a
    /// child shell waits for end-of-file on a pipe whose write end this
    /// process holds until it is gone, then asks Launch Services to open the
    /// bundle. Starting the new instance while this one is still quitting
    /// makes macOS skip the window restoration it does after any other quit
    /// (the app still counts as running), which left an empty launch.
    func launchNewInstanceIfRequested() {
        guard relaunchesOnTermination else { return }
        relaunchesOnTermination = false

        let pipe = Pipe()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "cat >/dev/null; exec /usr/bin/open -a \"$@\"", "relaunch",
                            Bundle.main.bundlePath] + Self.documentPathsToReopen()
        helper.standardInput = pipe
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            NSLog("Relaunch helper failed to start: %@", error.localizedDescription)
            return
        }
        // Kept until exit: releasing the pipe would close the write end and
        // relaunch while this instance is still here.
        relaunchHelper = helper
        relaunchPipe = pipe
    }

    private var relaunchHelper: Process?
    private var relaunchPipe: Pipe?

    /// The files to hand the new instance. With "Close windows when quitting
    /// an app" turned off, macOS restores every window itself and handing it
    /// the files too would open each document twice.
    private static func documentPathsToReopen() -> [String] {
        let restoresWindowsAfterQuit = UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows")
        guard !restoresWindowsAfterQuit else { return [] }
        return NSDocumentController.shared.documents.compactMap(\.fileURL?.path)
    }
}
