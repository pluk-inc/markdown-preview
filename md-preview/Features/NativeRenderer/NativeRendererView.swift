//
//  NativeRendererView.swift
//  md-preview
//
//  The experimental native renderer's view (`RendererSetting.native`). The
//  Markdown core in `markdown-core/` (Odin) does the work: md4c parses,
//  CoreText shapes the text and breaks the lines, and Metal draws one quad
//  per glyph into this view's layer. This view owns the layer, the scroll
//  position, and the input.
//
//  Scrolling is AppKit's: a transparent `NSScrollView` lies over the Metal
//  layer, with an empty document view as tall as the page. It gives the
//  scroll bar, momentum, and the elastic ends; this view reads its offset
//  and draws the page there.
//
//  Drawing follows the display, not the events: a scroll or a selection
//  change only asks the render loop for a frame, and the loop draws one
//  frame for each refresh of the display, off the main thread
//  (`NativeRenderLoop`). A draw can wait for a drawable and can make glyph
//  bitmaps, and on the main thread that made the scroll fall behind the
//  fingers.
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
    private let scrollView = NSScrollView()
    private let page = PageArea()
    private var layoutScheduled = false
    /// Goes up with each new layout (a document, a size, a style).
    private var layoutCount = 0
    /// Draws the frames and runs the layout steps off the main thread, so
    /// work that makes glyphs or breaks lines does not hold it.
    /// Read in `deinit`, which is why it is unsafe.
    nonisolated(unsafe) private var renderLoop: NativeRenderLoop!
    /// True while the scroll view takes the offset of a scroll that the
    /// render loop animates: that frame is drawn already.
    private var followsRenderLoop = false
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
        renderLoop = NativeRenderLoop(ctx: ctx)
        renderLoop.didDraw = { [weak self] animatedY, animationEnded in
            self?.frameDidDraw(animatedY: animatedY, animationEnded: animationEnded)
        }
        applyStyle()

        page.owner = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // The view already starts below the toolbar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = page
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // A scroll by hand takes over from a scroll that the keyboard started.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userWillScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
    }

    /// The offset of the page in the view, in points. Below zero and past
    /// the end while the scroll view stretches at an end.
    private var scrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    @objc private func pageDidScroll() {
        guard !followsRenderLoop else { return }
        setNeedsDraw()
    }

    // MARK: Frames

    /// The offset that a keyboard scroll in progress goes to.
    private var scrollAnimationTarget: CGFloat?

    /// Asks for a frame at the next refresh of the display.
    private func setNeedsDraw() {
        guard hasDocument, bounds.width > 0, bounds.height > 0 else { return }
        renderLoop.requestFrame(at: scrollY)
    }

    /// After each frame, on the main thread.
    private func frameDidDraw(animatedY: Double?, animationEnded: Bool) {
        // Not for a scroll that the reader took over meanwhile.
        if let animatedY, scrollAnimationTarget != nil {
            followsRenderLoop = true
            scroll(toY: animatedY)
            followsRenderLoop = false
            if animationEnded { scrollAnimationTarget = nil }
        }
        // A draw can lay out more of the page, when the view came to the
        // end of what the steps reached. The main thread reads the height
        // itself: a height sent from the render thread can come after a
        // newer one.
        updatePageHeight()
    }

    /// Scrolls to an offset over a short time, as the system's views do
    /// for the keyboard. The render loop moves the page, one step for each
    /// frame, and the scroll view follows.
    private func animateScroll(toY y: CGFloat) {
        let limit = max(0, page.frame.height - scrollView.contentView.bounds.height)
        let target = min(max(0, y), limit)
        // The new place replaces the one a scroll in progress went to.
        endScrollAnimation()
        guard abs(target - scrollY) > 1 else { return scroll(toY: target) }
        scrollAnimationTarget = target
        renderLoop.animateScroll(from: scrollY, to: target)
    }

    private func endScrollAnimation() {
        scrollAnimationTarget = nil
        renderLoop.cancelScrollAnimation()
    }

    /// The offset that the view scrolls to, when it is on its way there.
    private var scrollTarget: CGFloat { scrollAnimationTarget ?? scrollY }

    @objc private func userWillScroll() {
        endScrollAnimation()
    }

    /// Scrolls to an offset, kept inside the page.
    private func scroll(toY y: CGFloat) {
        let limit = max(0, page.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), limit)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Makes the scroll view's page as tall as what the core laid out.
    private func updatePageHeight() {
        let size = NSSize(width: bounds.width, height: max(mdcore_content_height(ctx), 1))
        if page.frame.size != size { page.setFrameSize(size) }
    }

    /// The zoom of the document: the text size is the body size times this.
    var textZoom = TextSizeSetting.currentZoom {
        didSet { if textZoom != oldValue { applyStyle() } }
    }

    /// Reads the reader settings and the theme again and shows the document
    /// with them. For a change of a setting, the theme, or the appearance.
    func applyStyle() {
        NativeRendererStyle(appearance: effectiveAppearance, zoom: textZoom).apply(to: ctx)
        // The core needs a new layout, also when the view has no size now and
        // gets its old size back later.
        laidOutSize = .zero
        relayout(force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // No frame and no layout step may run when the core goes away.
        renderLoop.stop()
        mdcore_destroy(ctx)
    }

    func open(_ markdown: String) {
        var text = markdown
        text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { mdcore_set_markdown(ctx, $0.baseAddress, $0.count) }
        }
        hasDocument = true
        endScrollAnimation()
        // Before the layout: it lays out what the view shows, and that must
        // be the top of the new document, not the place the old one was at.
        scroll(toY: 0)
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
        let size = bounds.size
        layoutCount += 1
        // The new size, then its frame, in this order off the main thread.
        drawNow { [ctx] in mdcore_resize(ctx, size.width, size.height, scale) }
        continueLayout()
    }

    /// Draws a frame now and waits for it: the first frame of a document,
    /// and a frame for a new size, which must be there with the window's.
    /// `before` runs off the main thread ahead of the frame.
    private func drawNow(before: (@Sendable () -> Void)? = nil) {
        guard hasDocument, bounds.width > 0, bounds.height > 0 else { return }
        renderLoop.frameNow(at: scrollY, before: before)
        updatePageHeight()
    }

    /// Lays out the rest of a long document in steps shorter than a frame,
    /// off the main thread, so frames go between them.
    private func continueLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        nonisolated(unsafe) let ctx = ctx
        let layout = layoutCount
        renderLoop.perform { [weak self] in
            let more = mdcore_layout_more(ctx, 4)
            DispatchQueue.main.async {
                guard let self else { return }
                self.layoutScheduled = false
                self.updatePageHeight()
                // A step that ran for a layout before the present one
                // says nothing about what is left of this one.
                if more || layout != self.layoutCount { self.continueLayout() }
            }
        }
    }

    override func updateLayer() {
        drawNow()
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
        if window == nil { endScrollAnimation() }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(followDisplay),
                name: NSWindow.didChangeScreenNotification, object: window
            )
        }
        followDisplay()
        relayout()
    }

    /// The render loop's clock runs at the refresh rate of one display.
    @objc private func followDisplay() {
        guard let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        renderLoop.setDisplay(CGDirectDisplayID(number.uint32Value))
    }

    // MARK: Input

    /// A pointer event on the page. `point` is in page coordinates, which
    /// are the core's document space. phase: 0 = down, 1 = drag.
    fileprivate func pointer(at point: NSPoint, phase: Int32) {
        if phase == 0 { window?.makeFirstResponder(self) }
        mdcore_mouse(ctx, point.x, point.y, phase)
        setNeedsDraw()
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
        updatePageHeight()
        setNeedsDraw()
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
        let step = bounds.height - 60
        switch event.keyCode {
        // From the place a scroll in progress goes to, so fast key presses add up.
        case Key.pageDown, Key.space: animateScroll(toY: scrollTarget + step)
        case Key.pageUp: animateScroll(toY: scrollTarget - step)
        case Key.downArrow: animateScroll(toY: scrollTarget + 48)
        case Key.upArrow: animateScroll(toY: scrollTarget - 48)
        case Key.home: animateScroll(toY: 0)
        case Key.end:
            // The end of the document, not of the part laid out so far.
            _ = mdcore_layout_more(ctx, 0)
            updatePageHeight()
            animateScroll(toY: .greatestFiniteMagnitude)
        default: super.keyDown(with: event)
        }
    }
}

/// The scroll view's document view: an empty area as tall as the page. It
/// draws nothing; it gives the scroll view a size to scroll and takes the
/// pointer events of the page.
private final class PageArea: NSView {
    weak var owner: NativeRendererView?

    override var isFlipped: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        owner?.pointer(at: convert(event.locationInWindow, from: nil), phase: 0)
    }

    /// The last drag event, repeated by a timer while the button is down:
    /// AppKit sends no drag events for a pointer that does not move, and a
    /// pointer held past the top or the bottom must keep the page scrolling.
    private var lastDrag: NSEvent?
    private var dragTimer: Timer?

    override func mouseDragged(with event: NSEvent) {
        lastDrag = event
        extendSelection()
        guard dragTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.extendSelection() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    /// A view that leaves its window in the middle of a drag gets no mouse up.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { endDrag() }
    }

    private func endDrag() {
        dragTimer?.invalidate()
        dragTimer = nil
        lastDrag = nil
    }

    /// Scrolls when the drag is outside the visible part, then moves the
    /// end of the selection to the pointer.
    private func extendSelection() {
        guard let event = lastDrag else { return }
        autoscroll(with: event)
        owner?.pointer(at: convert(event.locationInWindow, from: nil), phase: 1)
    }
}
