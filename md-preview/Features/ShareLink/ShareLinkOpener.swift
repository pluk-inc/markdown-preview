//
//  ShareLinkOpener.swift
//  md-preview
//
//  Opens a share link someone sent: fetches the envelope, decrypts it with
//  the key from the link, and unpacks the Markdown and its images into the
//  app's caches, where the document opens read-only.
//  docs/share-link-plan.md §4.5.
//

import AppKit
import WebKit

@MainActor
enum ShareLinkOpener {

    /// Where received shares are unpacked, one folder per share id.
    /// Standardized once: menu validation and every display ask about it.
    static let directory = URL.cachesDirectory
        .appending(path: "SharedLinks", directoryHint: .isDirectory)
        .standardizedFileURL

    /// True for a file unpacked from a received share. Such a copy is
    /// replaced whenever the link is opened again, so it must not be edited.
    static func isReceivedCopy(_ fileURL: URL?) -> Bool {
        isFile(fileURL, inside: directory)
    }

    /// True for a file unpacked from the share `id`.
    static func isReceivedCopy(_ fileURL: URL?, id: String) -> Bool {
        isFile(fileURL, inside: folder(for: id))
    }

    /// Blocks network loads in a received share's preview: a remote image
    /// would tell the sender's server who opened the link, and when. Link
    /// clicks (document loads) still work. Nil when WebKit cannot compile it;
    /// the share then stays unrendered rather than reach the network, and
    /// the next display tries again.
    static func remoteContentBlocker() async -> WKContentRuleList? {
        if let compiling = remoteContentBlockerTask { return await compiling.value }
        let task = Task { @MainActor () -> WKContentRuleList? in
            let rules = #"[{"trigger":{"url-filter":"^https?:","resource-type":["image","style-sheet","font","media","raw","svg-document"]},"action":{"type":"block"}}]"#
            // The store keeps compiled lists on disk, so later launches only
            // look the list up. Change the version when the rules change.
            let identifier = "ReceivedShareRemoteContent.v1"
            let store = WKContentRuleListStore.default()!
            if let stored = try? await store.contentRuleList(forIdentifier: identifier) { return stored }
            do {
                return try await store.compileContentRuleList(forIdentifier: identifier,
                                                              encodedContentRuleList: rules)
            } catch {
                NSLog("ShareLinkOpener: could not compile the remote content rules: \(error)")
                return nil
            }
        }
        remoteContentBlockerTask = task
        let blocker = await task.value
        if blocker == nil { remoteContentBlockerTask = nil }
        return blocker
    }

    private static var remoteContentBlockerTask: Task<WKContentRuleList?, Never>?

    /// Accepts both the web link and the md-preview://share form.
    static func parse(_ url: URL) -> ShareLink? {
        guard ShareLinkFeature.isEnabled else { return nil }
        return ShareLink.parse(url, webBase: ShareLinkFeature.baseURL)
    }

    /// The unpacked Markdown file for `link`, or nil after telling the user
    /// why the share cannot be opened (or when they cancelled the password).
    static func download(_ link: ShareLink) async -> URL? {
        guard let baseURL = ShareLinkFeature.baseURL else { return nil }
        do {
            let envelope = try await ShareLinkClient(baseURL: baseURL).fetch(id: link.id)
            guard link.hasPassword || ShareLinkCrypto.requiresPassword(envelope) else {
                return try await unpack(envelope, link: link, password: nil)
            }
            var retry = false
            while let password = askForPassword(retry: retry) {
                do {
                    return try await unpack(envelope, link: link, password: password)
                } catch ShareLinkCrypto.Failure.authenticationFailed {
                    retry = true
                }
            }
            return nil
        } catch {
            presentFailure(error)
            return nil
        }
    }

    // MARK: - Private

    private static func folder(for id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }

    private static func isFile(_ fileURL: URL?, inside folder: URL) -> Bool {
        fileURL?.isDescendantOrSame(of: folder) ?? false
    }

    /// Decrypts, decodes, and writes the share off the main thread: the
    /// plaintext can be 64 MB, and a password costs a PBKDF2 run.
    private static func unpack(_ envelope: Data, link: ShareLink, password: String?) async throws -> URL {
        let folder = folder(for: link.id)
        return try await Task.detached(priority: .userInitiated) {
            let plaintext = try ShareLinkCrypto.open(envelope, key: link.key, password: password)
            return try SharePayload.decode(plaintext).unpack(into: folder)
        }.value
    }

    private static func askForPassword(retry: Bool) -> String? {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let alert = fieldAlert(title: retry ? L("Incorrect Password") : L("Enter Password"),
                               message: L("The sender protected this shared document with a password."),
                               field: field)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private static func fieldAlert(title: String, message: String, field: NSTextField) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("Open"))
        alert.addButton(withTitle: L("Cancel"))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert
    }

    private static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("The shared document can’t be opened.")
        alert.informativeText = switch error {
        case ShareLinkClient.Failure.notFound:
            L("This link has expired, or sharing was stopped.")
        case is ShareLinkCrypto.Failure, is SharePayload.Failure, is DecodingError:
            L("This link is damaged, or it does not match the shared document.")
        case is CocoaError:
            error.localizedDescription
        default:
            ShareLinkSession.message(for: error)
        }
        alert.runModal()
    }
}
