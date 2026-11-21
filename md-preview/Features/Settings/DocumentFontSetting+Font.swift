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

extension DocumentFontSetting {
    /// The AppKit face for the native renderer, which draws with CoreText
    /// and so cannot use the CSS stack.
    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        func designed(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
            system.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        }
        func family(_ name: String) -> NSFont {
            // NSFontManager weights: 5 is regular, 9 is bold.
            let managerWeight = weight.rawValue >= NSFont.Weight.semibold.rawValue ? 9 : 5
            return NSFontManager.shared.font(withFamily: name, traits: [], weight: managerWeight, size: size) ?? system
        }
        switch self {
        case .system: return system
        case .athelas: return family("Athelas")
        case .avenirNext: return family("Avenir Next")
        case .charter: return family("Charter")
        case .georgia: return family("Georgia")
        case .iowan: return family("Iowan Old Style")
        case .newYork: return designed(.serif)
        case .palatino: return family("Palatino")
        case .rounded: return designed(.rounded)
        case .seravek: return family("Seravek")
        case .timesNewRoman: return family("Times New Roman")
        case .monospace: return designed(.monospaced)
        }
    }
}
