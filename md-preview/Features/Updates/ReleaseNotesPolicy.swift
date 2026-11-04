//
//  ReleaseNotesPolicy.swift
//  md-preview
//
//  Decides when the app says it was updated. The app remembers the last
//  build and version that showed a document window; a reader coming from an
//  older build is told once, and the version they came from bounds the
//  release notes they are offered.
//

import Foundation

enum ReleaseNotesPolicy {
    /// Named for the What's New window that used it before; kept so readers
    /// of those releases are still recognised as updating.
    static let lastBuildKey = "MarkdownPreview.whatsNewLastBuild"
    static let lastVersionKey = "MarkdownPreview.lastVersion"

    /// Records this build and version, and returns the version the reader
    /// updated from when this launch follows an update — empty when that
    /// version is unknown (it predates `lastVersionKey`) — or nil.
    static func claimUpdate(defaults: UserDefaults = .standard,
                            thisBuild: Int,
                            thisVersion: String,
                            hasUsedAppBefore: Bool) -> String? {
        let previousVersion = defaults.string(forKey: lastVersionKey) ?? ""
        let updated = claimPresentation(defaults: defaults, thisBuild: thisBuild,
                                        hasUsedAppBefore: hasUsedAppBefore)
        // Never lowered, like the build.
        if previousVersion.compare(thisVersion, options: .numeric) != .orderedDescending {
            defaults.set(thisVersion, forKey: lastVersionKey)
        }
        return updated ? previousVersion : nil
    }

    /// Records this build and returns whether to open the release notes.
    /// Recording happens before they open, so a crash or a window closed
    /// before they show never opens them a second time.
    ///
    /// `hasUsedAppBefore` covers readers from builds that predate
    /// `lastBuildKey`: they have used the app, just not recorded a build.
    /// A reader with neither is a fresh install, with nothing to catch up on.
    static func claimPresentation(defaults: UserDefaults = .standard,
                                  thisBuild: Int,
                                  hasUsedAppBefore: Bool) -> Bool {
        let stored = defaults.object(forKey: lastBuildKey) as? Int
        let lastBuild = stored ?? (hasUsedAppBefore ? 0 : nil)
        // Never lowered, so an older build run after a newer one keeps quiet.
        let recorded = max(lastBuild ?? 0, thisBuild)
        if stored != recorded {
            defaults.set(recorded, forKey: lastBuildKey)
        }
        guard let lastBuild else { return false }
        return lastBuild < thisBuild
    }
}
