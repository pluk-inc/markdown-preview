//
//  AutoSaveSetting.swift
//  md-preview
//

import Foundation

/// Shared interval used by the editor's periodic save timer and Settings.
enum AutoSaveSetting {
    static let defaultsKey = "MarkdownPreview.autoSaveIntervalMinutes"
    static let defaultMinutes = 5
    static let minimumMinutes = 1
    static let maximumMinutes = 60

    static var currentMinutes: Int {
        currentMinutes(from: .standard)
    }

    static func currentMinutes(from defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: defaultsKey) as? NSNumber else {
            return defaultMinutes
        }
        return clampedMinutes(stored.intValue)
    }

    static func store(minutes: Int, in defaults: UserDefaults = .standard) {
        defaults.set(clampedMinutes(minutes), forKey: defaultsKey)
    }

    static func clampedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, minimumMinutes), maximumMinutes)
    }

    static var interval: TimeInterval {
        TimeInterval(currentMinutes * 60)
    }
}
