//
//  FileURLHelpers.swift
//  md-preview
//

import Foundation

extension URL {
    nonisolated var isExistingDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated func isDescendantOrSame(of other: URL) -> Bool {
        let mine = standardizedFileURL.path
        let root = other.standardizedFileURL.path
        // "/" already ends in the separator the prefix needs.
        return mine == root || mine.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
