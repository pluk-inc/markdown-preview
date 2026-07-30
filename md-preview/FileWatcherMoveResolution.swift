import Foundation

enum FileWatcherMoveResolution: Equatable {
    case reloadOriginal
    case followRename(URL)
    case unavailable

    static func resolve(
        originalURL: URL,
        movedURL: URL?,
        fileExists: (URL) -> Bool
    ) -> FileWatcherMoveResolution {
        // Editors commonly move the old inode aside before creating the new
        // file at the original path. Prefer that path once the save settles.
        if fileExists(originalURL) {
            return .reloadOriginal
        }

        if let movedURL,
           movedURL.standardizedFileURL != originalURL.standardizedFileURL,
           fileExists(movedURL) {
            return .followRename(movedURL)
        }

        return .unavailable
    }
}
