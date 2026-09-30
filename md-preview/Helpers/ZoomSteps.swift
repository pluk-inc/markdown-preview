//
//  ZoomSteps.swift
//  md-preview
//
//  Shared discrete zoom stops used by Settings, shortcuts, pinch, and toolbar.
//  Kept in a file both the app and Quick Look targets can compile.
//

import CoreGraphics

enum ZoomSteps {
    static let values: [CGFloat] = [
        0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0
    ]

    /// Returns the index of the stop nearest to `zoom`.
    static func index(for zoom: CGFloat) -> Int {
        values.indices.min { abs(values[$0] - zoom) < abs(values[$1] - zoom) } ?? 0
    }

    /// Snaps `zoom` to the nearest configured stop.
    static func snap(_ zoom: CGFloat) -> CGFloat {
        values[index(for: zoom)]
    }
}