//
//  FileWatcher.swift
//  md-preview
//
//  Watches an open document's file for changes, renames, and deletion.
//

import Foundation

@MainActor
final class FileWatcher {
    private static let moveResolutionDelay: TimeInterval = 0.20

    private let url: URL
    private let onChange: () -> Void
    /// Fired when the watched file is renamed or moved (in Finder, by an
    /// editor, etc.). Detected via `F_GETPATH` on the still-open FD —
    /// the inode follows the file, so the descriptor resolves to the
    /// new path. Plain deletes don't fire this (path unchanged).
    var onRename: ((URL) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    /// The pending move resolution or reopen retry. Only one is pending at
    /// a time, and `cancel()` stops it, so no descriptor opens after cancel.
    private var pendingWork: DispatchWorkItem?
    /// Failed tries to open the file since it went missing; back to 0 once
    /// it opens. Tests wait on it.
    private(set) var failedReopenCount = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        if !open() {
            reopenWhenAvailable(attempt: 0)
        }
    }

    /// Opens the path and arms one source on it. Returns false when the
    /// file is not there (yet).
    @discardableResult
    private func open() -> Bool {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let event = source.data
            // Atomic-rename saves (Vim, VS Code, etc.) replace the inode;
            // re-open the watcher against the path so we keep tracking.
            // For an actual user-visible rename, the FD's resolved path
            // differs from the watcher's URL — surface that to the host.
            if !event.intersection([.delete, .rename, .revoke]).isEmpty {
                self.resolveMove(afterSettlingAt: Self.currentPath(of: fd))
                return
            }
            self.scheduleChange()
        }
        // Close the descriptor this source was made with, never a shared
        // one: closing a newer descriptor here left this one open on the
        // old inode.
        source.setCancelHandler {
            Darwin.close(fd)
        }
        self.source = source
        source.resume()
        return true
    }

    private func resolveMove(afterSettlingAt movedURL: URL?) {
        debounce?.cancel()
        source?.cancel()
        source = nil

        schedulePending(after: Self.moveResolutionDelay) { [weak self] in
            guard let self else { return }
            if let newURL = FileWatcherMoveResolution.renameTarget(
                originalURL: self.url,
                movedURL: movedURL,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            ) {
                self.onRename?(newURL)
            } else {
                // A save that deletes the file and writes it again can
                // leave the path empty for a moment, or for as long as the
                // writer takes. Keep trying the original path.
                self.reopenWhenAvailable(attempt: 0)
            }
        }
    }

    /// Re-arms the watcher on the original path and reloads, or tries
    /// again later while the path has no file.
    private func reopenWhenAvailable(attempt: Int) {
        if open() {
            failedReopenCount = 0
            scheduleChange()
            return
        }
        failedReopenCount += 1
        schedulePending(after: FileWatcherMoveResolution.reopenDelay(attempt: attempt)) { [weak self] in
            self?.reopenWhenAvailable(attempt: attempt + 1)
        }
    }

    private func schedulePending(after delay: TimeInterval, _ body: @escaping () -> Void) {
        pendingWork?.cancel()
        let work = DispatchWorkItem(block: body)
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func currentPath(of fd: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return URL(fileURLWithFileSystemRepresentation: buffer,
                   isDirectory: false,
                   relativeTo: nil)
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func cancel() {
        debounce?.cancel()
        pendingWork?.cancel()
        source?.cancel()
        source = nil
    }
}
