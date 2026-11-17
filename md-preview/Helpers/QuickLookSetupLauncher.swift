//
//  QuickLookSetupLauncher.swift
//  md-preview
//
//  Starts the embedded Quick Look Setup helper, which makes the Markdown
//  Preview extension the one Quick Look uses for Markdown files. The work
//  is in a separate app because the tool that changes extension elections
//  refuses sandboxed callers. An app opened through Launch Services does not
//  inherit this app's sandbox.
//

import AppKit

enum QuickLookSetupLauncher {
    static func open() {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/Quick Look Setup.app")
        NSWorkspace.shared.openApplication(at: helper, configuration: .init()) { _, error in
            guard let error else { return }
            // The helper shows every other failure itself. This is the one
            // it cannot show: it never started.
            let reason = error.localizedDescription
            Task { @MainActor in
                let alert = NSAlert()
                alert.messageText = L("The Quick Look extensions could not be changed.")
                alert.informativeText = reason
                alert.runModal()
            }
        }
    }
}
