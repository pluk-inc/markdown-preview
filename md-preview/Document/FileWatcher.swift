//
//  FileWatcher.swift
//  md-preview
//
//  Watches an open document's file for changes, renames, and deletion.
//

import Cocoa

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
    private var fileDescriptor: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var moveResolution: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        open()
    }

    private func open() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

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
                self.resolveMove(afterSettlingAt: self.currentPath())
                return
            }
            self.scheduleChange()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                Darwin.close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        self.source = source
        source.resume()
    }

    private func resolveMove(afterSettlingAt movedURL: URL?) {
        moveResolution?.cancel()
        debounce?.cancel()
        source?.cancel()
        source = nil

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.moveResolution = nil
            let resolution = FileWatcherMoveResolution.resolve(
                originalURL: self.url,
                movedURL: movedURL,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) }
            )
            switch resolution {
            case .reloadOriginal:
                self.open()
                self.scheduleChange()
            case .followRename(let newURL):
                self.onRename?(newURL)
            case .unavailable:
                self.reopen()
            }
        }
        moveResolution = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.moveResolutionDelay,
            execute: work
        )
    }

    private func reopen() {
        source?.cancel()
        source = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.open()
        }
    }

    private func currentPath() -> URL? {
        guard fileDescriptor >= 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fileDescriptor, F_GETPATH, &buffer) == 0 else { return nil }
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
        moveResolution?.cancel()
        source?.cancel()
        source = nil
    }
}
