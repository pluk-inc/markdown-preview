//
//  ChromeStripClickThrough.swift
//  md-preview
//
//  Keeps window dragging alive under a transparent titlebar on macOS 26.
//
//  With `titlebarAppearsTransparent`, a left click on the toolbar's empty
//  padding (between two buttons) is no longer handled by the titlebar:
//  AppKit re-dispatches it to the view underneath — here a WKWebView, which
//  consumes every mouseDown — so the click never reaches NSThemeFrame and
//  the window stops being draggable there. The web views decline exactly
//  those clicks from hitTest; the re-dispatch then lands on a plain
//  container view whose responder chain ends at NSThemeFrame, which
//  performs the native window drag. Scrolling, hover, and every other
//  event over the toolbar keeps passing through to the page as before.
//

import AppKit

extension NSView {
    /// Whether a `hitTest(_:)` at `point` (superview coordinates, per the
    /// hitTest convention) is a left-mouse click in the titlebar/toolbar
    /// strip of a transparent-titlebar window, and should return nil so the
    /// click keeps its native meaning (window drag, double-click zoom).
    func declinesChromeStripClick(at point: NSPoint) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        guard let window, window.titlebarAppearsTransparent else { return false }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: break
        default: return false
        }
        // contentLayoutRect is in window coordinates; everything above its
        // top edge is the titlebar-and-toolbar strip.
        let windowPoint = superview?.convert(point, to: nil) ?? point
        return windowPoint.y > window.contentLayoutRect.maxY
    }
}
