//
//  main.swift
//  quick-look-setup
//
//  A small app, embedded in Markdown Preview, that makes the Markdown
//  Preview extension the one Quick Look uses for Markdown files. It is a
//  separate app because it must run outside the sandbox (see PlugInKit.swift);
//  the main app only starts it.
//
//  It runs in one of two ways and then quits:
//  - Started plainly, it asks before each change and makes the change.
//  - Started with a URL to open, it shows nothing and writes the current
//    state to a file the main app reads. A sandboxed app cannot pass launch
//    arguments, so the opened URL is the only signal it can send.
//

import AppKit

final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var isStatusRequest = false

    // Arrives before `applicationDidFinishLaunching` when the launch itself
    // carries the URL. A request that reaches a helper already showing its
    // dialog is dropped: the main app asks again when that helper quits.
    func application(_ application: NSApplication, open urls: [URL]) {
        isStatusRequest = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let setup = QuickLookSetup()
        if isStatusRequest {
            setup.writeStatus()
        } else {
            NSApp.activate()
            setup.run()
            setup.writeStatus()
        }
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = HelperDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
