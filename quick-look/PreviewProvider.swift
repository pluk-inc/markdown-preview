//
//  PreviewProvider.swift
//  quick-look
//
//  Created by Fauzaan on 4/28/26.
//

import Cocoa
import Quartz
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
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
