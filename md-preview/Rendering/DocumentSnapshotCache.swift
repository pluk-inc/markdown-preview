import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Saves an image of a document's first screen after it paints, and shows
/// that image when the same file opens again, until WebKit paints the page.
/// Only documents whose first paint is also their final look are saved:
/// math, Mermaid and script-highlighted code change after the first paint,
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
        let files = Self.files(for: fileURL)
        DispatchQueue.global(qos: .userInteractive).async {
            defer { prefetch.done.signal() }
            guard let json = try? Data(contentsOf: files.metadata),
                  let metadata = try? JSONDecoder().decode(Metadata.self, from: json),
                  metadata.contentHash == prefetch.contentHash,
                  let source = CGImageSourceCreateWithURL(files.image as CFURL, nil),
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
        let files = Self.files(for: fileURL)
        DispatchQueue.global(qos: .utility).async {
            guard let json = try? JSONEncoder().encode(metadata) else { return }
            try? FileManager.default.createDirectory(at: files.image.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(
                files.image as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return }
            try? json.write(to: files.metadata, options: .atomic)
            Self.removeOldSnapshots(in: files.image.deletingLastPathComponent())
        }
    }

    private nonisolated static func removeOldSnapshots(in folder: URL) {
        let manager = FileManager.default
        guard let images = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter({ $0.pathExtension == "png" }), images.count > maximumSnapshots else { return }
        let oldestFirst = images.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for image in oldestFirst.prefix(images.count - maximumSnapshots) {
            try? manager.removeItem(at: image)
            try? manager.removeItem(at: image.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    nonisolated static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// One image per file path; a new version of the file replaces it.
    private nonisolated static func files(for fileURL: URL) -> (image: URL, metadata: URL) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = hash(fileURL.standardizedFileURL.path)
        let folder = caches.appendingPathComponent("DocumentSnapshots", isDirectory: true)
        return (folder.appendingPathComponent("\(name).png"),
                folder.appendingPathComponent("\(name).json"))
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
