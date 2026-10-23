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
        let hosting = NSHostingController(rootView: ShareLinkManageView(model: model, dismiss: {}))
        hosting.rootView = ShareLinkManageView(model: model) { [weak hosting] in
            hosting?.dismiss(nil)
        }
        // The view decides its own size. A fixed preferredContentSize fought
        // the view's natural height and looped the window's constraint passes
        // until AppKit threw.
        hosting.sizingOptions = .preferredContentSize
        host.presentAsSheet(hosting)
    }
}

@MainActor @Observable
final class ShareLinkManageModel {

    enum Activity: Equatable { case idle, copying, stopping }

    let fileURL: URL
    let markdown: String
    private(set) var activity = Activity.idle
    private(set) var errorMessage: String?
    private(set) var record: ShareLinkStore.Record?

    init(fileURL: URL, markdown: String) {
        self.fileURL = fileURL
        self.markdown = markdown
        record = ShareLinkStore.shared.record(forFile: fileURL)
    }

    func copyLink() async {
        activity = .copying
        errorMessage = nil
        do {
            let link = try await ShareLinkSession.link(forFile: fileURL, markdown: markdown)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            record = ShareLinkStore.shared.record(forFile: fileURL)
            activity = .idle
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

struct ShareLinkManageView: View {
    let model: ShareLinkManageModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Permissions"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    // A share link has one audience and one access level;
                    // shown like Pages' pop-ups, but there is nothing to pick.
                    readOnlyChoice(L("Anyone with the link"))
                    readOnlyChoice(L("can read"))
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.fileURL.path))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.fileURL.lastPathComponent)
                    .font(.headline)
                Text(SharePreviewItem.subtitle(for: model.markdown))
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

    private func readOnlyChoice(_ title: String) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) {
                Task { if await model.stopSharing() { dismiss() } }
            } label: {
                Text(L("Stop Sharing"))
                    .foregroundStyle(.red)
            }
            .disabled(model.activity != .idle)

            Button(L("Copy Link")) {
                Task { await model.copyLink() }
            }
            .disabled(model.activity != .idle)

            Spacer()

            Button(L("Done"), action: dismiss)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }
}
