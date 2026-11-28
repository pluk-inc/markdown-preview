//
//  NativeRendererStyle.swift
//  md-preview
//
//  The reader style for the native renderer: the same settings and theme
//  colors the web page gets as CSS, resolved to fonts and colors for one
//  appearance.
//

import AppKit
import MDCore

/// Fonts and colors for one `mdcore_set_style` call. It owns the fonts, so
/// the pointers in `mdcore_style` stay valid while the call runs.
///
/// A value with no actor: the warm-up gives it to its own thread
/// (`NativeRendererWarmUp`). It is made on the main actor, which the
/// settings and the appearance need.
nonisolated struct NativeRendererStyle {
    private let body: NSFont
    private let bold: NSFont
    private let heading: NSFont
    private let code: NSFont
    private var style = mdcore_style()

    /// The current reader settings, for a view with the given appearance.
    @MainActor
    init(appearance: NSAppearance, zoom: CGFloat) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let scheme: ThemeColorScheme = isDark ? .dark : .light
        let theme = ThemeColorsSetting.current
        let layout = ReaderLayoutSetting.current.effective
        let face = DocumentFontSetting.current
        let size = MarkdownHTML.bodyFontSize * zoom

        // "Bold text" in Customize Theme draws the body at weight 600.
        body = face.nsFont(size: size, weight: layout.boldText ? .semibold : .regular)
        bold = face.nsFont(size: size, weight: .bold)
        heading = face.nsFont(size: size, weight: .semibold)
        code = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        style.body_size = size
        style.line_height = layout.lineSpacing
        style.column_width = ContentWidthSetting.current == .normal ? Double(MarkdownHTML.contentColumnWidth) : 0
        // The Margins slider, as `ReaderLayoutSetting.cssVariables` gives it to
        // the page: above zero it narrows the text inside the column, below
        // zero it takes away from the padding around the column.
        style.page_padding = MarkdownHTML.pagePaddingHorizontal * (1 + min(0, layout.marginsPercent) / 100)
        style.column_inset = CGFloat(layout.pageInset)

        func resolved(_ color: NSColor) -> mdcore_color {
            var result = mdcore_color(r: 0, g: 0, b: 0, a: 255)
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = color.usingColorSpace(.sRGB) else { return }
                func byte(_ value: CGFloat) -> UInt8 { UInt8((min(max(value, 0), 1) * 255).rounded()) }
                result = mdcore_color(r: byte(rgb.redComponent), g: byte(rgb.greenComponent),
                                      b: byte(rgb.blueComponent), a: byte(rgb.alphaComponent))
            }
            return result
        }
        func gray(_ light: CGFloat, _ dark: CGFloat) -> NSColor { NSColor(white: (isDark ? dark : light) / 255, alpha: 1) }

        // The same values as the page's style sheet (MarkdownHTML+Stylesheet).
        style.text = resolved(theme.color(.textColor, scheme) ?? (isDark ? .labelColor : .black))
        style.secondary = resolved(.secondaryLabelColor)
        style.link = resolved(theme.color(.linkColor, scheme)
            ?? (isDark ? NSColor(srgbRed: 65 / 255, green: 156 / 255, blue: 1, alpha: 1)
                       : NSColor(srgbRed: 0, green: 104 / 255, blue: 218 / 255, alpha: 1)))
        style.code_background = resolved(theme.color(.codeBlockBackground, scheme) ?? gray(0xf9, 0x26))
        style.code_border = resolved(gray(0xf0, 0x32))
        style.rule = resolved(.separatorColor)
        style.quote_bar = resolved(.quaternaryLabelColor)
        style.selection = resolved(.selectedTextBackgroundColor)
    }

    /// Gives the style to a renderer of the core.
    func apply(to renderer: UnsafeMutableRawPointer?) {
        var style = style
        style.body_font = UnsafeRawPointer(Unmanaged.passUnretained(body).toOpaque())
        style.bold_font = UnsafeRawPointer(Unmanaged.passUnretained(bold).toOpaque())
        style.heading_font = UnsafeRawPointer(Unmanaged.passUnretained(heading).toOpaque())
        style.code_font = UnsafeRawPointer(Unmanaged.passUnretained(code).toOpaque())
        mdcore_set_style(renderer, &style)
    }
}
