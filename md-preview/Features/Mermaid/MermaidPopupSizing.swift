//
//  MermaidPopupSizing.swift
//  md-preview
//
//  Pure sizing math for Mermaid diagram popup windows. Kept free of AppKit so
//  the SPM helper tests can exercise it without a GUI host.
//

import CoreGraphics
import Foundation

enum MermaidPopupSizing {
    /// Stable 16:9 client size for the popup. The diagram is deliberately not
    /// used to choose the initial window geometry.
    static let initialContentSize = CGSize(width: 1440, height: 810)
    static let minimumWidth: CGFloat = 640
    static let minimumHeight: CGFloat = 360
    /// Fraction of the screen's visible frame the popup may occupy.
    static let screenFraction: CGFloat = 0.9

    /// Chooses a stable popup content size independent of diagram aspect ratio.
    ///
    /// The viewport, rather than the SVG, determines the initial window geometry.
    static func preferredContentSize(screen: CGSize) -> CGSize {
        let maxW = max(screen.width * screenFraction, 1)
        let maxH = max(screen.height * screenFraction, 1)
        let fit = min(maxW / initialContentSize.width, maxH / initialContentSize.height)
        let width = initialContentSize.width * fit
        let height = initialContentSize.height * fit
        return CGSize(width: width.rounded(.up), height: height.rounded(.up))
    }


    // MARK: - Popup content helpers (shared with MermaidDiagramPopup)

    /// Whether the host should attempt to open a popup for this SVG payload.
    static func canPresent(svgHTML: String) -> Bool {
        !svgHTML.isEmpty
    }

    /// Neutralize script tags in SVG markup before loading into the popup
    /// web view. Mermaid SVGs are static; this is defense-in-depth only.
    static func sanitizedSVGHTML(_ svgHTML: String) -> String {
        svgHTML
            .replacingOccurrences(of: "<script", with: "&lt;script", options: .caseInsensitive)
            .replacingOccurrences(of: "</script", with: "&lt;/script", options: .caseInsensitive)
    }
}
