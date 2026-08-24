//
//  AutoSaveSetting.swift
//  md-preview
//

import Foundation

/// Shared interval used by the editor's periodic save timer and Settings.
enum AutoSaveSetting {
    static let defaultsKey = "MarkdownPreview.autoSaveIntervalMinutes"
    // Keep the existing minute-based preference key compatible without
    // confusing the new 30-second choice with a stored minute count.
    static let thirtySeconds = -30
    static let disabledMinutes = 0
    static let minimumMinutes = 1
    static let maximumMinutes = 60

    static var currentMinutes: Int {
        currentMinutes(from: .standard)
    }

    static func currentMinutes(from defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: defaultsKey) as? NSNumber else {
            return disabledMinutes
        }
        return clampedMinutes(stored.intValue)
    }

    static func store(minutes: Int, in defaults: UserDefaults = .standard) {
        defaults.set(clampedMinutes(minutes), forKey: defaultsKey)
    }

    static func clampedMinutes(_ minutes: Int) -> Int {
        if minutes == thirtySeconds { return thirtySeconds }
        guard minutes != disabledMinutes else { return disabledMinutes }
        return min(max(minutes, minimumMinutes), maximumMinutes)
    }

    static var interval: TimeInterval? {
        interval(for: currentMinutes)
    }

    static func interval(for minutes: Int) -> TimeInterval? {
        switch minutes {
        case disabledMinutes:
            return nil
        case thirtySeconds:
            return 30
        default:
            return TimeInterval(minutes * 60)
        }
    }
}
