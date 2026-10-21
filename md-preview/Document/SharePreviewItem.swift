//
//  SharePreviewItem.swift
//  md-preview
//
//  The share popover's header: the app icon, the file name, and a gray
//  "N words · size" subtitle in place of the first lines of the raw Markdown.
//

import AppKit
import LinkPresentation
import ObjectiveC

/// The public `NSPreviewRepresentingActivityItem` has a title and an image but
/// no subtitle. The picker draws one from the private `LPLinkMetadata.summary`
/// when the item carries link metadata in its private `_linkMetadata` ivar —
/// the metadata the Tips app hands its SwiftUI share preview. Observed on
/// macOS 26 and 27. When either private piece is missing, the item keeps its
/// public title-only header.
@MainActor
enum SharePreviewItem {
    static func make(markdown: String, title: String) -> NSPreviewRepresentingActivityItem {
        let preview = NSPreviewRepresentingActivityItem(
            item: markdown, title: title, image: headerIcon, icon: nil)
        guard supportsSubtitle else { return preview }
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.setValue(subtitle(for: markdown), forKey: "summary")
        metadata.imageProvider = NSItemProvider(object: headerIcon)
        preview.setValue(metadata, forKey: "linkMetadata")
        return preview
    }

    private static let supportsSubtitle =
        LPLinkMetadata.instancesRespond(to: NSSelectorFromString("setSummary:"))
            && class_getInstanceVariable(NSPreviewRepresentingActivityItem.self, "_linkMetadata") != nil

    /// The size of the text being shared, which matches the file on disk
    /// unless there are unsaved edits.
    private static func subtitle(for markdown: String) -> String {
        // English singular/plural forms live in Localizable.stringsdict.
        let words = String.localizedStringWithFormat(
            NSLocalizedString("%ld words", comment: "Share popover word count"),
            DocumentMetadata.wordCount(of: markdown))
        let size = Int64(markdown.utf8.count).formatted(.byteCount(style: .file))
        return "\(words) · \(size)"
    }

    /// The app icon without the transparent margin of the macOS icon grid, so
    /// it fills the header tile the way a site icon does in Safari. Rendered
    /// once into a bitmap so later draws don't rescale the full-size icon.
    private static let headerIcon: NSImage = {
        let side: CGFloat = 128
        // The icon body covers 824 of the 1024-point canvas.
        let pad = side * (1024 / 824 - 1) / 2
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        let image = NSImage(size: rect.size)
        for scale in [1, 2] as [CGFloat] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(side * scale), pixelsHigh: Int(side * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = rect.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSApp.applicationIconImage.draw(in: rect.insetBy(dx: -pad, dy: -pad))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }()
}
