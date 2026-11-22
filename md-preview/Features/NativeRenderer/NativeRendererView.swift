//
//  NativeRendererView.swift
//  md-preview
//
//  The experimental native renderer's view (`RendererSetting.native`). The
//  Markdown core in `markdown-core/` (Odin) does the work: cmark-gfm parses,
//  CoreText shapes the text and breaks the lines, and Metal draws one quad
//  per glyph into this view's layer. This view owns the layer, the scroll
//  position, and the input.
//
//  The core is a static archive that the "Build Markdown Core" phase makes
//  and the app target links. `MDCore` is its C header, as a module.
//

import AppKit
import MDCore
import QuartzCore

final class NativeRendererView: NSView {
    /// The core's renderer. Read in `deinit`, which is why it is unsafe.
    nonisolated(unsafe) private var ctx: UnsafeMutableRawPointer?
    private var hasDocument = false
    private var scrollY: CGFloat = 0
    private var layoutScheduled = false
    private var laidOutSize = NSSize.zero
    private var laidOutScale = 0.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.maximumDrawableCount = 2
        // Transparent: the document background view behind it paints the
        // page color, with the theme and the appearance it already follows.
        layer.isOpaque = false
        return layer
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        ctx = mdcore_create(Unmanaged.passUnretained(layer!).toOpaque())
        applyStyle()
    }

    /// The zoom of the document: the text size is the body size times this.
    var textZoom = TextSizeSetting.currentZoom {
        didSet { if textZoom != oldValue { applyStyle() } }
    }

    /// Reads the reader settings and the theme again and shows the document
    /// with them. For a change of a setting, the theme, or the appearance.
    func applyStyle() {
        NativeRendererStyle(appearance: effectiveAppearance, zoom: textZoom).apply(to: ctx)
        relayout(force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        mdcore_destroy(ctx)
    }

    func open(_ markdown: String) {
        var text = markdown
        text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { mdcore_set_markdown(ctx, $0.baseAddress, $0.count) }
        }
        hasDocument = true
        scrollY = 0
        relayout(force: true)
    }

    /// Gives the core the view's size and draws. Skips a call that changes
    /// nothing, because one turn can report the same size more than once.
    private func relayout(force: Bool = false) {
        guard hasDocument, bounds.width > 0, bounds.height > 0 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        guard force || bounds.size != laidOutSize || scale != laidOutScale else { return }
        laidOutSize = bounds.size
        laidOutScale = scale
        mdcore_resize(ctx, bounds.width, bounds.height, scale)
        draw()
        continueLayout()
    }

    private func draw() {
        guard hasDocument, bounds.width > 0, bounds.height > 0 else { return }
        let maxScroll = max(0, mdcore_content_height(ctx) - bounds.height)
        scrollY = min(max(0, scrollY), maxScroll)
        autoreleasepool { mdcore_draw(ctx, scrollY) }
    }

    /// Lays out the rest of a long document in steps shorter than a frame,
    /// between events.
    private func continueLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            if mdcore_layout_more(self.ctx, 8) { self.continueLayout() }
        }
    }

    override func updateLayer() {
        draw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relayout()
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        scrollY -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        draw()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouse(event, phase: 0)
    }

    override func mouseDragged(with event: NSEvent) { mouse(event, phase: 1) }

    private func mouse(_ event: NSEvent, phase: Int32) {
        let point = convert(event.locationInWindow, from: nil)
        mdcore_mouse(ctx, point.x, point.y + scrollY, phase)
        draw()
    }

    @objc func copy(_ sender: Any?) {
        var length = 0
        guard let bytes = mdcore_selection_text(ctx, &length), length > 0 else { return }
        let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        mdcore_select_all(ctx)
        draw()
    }

    private enum Key {
        static let space: UInt16 = 49
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    override func keyDown(with event: NSEvent) {
        let page = bounds.height - 60
        switch event.keyCode {
        case Key.pageDown, Key.space: scrollY += page
        case Key.pageUp: scrollY -= page
        case Key.downArrow: scrollY += 48
        case Key.upArrow: scrollY -= 48
        case Key.home: scrollY = 0
        case Key.end: scrollY = .greatestFiniteMagnitude
        default: super.keyDown(with: event); return
        }
        draw()
    }
}
