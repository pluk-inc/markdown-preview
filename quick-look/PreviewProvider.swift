//
//  PreviewProvider.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import os
import Quartz
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    #if DEBUG
    // Debug-only perf instrumentation so `log stream --level debug
    // --predicate 'subsystem BEGINSWITH "doc.md-preview"'` shows Quick Look
    // render wall-time alongside the app's `[mdp-perf]` entries.
    private static let perf = Logger(subsystem: "doc.md-preview.quicklook", category: "perf")
    #endif

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        #if DEBUG
        // Default log level (not .debug): Quick Look appex processes are
        // short-lived, and their debug-level messages don't reliably reach a
        // running `log stream` — default-level entries are always persisted.
        let t0 = DispatchTime.now()
        Self.perf.log(
            "[mdp-perf-ql] provide start \(request.fileURL.lastPathComponent, privacy: .public)"
        )
        #endif
        let text = try String(contentsOf: request.fileURL, encoding: .utf8)
        let renderedHTML = MarkdownHTML.makeHTML(from: text, allowsScroll: true)
        let baseDirectory = request.fileURL.deletingLastPathComponent()
        let rewrite = InlineLocalAssets.rewriteRelativeImages(
            html: renderedHTML,
            baseDirectory: baseDirectory,
            reader: { try Data(contentsOf: $0) }
        )

        let replyAttachments: [String: QLPreviewReplyAttachment] = rewrite.attachments
            .reduce(into: [:]) { acc, pair in
                let contentType = UTType(filenameExtension: pair.value.pathExtension)
                    ?? .data
                acc[pair.key] = QLPreviewReplyAttachment(
                    data: pair.value.data,
                    contentType: contentType
                )
            }

        #if DEBUG
        let elapsedMs = Int(
            (Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds)
             / 1_000_000).rounded()
        )
        Self.perf.log(
            "[mdp-perf-ql] provide finish +\(elapsedMs, privacy: .public)ms (\(text.count, privacy: .public) chars)"
        )
        #endif

        return QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: MarkdownHTML.preferredPageWidth,
                                height: MarkdownHTML.preferredPageWidth)
        ) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8
            replyToUpdate.attachments = replyAttachments
            return Data(rewrite.html.utf8)
        }
    }
}
