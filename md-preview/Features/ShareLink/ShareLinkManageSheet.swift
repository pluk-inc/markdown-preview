//
//  ShareLinkManageSheet.swift
//  md-preview
//
//  "Manage Shared Document…": the sheet for a file that already has a share
//  link. Copy Link uploads the current text under the same link and copies
//  it; Stop Sharing deletes the link. Laid out like the Pages sharing sheet,
//  without participants: a share link has none.
//

import AppKit
import Observation
import SwiftUI

@MainActor
enum ShareLinkManageSheet {

    static func present(on host: NSViewController, fileURL: URL, markdown: String) {
        let model = ShareLinkManageModel(fileURL: fileURL, markdown: markdown)
        // Built first and given its root view after, so the dismiss closure
        // can hold the controller weakly instead of through its own view.
        let hosting = NSHostingController(rootView: ShareLinkManageView(model: model, dismiss: {},
                                                                        confirmStop: { _ in }))
        hosting.rootView = ShareLinkManageView(model: model) { [weak hosting] in
            hosting?.dismiss(nil)
        } confirmStop: { [weak hosting] stop in
            guard let window = hosting?.view.window else { return }
            confirmStopSharing(on: window, then: stop)
        }
        // The view decides its own size. A fixed preferredContentSize fought
        // the view's natural height and looped the window's constraint passes
        // until AppKit threw.
        hosting.sizingOptions = .preferredContentSize
        host.presentAsSheet(hosting)
    }

    /// Stopping cannot be undone: the link stops working for everyone.
    private static func confirmStopSharing(on window: NSWindow, then stop: @escaping () -> Void) {
        let alert = NSAlert()
        // Sheet alerts hide the default icon; set it to show the app icon,
        // as Pages' stop-sharing alert does.
        alert.icon = NSApp.applicationIconImage
        alert.messageText = L("Stop sharing this document?")
        alert.informativeText = L("If you stop sharing, people with the link can no longer open this document, and its copy is deleted from the server.")
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { stop() }
        }
    }
}

@MainActor @Observable
final class ShareLinkManageModel {

    enum Activity: Equatable { case idle, copying, copied, stopping }

    let fileURL: URL
    private let markdown: String
    /// Worked out once; the view re-evaluates on every activity change.
    let icon: NSImage
    let summary: String
    private(set) var activity = Activity.idle
    private(set) var errorMessage: String?
    private(set) var record: ShareLinkStore.Record?

    var isBusy: Bool { activity == .copying || activity == .stopping }

    init(fileURL: URL, markdown: String) {
        self.fileURL = fileURL
        self.markdown = markdown
        icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        summary = SharePreviewItem.subtitle(for: markdown)
        record = ShareLinkStore.shared.record(forFile: fileURL)
    }

    func copyLink() async {
        activity = .copying
        errorMessage = nil
        do {
            try await ShareLinkSession.copyLink(forFile: fileURL, markdown: markdown)
            record = ShareLinkStore.shared.record(forFile: fileURL)
            activity = .copied
            try? await Task.sleep(for: .seconds(1.5))
            if activity == .copied { activity = .idle }
        } catch {
            errorMessage = ShareLinkSession.message(for: error)
            activity = .idle
        }
    }

    /// True when sharing stopped and the sheet can close.
    func stopSharing() async -> Bool {
        activity = .stopping
        errorMessage = nil
        do {
            try await ShareLinkSession.stopSharing(fileURL: fileURL)
            return true
        } catch {
            errorMessage = ShareLinkSession.message(for: error)
            activity = .idle
            return false
        }
    }
}

/// An AppKit pop-up with the first choice selected: SwiftUI's menu picker
/// sizes to its title and will not fill the column, and NSMenuItem gives
/// the other choices the native disabled look.
private struct PermissionPopUp: NSViewRepresentable {
    let choices: [(title: String, enabled: Bool)]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        for choice in choices {
            button.addItem(withTitle: choice.title)
            button.lastItem?.isEnabled = choice.enabled
        }
        button.selectItem(at: 0)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {}
}

struct ShareLinkManageView: View {
    let model: ShareLinkManageModel
    let dismiss: () -> Void
    /// Asks before stopping; calls its argument when the user agrees.
    let confirmStop: (_ stop: @escaping () -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Permissions"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    // A share link has one audience and one access level.
                    // The pop-ups match Pages; the other choices are shown
                    // but disabled.
                    PermissionPopUp(choices: [
                        (L("Anyone with the link"), true),
                        (L("People you choose"), false),
                    ])
                    .frame(maxWidth: .infinity)
                    PermissionPopUp(choices: [
                        (L("can view only"), true),
                        (L("can edit"), false),
                    ])
                    .frame(maxWidth: .infinity)
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: dismiss)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: model.icon)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.fileURL.lastPathComponent)
                    .font(.headline)
                Text(model.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let record = model.record {
                    Text(String(format: L("Shared · Link expires %@"),
                                record.expiresAt.formatted(date: .abbreviated, time: .omitted)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                confirmStop {
                    Task { if await model.stopSharing() { dismiss() } }
                }
            } label: {
                Text(L("Stop Sharing"))
                    .foregroundStyle(.red)
            }
            .disabled(model.isBusy)

            Button(model.activity == .copied ? L("Copied") : L("Copy Link")) {
                Task { await model.copyLink() }
            }
            .disabled(model.isBusy)

            Spacer()

            Button(L("Done"), action: dismiss)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }
}
