//
//  FileURLHelpers.swift
//  md-preview
//

import Foundation

extension URL {
    var isExistingDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func isDescendantOrSame(of other: URL) -> Bool {
        let mine = standardizedFileURL.path
        let root = other.standardizedFileURL.path
        return mine == root || mine.hasPrefix(root + "/")
    }
}
