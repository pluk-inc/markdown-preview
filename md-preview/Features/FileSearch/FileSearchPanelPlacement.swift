import CoreGraphics
import Foundation

enum FileSearchPanelPlacement {
    /// Restore a user drag relative to the document, then fit the palette to
    /// the document's current display rather than a previously used display.
    static func frame(contentSize: CGSize, parentFrame: CGRect,
                      visibleFrame: CGRect, savedOffset: [Double]?) -> CGRect {
        let offset = savedOffset.flatMap { values -> CGPoint? in
            guard values.count == 2, values.allSatisfy(\.isFinite) else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
        let width = min(contentSize.width, max(0, visibleFrame.width - 32))
        let height = min(contentSize.height, max(0, visibleFrame.height - 32))
        let desiredX = offset.map { parentFrame.minX + $0.x } ?? (parentFrame.midX - width / 2)
        let desiredTop = parentFrame.maxY - (offset?.y ?? parentFrame.height * 0.26)
        let x = min(max(desiredX, visibleFrame.minX + 16), visibleFrame.maxX - width - 16)
        let y = min(max(desiredTop - height, visibleFrame.minY + 16), visibleFrame.maxY - height - 16)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
