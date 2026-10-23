//
//  SharePreviewItem.swift
//  md-preview
//
//  The share popover's header: the document's Finder icon (the app icon for
//  an untitled document), the file name, and a gray "N words · size"
//  subtitle in place of the first lines of the raw Markdown.
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
    /// `fileURL` gives the header the document's own Finder icon, the same
    /// image the manage-sharing sheet shows.
    static func make(markdown: String, title: String, fileURL: URL?) -> NSPreviewRepresentingActivityItem {
        // The page covers about 1/1.3 of a document icon's height; drawn
        // larger it fills the tile instead of floating in white.
        let image = fileURL.map(documentIcon) ?? headerIcon
        let preview = NSPreviewRepresentingActivityItem(
            item: markdown, title: title, image: image, icon: nil)
        guard supportsSubtitle else { return preview }
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.setValue(subtitle(for: markdown), forKey: "summary")
        metadata.imageProvider = NSItemProvider(object: image)
        preview.setValue(metadata, forKey: "linkMetadata")
        return preview
    }

    /// The toolbar asks for its items while it is built, so the last icon is
    /// kept rather than looked up and redrawn on every call.
    private static var cachedDocumentIcon: (path: String, image: NSImage)?

    private static func documentIcon(for fileURL: URL) -> NSImage {
        if let cached = cachedDocumentIcon, cached.path == fileURL.path { return cached.image }
        let image = filling(NSWorkspace.shared.icon(forFile: fileURL.path), scale: 1.3)
        cachedDocumentIcon = (fileURL.path, image)
        return image
    }

    private static let supportsSubtitle =
        LPLinkMetadata.instancesRespond(to: NSSelectorFromString("setSummary:"))
            && class_getInstanceVariable(NSPreviewRepresentingActivityItem.self, "_linkMetadata") != nil

    /// The size of the text being shared, which matches the file on disk
    /// unless there are unsaved edits. Also the manage-sharing sheet's
    /// subtitle, so both read the same.
    static func subtitle(for markdown: String) -> String {
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
    // The icon body covers 824 of the 1024-point canvas.
    private static let headerIcon = filling(NSApp.applicationIconImage, scale: 1024 / 824)

    /// `source` drawn `scale` times larger on the same 128-point canvas,
    /// cropping its transparent margin.
    private static func filling(_ source: NSImage, scale factor: CGFloat) -> NSImage {
        let side: CGFloat = 128
        let pad = side * (factor - 1) / 2
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
            source.draw(in: rect.insetBy(dx: -pad, dy: -pad))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        return image
    }
}
