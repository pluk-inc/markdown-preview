import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Saves an image of a document's first screen after it paints, and shows
/// that image when the same file opens again, until WebKit paints the page.
/// Only documents whose first paint is also their final look are saved:
/// math, Mermaid and script-highlighted code change after the first paint,
/// and images can load late or change on disk without the Markdown changing,
/// so an image of them would not match the page it covers.
@MainActor
final class DocumentSnapshotCache {
    static let shared = DocumentSnapshotCache()

    /// Launch argument / default that turns snapshots off, for A/B timing.
    private static let disabledDefaultsKey = "MarkdownPreview.disableDocumentSnapshots"
    /// Longest wait for a decode that is still running when the window is
    /// about to show. The decode starts before the window is built.
    private static let decodeWait: DispatchTimeInterval = .milliseconds(30)
    /// Saved images show document content, so keep only recent ones.
    private nonisolated static let maximumSnapshots = 40
    /// One writer at a time, so pruning and replacing never interleave.
    private nonisolated static let writeQueue = DispatchQueue(label: "doc.md-preview.snapshots", qos: .utility)

    /// Everything the saved image depends on.
    nonisolated struct Metadata: Codable, Equatable, Sendable {
        let contentHash: String
        let pixelWidth: Int
        let pixelHeight: Int
        let isDark: Bool
        let settings: String
        let zoom: Double
        /// The page starts this far below the web view's top (the toolbar
        /// strip on macOS 26), while the saved image starts at the page top.
        let topInset: Double
    }

    /// A background read and decode, started as soon as the document text is
    /// known.
    final class Prefetch: @unchecked Sendable {
        let contentHash: String
        fileprivate let done = DispatchSemaphore(value: 0)
        fileprivate var image: CGImage?
        fileprivate var metadata: Metadata?

        fileprivate init(contentHash: String) {
            self.contentHash = contentHash
        }
    }

    private var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: Self.disabledDefaultsKey)
    }

    func prefetch(fileURL: URL?, markdown: String) -> Prefetch? {
        guard isEnabled, let fileURL else { return nil }
        let prefetch = Prefetch(contentHash: Self.hash(markdown))
        let file = Self.file(for: fileURL)
        DispatchQueue.global(qos: .userInteractive).async {
            defer { prefetch.done.signal() }
            // The metadata travels inside the PNG, so an image is never read
            // with another version's metadata.
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
                  let json = (png[kCGImagePropertyPNGDescription] as? String)?.data(using: .utf8),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: json),
                  metadata.contentHash == prefetch.contentHash,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [
                      kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return }
            prefetch.metadata = metadata
            prefetch.image = image
        }
        return prefetch
    }

    /// The decoded image, when it matches what the page will look like now.
    func image(for prefetch: Prefetch, expected: Metadata) -> CGImage? {
        guard prefetch.done.wait(timeout: .now() + Self.decodeWait) == .success else { return nil }
        // Leave the semaphore signalled for any later call.
        prefetch.done.signal()
        guard prefetch.metadata == expected else { return nil }
        return prefetch.image
    }

    func store(_ image: CGImage, fileURL: URL, metadata: Metadata) {
        guard isEnabled,
              image.width == metadata.pixelWidth,
              image.height == metadata.pixelHeight else { return }
        let file = Self.file(for: fileURL)
        Self.writeQueue.async {
            guard let json = try? JSONEncoder().encode(metadata) else { return }
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Write beside the target, then rename over it, so a reader sees
            // either the old file or the new one, never a partial write.
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).png")
            guard let destination = CGImageDestinationCreateWithURL(
                temporary as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return }
            let properties = [kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: String(decoding: json, as: UTF8.self),
            ]] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination),
                  rename(temporary.path, file.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            Self.removeOldSnapshots(in: folder)
        }
    }

    private nonisolated static func removeOldSnapshots(in folder: URL) {
        let manager = FileManager.default
        guard let images = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.pathExtension == "png" && !$0.lastPathComponent.hasPrefix(".") }),
              images.count > maximumSnapshots else { return }
        let oldestFirst = images.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for image in oldestFirst.prefix(images.count - maximumSnapshots) {
            try? manager.removeItem(at: image)
        }
    }

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One image per file path; a new version of the file replaces it.
    private nonisolated static func file(for fileURL: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = hash(fileURL.standardizedFileURL.path)
        return caches.appendingPathComponent("DocumentSnapshots", isDirectory: true)
            .appendingPathComponent("\(name).png")
    }
}

/// Shows a saved snapshot over the reader and lets every event pass through
/// to the web view underneath.
final class DocumentSnapshotOverlayView: NSView {
    /// `frame` is the part of the web view below its top inset. The image
    /// keeps its pixel size from the top edge, and the rest is clipped.
    init(image: CGImage, frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsScale = scale
        layer?.contentsGravity = .top
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
