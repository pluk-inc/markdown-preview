import Foundation

/// Decisions the file watcher makes after its file is deleted, renamed or
/// replaced. Kept free of file-system calls so tests can cover them.
enum FileWatcherMoveResolution {
    /// The new location to follow when the watched file was renamed, or nil
    /// when the watcher should keep the original path. Editors commonly move
    /// the old inode aside before creating the new file at the original
    /// path, so a file at the original path wins once the save settles.
    static func renameTarget(
        originalURL: URL,
        movedURL: URL?,
        fileExists: (URL) -> Bool
    ) -> URL? {
        guard !fileExists(originalURL),
              let movedURL,
              movedURL.standardizedFileURL != originalURL.standardizedFileURL,
              fileExists(movedURL) else { return nil }
        return movedURL
    }

    /// Wait before the next try to open a path that has no file. Starts
    /// short, because a save that replaces the file usually writes it
    /// again within milliseconds, then backs off to one try per second.
    static func reopenDelay(attempt: Int) -> TimeInterval {
        min(0.05 * pow(2, Double(attempt)), 1.0)
    }
}
