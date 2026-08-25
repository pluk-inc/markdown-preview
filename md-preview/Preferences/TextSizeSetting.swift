//
//  TextSizeSetting.swift
//  md-preview
//
//  Preferred size for rendered Markdown.
//
//  This is not a separate preference from zoom — it is the *same* stored page
//  zoom that ⌘+ / ⌘− , pinch, and the toolbar's A/A buttons write. Giving
//  Settings its own font-size value would mean two knobs fighting over one
//  rendered size; instead Settings offers three named stops on the scale the
//  document window already uses, and reads back whatever the window last set.
//
//  Base *typography* (`MarkdownHTML.bodyFontSize`) is deliberately left alone:
//  its derived spacing tokens are shared with the CodeMirror editor bundle, so
//  scaling there would change editor layout too.
//

import CoreGraphics
import Foundation

enum TextSizeSetting: CaseIterable {
    case small
    case medium
    case large

    /// Shared with `ContentViewController`, which seeds each web view from it.
    static let defaultsKey = "MarkdownPreview.pageZoom"

    /// Page zoom each stop maps to. All three are exact members of
    /// `MarkdownWebView.zoomSteps`, so stepping with ⌘+ / ⌘− lands back on a
    /// named stop rather than between two of them.
    var zoom: CGFloat {
        switch self {
        case .small: return 0.9
        case .medium: return 1.0
        case .large: return 1.25
        }
    }

    /// Relative size for the "Aa" sample shown in the Settings picker.
    var sampleFontSize: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 12
        case .large: return 15
        }
    }

    var title: String {
        switch self {
        case .small: return NSLocalizedString("Small", comment: "Text size")
        case .medium: return NSLocalizedString("Medium", comment: "Text size")
        case .large: return NSLocalizedString("Large", comment: "Text size")
        }
    }

    /// Stored zoom, or 1.0 when the key is absent — `persistPageZoom` removes
    /// it at the default rather than writing 1.0.
    static var currentZoom: CGFloat {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? NSNumber else {
            return 1.0
        }
        return CGFloat(truncating: stored)
    }

    /// The stop matching the stored zoom, or `nil` when the reader has zoomed
    /// to a size that isn't one of them. Settings shows no selection in that
    /// case rather than claiming a stop the document isn't actually at.
    static var current: TextSizeSetting? {
        let zoom = currentZoom
        return allCases.first { abs($0.zoom - zoom) <= 0.001 }
    }

    static func store(_ setting: TextSizeSetting) {
        if setting == .medium {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else {
            UserDefaults.standard.set(Double(setting.zoom), forKey: defaultsKey)
        }
    }
}
