//
//  HairlineSeparator.swift
//  md-preview
//

import Cocoa

/// 1pt separator-colored hairline. Replacement for `NSBox(.separator)` —
/// `NSBox.separator` inside a bottom `NSTitlebarAccessoryViewController`
/// triggers a macOS 26 layout regression that bypasses the window's
/// `contentMinSize` and collapses the window to the toolbar's natural
/// minimum width.
final class HairlineSeparator: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
