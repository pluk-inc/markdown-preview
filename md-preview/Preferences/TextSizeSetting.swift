//
//  TextSizeSetting.swift
//  md-preview
//
//  Preferred size for rendered Markdown.
//
//  This is not a separate preference from zoom — it is the *same* stored page
//  zoom that ⌘+ / ⌘− , pinch, and the toolbar's A/A buttons write. Settings
//  offers a stepper that moves through the same discrete zoom stops the rest
//  of the app uses, so the stored value always lands on a valid stop.
//
//  Base *typography* (`MarkdownHTML.bodyFontSize`) is deliberately left alone:
//  its derived spacing tokens are shared with the CodeMirror editor bundle, so
//  scaling there would change editor layout too.
//

import CoreGraphics
import Foundation

/// A precise text size setting that maps to the discrete zoom steps used
/// throughout the app (keyboard shortcuts, pinch, toolbar). The stepper in
/// Settings moves one stop at a time, so the stored value is always a member
/// of `ZoomSteps.values`.
struct TextSizeSetting: Equatable {
    /// Shared with `ContentViewController`, which seeds each web view from it.
    static let defaultsKey = "MarkdownPreview.pageZoom"

    /// The discrete zoom stops. Owned by `ZoomSteps` so Settings, shortcuts,
    /// pinch and the toolbar can never offer different stops.
    static var zoomSteps: [CGFloat] { ZoomSteps.values }

    /// The current zoom level, guaranteed to be a member of `zoomSteps`.
    let zoom: CGFloat

    /// Creates a setting from a zoom value, snapping to the nearest stop.
    init(zoom: CGFloat) {
        self.zoom = Self.snapToStep(zoom)
    }

    /// Creates a setting at a specific step index.
    init(stepIndex: Int) {
        let clamped = max(0, min(Self.zoomSteps.count - 1, stepIndex))
        self.zoom = Self.zoomSteps[clamped]
    }

    /// The step index of the current zoom level.
    var stepIndex: Int {
        ZoomSteps.index(for: zoom)
    }

    /// Snaps a zoom value to the nearest discrete step.
    private static func snapToStep(_ zoom: CGFloat) -> CGFloat {
        ZoomSteps.snap(zoom)
    }

    /// The next larger step, or the current one if already at maximum.
    func steppedUp() -> TextSizeSetting {
        TextSizeSetting(stepIndex: stepIndex + 1)
    }

    /// The next smaller step, or the current one if already at minimum.
    func steppedDown() -> TextSizeSetting {
        TextSizeSetting(stepIndex: stepIndex - 1)
    }

    /// Whether a larger step is available.
    var canStepUp: Bool { stepIndex < Self.zoomSteps.count - 1 }

    /// Whether a smaller step is available.
    var canStepDown: Bool { stepIndex > 0 }

    /// Human-readable label for the current size (e.g. "100%", "125%").
    var displayString: String {
        let percent = Int(round(zoom * 100))
        return "\(percent)%"
    }

    /// Stored zoom, or 1.0 when the key is absent — `persistPageZoom` removes
    /// it at the default rather than writing 1.0.
    static var currentZoom: CGFloat {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber else {
            return 1.0
        }
        return CGFloat(truncating: stored)
    }

    /// The setting matching the stored zoom, snapped to the nearest stop.
    static var current: TextSizeSetting {
        TextSizeSetting(zoom: currentZoom)
    }

    /// Stores the zoom level. Removes the key at the default (1.0) to match
    /// the existing behaviour of `persistPageZoom`.
    static func store(_ setting: TextSizeSetting) {
        if abs(setting.zoom - 1.0) <= 0.001 {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(Double(setting.zoom), forKey: defaultsKey)
        }
    }

    /// The default setting (100%).
    static let `default` = TextSizeSetting(zoom: 1.0)
}