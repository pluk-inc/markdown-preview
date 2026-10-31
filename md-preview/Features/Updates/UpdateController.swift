//
//  UpdateController.swift
//  md-preview
//
//  Sparkle's updater with our own user driver: an update shows as a small
//  capsule at the bottom of the document windows (UpdatePill) instead of
//  Sparkle's windows. Sparkle still checks, downloads, verifies and
//  installs; only the presentation changes. When no document window can
//  show the capsule — none is open, or the user checked from Settings —
//  the session goes to Sparkle's standard windows instead.
//

import AppKit
import Sparkle

final class UpdateController {
    let model = UpdateModel()
    let updater: SPUUpdater
    private let driver: UpdateDriver

    init() {
        model.didAppear = { model in
            for window in NSApp.windows {
                (window.windowController as? DocumentWindowController)?.installUpdatePill(model)
            }
        }
        driver = UpdateDriver(model: model)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                             userDriver: driver, delegate: driver)
    }

    func startUpdater() {
        #if DEBUG
        // `-MarkdownPreview.updatePillDemo available` (or checking,
        // upToDate, failed) plays the capsule without a release and keeps
        // the real updater stopped.
        if let demo = UserDefaults.standard.string(forKey: "MarkdownPreview.updatePillDemo") {
            return playDemo(demo)
        }
        #endif
        do {
            try updater.start()
        } catch {
            driver.showUpdaterError(error, acknowledgement: {})
        }
    }

    #if DEBUG
    private func playDemo(_ start: String) {
        switch start {
        case "checking": model.show(.checking, close: {})
        case "upToDate": model.show(.upToDate, close: {})
        case "failed": model.show(.failed, detail: "The update server could not be reached.", close: {})
        default:
            model.show(.available, detail: "Version 9.9.9", primary: { [weak self] in
                self?.playDemoDownload()
            }, close: {})
        }
    }

    private func playDemoDownload() {
        Task { [model] in
            model.show(.downloading(0), close: {})
            for percent in stride(from: 0, through: 100, by: 2) {
                model.update(.downloading(Double(percent) / 100))
                try? await Task.sleep(for: .milliseconds(60))
            }
            model.show(.preparing(1))
            try? await Task.sleep(for: .milliseconds(600))
            model.show(.ready, primary: { model.hide() }, close: {})
        }
    }
    #endif
}

private final class UpdateDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private let model: UpdateModel
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
    /// Decided when a session starts and kept until Sparkle dismisses it, so
    /// one update never moves between the capsule and Sparkle's windows.
    private var usesPill: Bool?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    init(model: UpdateModel) {
        self.model = model
    }

    private func routesToPill(userInitiated: Bool = false) -> Bool {
        if let usesPill { return usesPill }
        let decided = Self.pillHasTarget(userInitiated: userInitiated)
        usesPill = decided
        return decided
    }

    /// Every visible document window shows the capsule. A check the user
    /// asked for answers where they asked: from a document window in the
    /// capsule, from Settings in Sparkle's window.
    private static func pillHasTarget(userInitiated: Bool) -> Bool {
        let hasDocumentWindow = NSApp.windows.contains {
            $0.windowController is DocumentWindowController && $0.isVisible && !$0.isMiniaturized
        }
        guard hasDocumentWindow else { return false }
        return !userInitiated || NSApp.mainWindow?.windowController is DocumentWindowController
    }

    /// Sparkle's choice replies expect one answer; a second Download press
    /// before the capsule moves on would start a second download.
    private static func once(_ reply: @escaping (SPUUserUpdateChoice) -> Void) -> (SPUUserUpdateChoice) -> Void {
        var answered = false
        return { choice in
            guard !answered else { return }
            answered = true
            reply(choice)
        }
    }

    private static func versionLabel(_ item: SUAppcastItem) -> String {
        String(format: L("Version %@"), item.displayVersionString)
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // SUEnableAutomaticChecks answers this for most users; the rare
        // prompt is a choice worth Sparkle's full window.
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard routesToPill(userInitiated: true) else {
            return standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
        model.show(.checking, close: cancellation)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard routesToPill(userInitiated: state.userInitiated) else {
            return standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
        // Downloaded in the background, or resumed after a relaunch: one
        // click installs it.
        let phase: UpdateModel.Phase = state.stage == .notDownloaded ? .available : .ready
        let reply = Self.once(reply)
        model.show(phase, detail: Self.versionLabel(appcastItem),
                   primary: { reply(.install) },
                   close: { reply(.dismiss) })
    }

    // Release notes and focus requests come only inside a session that has
    // already been routed, so these never decide the route.

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if usesPill == false { standard.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        if usesPill == false { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard routesToPill() else {
            return standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
        model.show(.upToDate, detail: error.localizedDescription, close: acknowledgement)
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        guard routesToPill() else {
            return standard.showUpdaterError(error, acknowledgement: acknowledgement)
        }
        model.show(.failed, detail: error.localizedDescription, close: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        guard routesToPill() else { return standard.showDownloadInitiated(cancellation: cancellation) }
        model.show(.downloading(nil), close: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        guard routesToPill() else {
            return standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
        model.update(.downloading(expectedLength > 0 ? 0 : nil))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard routesToPill() else { return standard.showDownloadDidReceiveData(ofLength: length) }
        guard expectedLength > 0 else { return }
        // Whole percents only, so the capsule redraws a hundred times at
        // most rather than once per network packet.
        let percent = (min(Double(receivedLength) / Double(expectedLength), 1) * 100).rounded(.down)
        if model.phase != .downloading(percent / 100) {
            model.update(.downloading(percent / 100))
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        guard routesToPill() else { return standard.showDownloadDidStartExtractingUpdate() }
        model.show(.preparing(0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        guard routesToPill() else { return standard.showExtractionReceivedProgress(progress) }
        model.update(.preparing(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard routesToPill() else { return standard.showReady(toInstallAndRelaunch: reply) }
        let reply = Self.once(reply)
        // Dismissed, the update still installs when the app quits.
        model.show(.ready, primary: { reply(.install) }, close: { reply(.dismiss) })
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        guard routesToPill() else {
            return standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated,
                                                 retryTerminatingApplication: retryTerminatingApplication)
        }
        if applicationTerminated {
            model.show(.installing)
        } else {
            // A document with unsaved changes stopped the quit. Relaunch Now
            // asks again once the user has dealt with it.
            model.show(.ready, primary: retryTerminatingApplication, close: {})
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        model.hide()
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        guard usesPill == true else { return standard.showUpdateInFocus() }
        // Every document window shows the capsule: bring one forward.
        if NSApp.mainWindow?.windowController is DocumentWindowController { return }
        guard let window = NSApp.windows.first(where: {
            $0.windowController is DocumentWindowController && ($0.isVisible || $0.isMiniaturized)
        }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func dismissUpdateInstallation() {
        model.hide()
        standard.dismissUpdateInstallation()
        usesPill = nil
    }

    // MARK: SPUUpdaterDelegate

    /// An update downloaded in the background waits for the next quit. While
    /// a document window is open, offer to install it now.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard Self.pillHasTarget(userInitiated: false) else { return false }
        model.show(.ready, detail: Self.versionLabel(item),
                   primary: immediateInstallHandler, close: {})
        return true
    }
}
