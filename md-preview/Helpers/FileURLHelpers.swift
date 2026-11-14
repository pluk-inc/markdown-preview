//
//  FileURLHelpers.swift
//  md-preview
//

import Foundation

extension URL {
    /// The reader's home folder. The sandbox remaps `NSHomeDirectory()` to
    /// the app's container, so ask the user database.
    nonisolated static let realHomeDirectory: URL = {
        if let directory = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }()

    nonisolated var isExistingDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated func isDescendantOrSame(of other: URL) -> Bool {
        let mine = standardizedFileURL.path
        let root = other.standardizedFileURL.path
        return mine == root || mine.hasPrefix(root + "/")
    }
}
