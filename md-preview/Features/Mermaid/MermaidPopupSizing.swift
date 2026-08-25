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
    /// Padding around the diagram inside the popup content area.
    static let contentPadding: CGFloat = 40
    /// Soft minimum so tiny diagrams don't open a postage-stamp window.
    static let minimumWidth: CGFloat = 360
    static let minimumHeight: CGFloat = 260
    /// Fraction of the screen's visible frame the popup may occupy.
    static let screenFraction: CGFloat = 0.9
    /// Prefer not to upscale beyond this relative to the natural size.
    static let maxUpscale: CGFloat = 1.75

    /// Chooses a popup content size that shows the diagram clearly.
    ///
    /// - Parameters:
    ///   - natural: SVG viewBox / intrinsic size in CSS pixels (preferred).
    ///   - display: On-screen figure size used when natural size is unavailable.
    ///   - screen: Visible frame of the screen that will host the popup.
    /// - Returns: Content size for the popup's client area (not including
    ///   the window chrome). Aspect ratio of the diagram is preserved.
    static func preferredContentSize(
        natural: CGSize,
        display: CGSize,
        screen: CGSize
    ) -> CGSize {
        let maxW = max(screen.width * screenFraction, minimumWidth)
        let maxH = max(screen.height * screenFraction, minimumHeight)

        // Prefer the natural (uncapped) diagram size — this is what the
        // document max-height may have truncated. Treat width and height as
        // one pair: the on-screen figure can have a different aspect ratio
        // after CSS caps its height, so mixing one axis from each size would
        // corrupt the SVG's natural aspect ratio.
        let diagram = positiveSize(natural) ?? positiveSize(display)
            ?? CGSize(width: 400, height: 300)
        let diagramW = diagram.width
        let diagramH = diagram.height

        let aspect = diagramW / diagramH

        // Ideal: natural size + padding, optionally upscaled a bit for very
        // small diagrams so labels stay readable, but never beyond maxUpscale.
        let upscaleFloorW = minimumWidth - contentPadding
        let upscaleFloorH = minimumHeight - contentPadding
        var scale: CGFloat = 1
        if diagramW < upscaleFloorW || diagramH < upscaleFloorH {
            let up = min(upscaleFloorW / diagramW, upscaleFloorH / diagramH)
            scale = min(max(up, 1), maxUpscale)
        }

        var contentW = diagramW * scale + contentPadding
        var contentH = diagramH * scale + contentPadding

        // Fit within the screen budget, preserving aspect.
        if contentW > maxW || contentH > maxH {
            let fit = min(maxW / contentW, maxH / contentH)
            contentW *= fit
            contentH *= fit
        }

        // Enforce soft minimums while preserving aspect if screen allows.
        if contentW < minimumWidth, contentW < maxW {
            let target = min(minimumWidth, maxW)
            let grownH = target / (contentW / contentH)
            if grownH <= maxH {
                contentW = target
                contentH = grownH
            }
        }
        if contentH < minimumHeight, contentH < maxH {
            let target = min(minimumHeight, maxH)
            let grownW = target * (contentW / contentH)
            if grownW <= maxW {
                contentH = target
                contentW = grownW
            }
        }

        // Final clamp + keep aspect stable against float drift.
        contentW = min(max(contentW, 1), maxW)
        contentH = min(max(contentH, 1), maxH)
        // Re-sync aspect if clamp distorted it significantly.
        let clampedAspect = contentW / contentH
        if abs(clampedAspect - aspect) > 0.05 {
            if clampedAspect > aspect {
                contentW = contentH * aspect
            } else {
                contentH = contentW / aspect
            }
            contentW = min(max(contentW, 1), maxW)
            contentH = min(max(contentH, 1), maxH)
        }

        return CGSize(width: contentW.rounded(.up), height: contentH.rounded(.up))
    }

    private static func positive(_ value: CGFloat) -> CGFloat? {
        value.isFinite && value > 1 ? value : nil
    }

    private static func positiveSize(_ size: CGSize) -> CGSize? {
        guard let width = positive(size.width),
              let height = positive(size.height) else { return nil }
        return CGSize(width: width, height: height)
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
