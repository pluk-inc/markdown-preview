//
//  DocumentFontSetting+Font.swift
//  md-preview
//
//  SwiftUI font for each reading face, so the pickers and the theme cards
//  render every option in the face it applies. Kept out of
//  DocumentFontSetting itself: that file is shared with the Quick Look
//  extension and the Foundation-only test package, and it carries CSS font
//  stacks rather than AppKit faces.
//
//  Each case names the same first family its CSS stack does; the two must
//  move together, or the previews stop matching the rendered page.
//

import SwiftUI

extension DocumentFontSetting {
    func font(size: CGFloat) -> Font {
        switch self {
        case .system: .system(size: size)
        case .athelas: .custom("Athelas", size: size)
        case .avenirNext: .custom("Avenir Next", size: size)
        case .charter: .custom("Charter", size: size)
        case .georgia: .custom("Georgia", size: size)
        case .iowan: .custom("Iowan Old Style", size: size)
        case .newYork: .system(size: size, design: .serif)
        case .palatino: .custom("Palatino", size: size)
        case .rounded: .system(size: size, design: .rounded)
        case .seravek: .custom("Seravek", size: size)
        case .timesNewRoman: .custom("Times New Roman", size: size)
        case .monospace: .system(size: size, design: .monospaced)
        }
    }
}
