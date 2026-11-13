//
//  FavoriteFolders.swift
//  md-preview
//

import AppKit

/// Folders the reader added to the favorites of the Project Navigator. A
/// file inside a favorite opens with that folder as the navigator root,
/// instead of the file's own folder, so the reader sees the whole folder
/// every time.
///
/// Reading needs no grant (the sandbox allows read-only access to the
/// whole file system), so plain paths are enough here.
@MainActor
enum FavoriteFolders {
    static let didChangeNotification = Notification.Name("FavoriteFolders.didChange")
    private static let defaultsKey = "ProjectNavigator.PinnedFolders"

    static var all: [URL] { storedFolders(forKey: defaultsKey) }

    static func contains(_ folder: URL) -> Bool {
        all.contains(folder.standardizedFileURL)
    }

    /// Adds `folder`, or removes it when it is a favorite already.
    static func toggle(_ folder: URL) {
        let folder = folder.standardizedFileURL
        var folders = all
        if let index = folders.firstIndex(of: folder) {
            folders.remove(at: index)
        } else {
            folders.append(folder)
        }
        UserDefaults.standard.set(folders.map(\.path), forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// The outermost favorite that contains `fileURL`. The outer one wins:
    /// a reader who adds a folder above an earlier favorite wants the
    /// larger view.
    static func root(containing fileURL: URL, among favorites: [URL]? = nil) -> URL? {
        let file = fileURL.standardizedFileURL
        return (favorites ?? all)
            .filter { file.isDescendantOrSame(of: $0) && $0.isExistingDirectory }
            .min { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// The root for a file inside a favorite: `current` when the navigator
    /// already shows that favorite or a folder above it, else the favorite.
    /// Nil when no favorite contains the file.
    static func root(for fileURL: URL, keeping current: URL?) -> URL? {
        guard let favorite = root(containing: fileURL) else { return nil }
        if let current, favorite.isDescendantOrSame(of: current) { return current }
        return favorite
    }
}

/// The folders the Project Navigator showed last, newest first, for the
/// Recent part of the folder menu.
@MainActor
enum RecentFolders {
    private static let defaultsKey = "ProjectNavigator.RecentFolders"
    private static let storedLimit = 8
    private static let menuLimit = 5

    static func record(_ folder: URL) {
        let folder = folder.standardizedFileURL
        let folders = [folder] + storedFolders(forKey: defaultsKey).filter { $0 != folder }
        UserDefaults.standard.set(folders.prefix(storedLimit).map(\.path), forKey: defaultsKey)
    }

    /// What the menu lists: `root` first, then the recorded folders, then
    /// the folders of File > Open Recent, so the list is not empty before
    /// the navigator has shown anything. Favorites have their own section.
    static func menuFolders(root: URL, favorites: [URL]) -> [URL] {
        let documentFolders = NSDocumentController.shared.recentDocumentURLs.map {
            FavoriteFolders.root(containing: $0, among: favorites)
                ?? $0.deletingLastPathComponent().standardizedFileURL
        }
        var seen = Set(favorites)
        return Array(([root] + storedFolders(forKey: defaultsKey) + documentFolders)
            .filter { seen.insert($0).inserted && $0.isExistingDirectory }
            .prefix(menuLimit))
    }
}

@MainActor
private func storedFolders(forKey key: String) -> [URL] {
    (UserDefaults.standard.stringArray(forKey: key) ?? [])
        .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
}
