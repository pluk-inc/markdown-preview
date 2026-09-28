//
//  WhatsNewPolicy.swift
//  md-preview
//
//  Decides when the What's New window appears. The app remembers the last
//  build that showed a document window; a reader coming from a build older
//  than `featuresBuild` sees the window once. To announce new features, set
//  `featuresVersion` and `featuresBuild` to the release that ships them
//  (`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Version.xcconfig)
//  and replace the features in `WhatsNewFeature.current`.
//

import Foundation

enum WhatsNewPolicy {
    /// The release that introduced `WhatsNewFeature.current`.
    static let featuresVersion = "0.0.62"
    static let featuresBuild = 66

    static let lastBuildKey = "MarkdownPreview.whatsNewLastBuild"

    /// A reader with no `lastBuild` is a fresh install: every feature is new
    /// to them, so there is nothing to announce.
    static func shouldPresent(lastBuild: Int?, featuresBuild: Int = featuresBuild) -> Bool {
        guard let lastBuild else { return false }
        return lastBuild < featuresBuild
    }

    /// Records this build and returns whether to show the window. Recording
    /// happens before the window appears, so a crash or a window closed
    /// before it shows never shows it a second time.
    ///
    /// `hasUsedAppBefore` covers readers from builds that predate
    /// `lastBuildKey`: they have used the app, just not recorded a build.
    static func claimPresentation(defaults: UserDefaults = .standard,
                                  thisBuild: Int,
                                  hasUsedAppBefore: Bool) -> Bool {
        let stored = defaults.object(forKey: lastBuildKey) as? Int
        let lastBuild = stored ?? (hasUsedAppBefore ? 0 : nil)
        let present = shouldPresent(lastBuild: lastBuild)
        // Never lowered, so an older build run after a newer one keeps quiet;
        // and at least `featuresBuild` once shown, so a development build
        // numbered below it does not show the window on every launch.
        let recorded = max(lastBuild ?? 0, thisBuild, present ? featuresBuild : 0)
        if stored != recorded {
            defaults.set(recorded, forKey: lastBuildKey)
        }
        return present
    }
}
