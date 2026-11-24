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
    /// The height that the page keeps while a document that opened again
    /// in place (`open` with `keepsScroll`) is laid out down to its end.
    private var heldPageHeight: CGFloat?
    /// How far down the core laid the page out, at the last look. The page
    /// can be taller (`heldPageHeight`).
    private var laidOutHeight: CGFloat = 0
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
    private var laidOutPageWidth: CGFloat = 0
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
        renderLoop.didDraw = { [weak self] step in
            self?.frameDidDraw(step)
        }
        applyStyle()

        page.owner = self
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // The owner says how much of the view is covered at its top (`topInset`).
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = page
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(pageDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // A scroll bar that takes room (the system setting "always", or a
        // mouse) has its strip at the right edge; see `pageWidth`.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
        // A scroll by hand takes over from a scroll that the keyboard started.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userWillScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
    }

    /// The offset of the page in the view, in points. Below `topScrollY`
    /// and past the end while the scroll view stretches at an end.
    private var scrollY: CGFloat { scrollView.contentView.bounds.origin.y }

    /// The height of the strip at the top of the view that is covered: by
    /// the toolbar, and by a bar that the app puts below it (the find bar).
    /// The page starts below the strip and scrolls under it. Zero for a
    /// view that starts below the toolbar.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            // A page at its top stays at its top.
            let wasAtTop = scrollY <= topScrollY + 0.5
            endScrollAnimation()
            scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
            updateCoveredEdgeBacking()
            if wasAtTop { scroll(toY: topScrollY) }
            setNeedsDraw()
        }
    }

    /// The system backs the covered top edge of a scroll view itself: the
    /// page shows through, blurred, with a line that closes the strip. It
    /// sizes that backing from the scroll view's safe area, which has only
    /// the window's own chrome in it. This adds the rest of `topInset` (a
    /// bar of the app below the toolbar), so the backing covers all of the
    /// strip, as WebKit's does in the web view. The place of the page does
    /// not depend on it: that is `contentInsets`, set by hand.
    private func updateCoveredEdgeBacking() {
        let extra = max(0, topInset - safeAreaInsets.top)
        if scrollView.additionalSafeAreaInsets.top != extra {
            scrollView.additionalSafeAreaInsets = NSEdgeInsets(top: extra, left: 0, bottom: 0, right: 0)
        }
    }

    override func layout() {
        // The safe area of this view can have changed (the tab bar came
        // or went) with no new `topInset`.
        updateCoveredEdgeBacking()
        super.layout()
    }

    /// The offset at the top of the page.
    private var topScrollY: CGFloat { -scrollView.contentInsets.top }

    /// The height of the part of the view that the toolbar does not cover.
    private var visibleHeight: CGFloat { scrollView.contentView.bounds.height + topScrollY }

    /// An offset, kept inside the page.
    private func clamped(_ y: CGFloat) -> CGFloat {
        let top = topScrollY
        return min(max(top, y), max(top, page.frame.height - scrollView.contentView.bounds.height))
    }

    @objc private func scrollerStyleDidChange() {
        relayout()
    }

    /// The width that the page is laid out in. A scroll bar that takes
    /// room has its strip free at all times, also while a short document
    /// shows no bar: the width of the page then does not depend on its
    /// height, so a bar that comes or goes starts no second layout.
    private var pageWidth: CGFloat {
        guard scrollView.scrollerStyle == .legacy else { return bounds.width }
        return max(bounds.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), 1)
    }

    @objc private func pageDidScroll() {
        // Another place of the page is under the pointer now.
        updatePointerShape()
        updateTaskCheckBoxes()
        guard !followsRenderLoop else { return }
        setNeedsDraw()
    }

    // MARK: Frames

    /// The keyboard scroll in progress: its number in the render loop and
    /// the offset that it goes to.
    private var scrollAnimation: (scroll: Int, target: CGFloat)?

    /// False without a document or a size: there is nothing to draw then.
    private var hasPageToDraw: Bool { hasDocument && bounds.width > 0 && bounds.height > 0 }

    /// Asks for a frame at the next refresh of the display.
    private func setNeedsDraw() {
        guard hasPageToDraw else { return }
        renderLoop.requestFrame(at: scrollY)
    }

    /// After a frame that was a step of a key scroll or that made the page
    /// taller, on the main thread.
    private func frameDidDraw(_ step: NativeRenderLoop.ScrollStep?) {
        // Not for a scroll that the reader took over or that another key
        // press replaced meanwhile: its last frames can come late.
        if let step, step.scroll == scrollAnimation?.scroll {
            followsRenderLoop = true
            scroll(toY: step.y)
            followsRenderLoop = false
            if step.isLast {
                scrollAnimation = nil
                // A frame that the main thread drew meanwhile (a new size)
                // had the offset before this step. Draw the end again.
                setNeedsDraw()
            }
            // The page can have become shorter under the scroll (a new
            // size, a zoom), so the frame is past the end. Draw it where
            // the scroll view could go.
            if abs(scrollY - step.y) > 0.5 { endScrollAnimation() }
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
        let target = clamped(y)
        // The new place replaces the one a scroll in progress went to.
        endScrollAnimation()
        guard abs(target - scrollY) > 1 else { return scroll(toY: target) }
        scrollAnimation = (renderLoop.animateScroll(from: scrollY, to: target), target)
    }

    private func endScrollAnimation() {
        guard scrollAnimation != nil else { return }
        scrollAnimation = nil
        renderLoop.cancelScrollAnimation()
        // The loop can have drawn a step that the scroll view never took.
        // The page must show the offset of the scroll view.
        setNeedsDraw()
    }

    /// The offset that the view scrolls to, when it is on its way there.
    private var scrollTarget: CGFloat { scrollAnimation?.target ?? scrollY }

    @objc private func userWillScroll() {
        endScrollAnimation()
    }

    /// Scrolls to an offset, kept inside the page.
    private func scroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped(y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Makes the scroll view's page as tall as what the core laid out.
    private func updatePageHeight() {
        laidOutHeight = mdcore_content_height(ctx)
        // Not wider than the visible part: a wider page could move sideways.
        let size = NSSize(width: pageWidth, height: max(laidOutHeight, heldPageHeight ?? 0, 1))
        if page.frame.size != size { page.setFrameSize(size) }
        updateTaskCheckBoxes()
        // After each layout and each frame that laid out more: other text
        // can be under a pointer that did not move.
        updatePointerShape()
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
        // No frame and no layout step may run when the core goes away.
        renderLoop.stop()
        mdcore_destroy(ctx)
    }

    /// A click on the check box of a task item: the source line of its
    /// "[ ]" (from 1) and the state it got. The view shows the new state
    /// already; the owner changes the source and saves it.
    var taskCheckboxToggled: ((_ line: Int, _ checked: Bool) -> Void)?

    /// The check boxes of the tasks in view: the system's own buttons, as
    /// subviews of the page, so they scroll with it. The core leaves their
    /// places empty and says where they are. Only the tasks near the view
    /// have a button, by the source line of the task: a task keeps its
    /// button while it is near the view, so the button does not change
    /// its state (which the system animates) when the page moves.
    private var taskCheckBoxes: [Int: TaskCheckBox] = [:]
    /// Buttons that no task has now, to use again. Hidden after a pass.
    private var spareTaskCheckBoxes: [TaskCheckBox] = []
    /// The size that the system gives a check box, and the box in it. The
    /// same for each one, and slow to ask for: the system's check box
    /// answers through its own view tree.
    private lazy var taskCheckBoxShape: (size: NSSize, box: NSRect) = {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.sizeToFit()
        let size = button.bounds.size
        return (size, button.cell?.imageRect(forBounds: NSRect(origin: .zero, size: size)) ?? NSRect(origin: .zero, size: size))
    }()
    /// The part of the page that has its check boxes, and how far down the
    /// page was laid out when the core was asked for them. Nil: ask again.
    private var taskBoxRange: (top: CGFloat, bottom: CGFloat, laidOutTo: CGFloat)?
    private var taskBuffer = [mdcore_task](repeating: mdcore_task(), count: 256)

    /// Puts a check box on each task near the visible part of the page.
    /// A scroll step that stays in the part that has its boxes does
    /// nothing: the boxes move with the page.
    private func updateTaskCheckBoxes() {
        let viewHeight = scrollView.contentView.bounds.height
        if let range = taskBoxRange {
            // Room for a quarter of a view more in each direction.
            let covers = scrollY - viewHeight / 4 >= range.top && scrollY + viewHeight * 1.25 <= range.bottom
            // The layout had reached the end of the part, or it did not
            // go on since then.
            let complete = range.laidOutTo >= range.bottom || laidOutHeight == range.laidOutTo
            if covers && complete { return }
        }
        var count = 0
        if hasDocument {
            // A view of room above and below, so a box is there before a
            // scroll shows its place. Not while the window changes its
            // size: each step of that moves every box.
            let room = inLiveResize ? 0 : viewHeight
            let top = scrollY - room
            let bottom = scrollY + viewHeight + room
            count = mdcore_tasks(ctx, top, bottom, &taskBuffer, taskBuffer.count)
            if count > taskBuffer.count {
                taskBuffer = [mdcore_task](repeating: mdcore_task(), count: count)
                count = min(mdcore_tasks(ctx, top, bottom, &taskBuffer, count), count)
            }
            taskBoxRange = (top, bottom, laidOutHeight)
        }
        let tasks = taskBuffer[..<count]

        // No animation of a move or of a state that this sets: the box
        // goes with the text, which has none.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            NSAnimationContext.endGrouping()
        }

        // The buttons of tasks that left go to the tasks that came, and
        // only the ones that are left over get hidden: to hide and to show
        // a button are slow.
        let lines = Set(tasks.map(\.line))
        for (line, button) in taskCheckBoxes where !lines.contains(line) {
            spareTaskCheckBoxes.append(button)
            taskCheckBoxes[line] = nil
        }
        let shape = taskCheckBoxShape
        for task in tasks {
            let button = taskCheckBoxes[task.line] ?? spareTaskCheckBoxes.popLast() ?? {
                let button = TaskCheckBox(checkboxWithTitle: "", target: self, action: #selector(taskCheckBoxClicked))
                button.setFrameSize(shape.size)
                page.addSubview(button)
                return button
            }()
            taskCheckBoxes[task.line] = button
            // The button keeps its own size as its bounds and gets a frame
            // that makes its box as large as the text asks for: AppKit
            // scales the drawing and the pointer with it.
            let zoom = shape.box.width > 0 ? task.size / shape.box.width : 1
            let frame = NSRect(
                x: task.x - shape.box.minX * zoom, y: task.y - shape.box.minY * zoom,
                width: shape.size.width * zoom, height: shape.size.height * zoom
            )
            if button.frame != frame {
                button.frame = frame
                button.bounds = NSRect(origin: .zero, size: shape.size)
            }
            // From the document each time: a click changes the button
            // itself, and the change may not reach the file.
            let state: NSControl.StateValue = task.checked ? .on : .off
            if button.state != state { button.state = state }
            button.tag = task.line
            if button.isHidden { button.isHidden = false }
        }
        for button in spareTaskCheckBoxes where !button.isHidden { button.isHidden = true }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // The boxes of the room above and below, which a resize leaves out.
        taskBoxRange = nil
        updateTaskCheckBoxes()
    }

    /// The text of the document that the core shows now.
    private var shownMarkdown: String?

    @objc private func taskCheckBoxClicked(_ sender: NSButton) {
        let line = sender.tag
        let checked = sender.state == .on
        // The core changes the state of this one task in place: no new
        // parse, no new layout, and the page does not move. The text that
        // the view shows gets the same change, so `open` knows the
        // document that the owner saves and gives back, and does nothing
        // for it.
        if let shown = shownMarkdown,
           let changed = TaskCheckboxSource.settingChecked(checked, onLine: line, in: shown),
           mdcore_set_task_checked(ctx, line, checked) {
            shownMarkdown = changed
            setNeedsDraw()
        }
        taskCheckboxToggled?(line, checked)
    }

    /// Shows a document. `keepsScroll` is for the same document again (the
    /// text after a click on a task, a file saved by another app): the
    /// reader stays where they are.
    func open(_ markdown: String, keepsScroll: Bool) {
        // The document that shows already: after a click on a task, the
        // saved text comes back here, and the core has that change.
        if keepsScroll, hasDocument, markdown == shownMarkdown {
            // A click that changed nothing (the app could not find the
            // task in its text) changed the button itself all the same.
            // The boxes take their state from the document again.
            taskBoxRange = nil
            updateTaskCheckBoxes()
            return
        }
        shownMarkdown = markdown
        var text = markdown
        text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { mdcore_set_markdown(ctx, $0.baseAddress, $0.count) }
        }
        hasDocument = true
        endScrollAnimation()
        // For the same file with a change from outside (another app saved
        // it, or a click on a task could not be saved): the layout starts
        // again from the top and reaches the end of the document some
        // steps later. Until then the page keeps the height it had, or the
        // scroll bar would jump to another place and back.
        heldPageHeight = keepsScroll ? page.frame.height : nil
        // Before the layout: it lays out what the view shows, and that must
        // be the top of a new document, not the place the old one was at.
        if !keepsScroll { scroll(toY: topScrollY) }
        relayout(force: true)
    }

    /// Gives the core the view's size and draws. Skips a call that changes
    /// nothing, because one turn can report the same size more than once.
    private func relayout(force: Bool = false) {
        // The core needs this layout also when the view has no size now
        // and gets its old size back later.
        if force { laidOutSize = .zero }
        guard hasPageToDraw else { return }
        let scale = Double(window?.backingScaleFactor ?? 2)
        // The frame is as large as the view; the page is laid out in the
        // part of it beside a scroll bar that takes room.
        let pageWidth = pageWidth
        guard bounds.size != laidOutSize || scale != laidOutScale || pageWidth != laidOutPageWidth else { return }
        laidOutSize = bounds.size
        laidOutScale = scale
        laidOutPageWidth = pageWidth
        let size = bounds.size
        layoutCount += 1
        // The new size, then its frame.
        drawNow { [ctx] in
            mdcore_set_page_width(ctx, pageWidth)
            mdcore_resize(ctx, size.width, size.height, scale)
        }
        continueLayout()
    }

    /// Draws a frame now and waits for it: the first frame of a document,
    /// and a frame for a new size, which must be there with the window's.
    /// `before` runs ahead of the frame.
    private func drawNow(before: (() -> Void)? = nil) {
        guard hasPageToDraw else { return }
        renderLoop.frameNow(at: scrollY, before: before)
        // The page was laid out again from its top (a new document, size,
        // or style): each check box can have another place.
        taskBoxRange = nil
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
                // The layout of this document is complete: its height is
                // the real one now.
                if !more && layout == self.layoutCount { self.heldPageHeight = nil }
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
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
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

    /// Shows the cursor for the place of the pointer. The core decides
    /// the shape, and the scroll view shows it as the cursor of its
    /// document, which is the system's way for a scrolled page: no cursor
    /// is set by hand, and none is left behind when the pointer goes out.
    fileprivate func updatePointerShape() {
        guard let window, window.isKeyWindow else { return }
        let point = page.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // Only for a pointer on the part of the page that shows below the
        // toolbar: the cursor of the document is for all of the scroll
        // view, also for the strip that the toolbar covers.
        var shown = scrollView.contentView.bounds
        shown.origin.y += topInset
        shown.size.height -= topInset
        var cursor = NSCursor.arrow
        if hasDocument, shown.contains(point) {
            switch mdcore_pointer_shape(ctx, point.x, point.y) {
            case MDCORE_POINTER_TEXT: cursor = .iBeam
            case MDCORE_POINTER_BUSY:
                // A layout step or a frame has the core. The main thread
                // does not wait for it: the cursor stays, and one later
                // call asks again.
                guard !pointerShapeRetryScheduled else { return }
                pointerShapeRetryScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.pointerShapeRetryScheduled = false
                    self?.updatePointerShape()
                }
                return
            default: break
            }
        }
        if scrollView.documentCursor !== cursor { scrollView.documentCursor = cursor }
    }

    private var pointerShapeRetryScheduled = false

    @objc private func windowDidBecomeKey() {
        updatePointerShape()
    }

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
        switch event.keyCode {
        case Key.pageDown: scrollPageDown(nil)
        case Key.space: event.modifierFlags.contains(.shift) ? scrollPageUp(nil) : scrollPageDown(nil)
        case Key.pageUp: scrollPageUp(nil)
        // With Command, as the Go menu has them, for a key that the menu
        // did not take.
        case Key.downArrow: event.modifierFlags.contains(.command) ? scrollToEndOfDocument(nil) : scrollLineDown(nil)
        case Key.upArrow: event.modifierFlags.contains(.command) ? scrollToBeginningOfDocument(nil) : scrollLineUp(nil)
        case Key.home: scrollToBeginningOfDocument(nil)
        case Key.end: scrollToEndOfDocument(nil)
        default: super.keyDown(with: event)
        }
    }

    // The scroll actions of the Go menu, which takes its key equivalents
    // before `keyDown` gets them. Each goes from the place that a scroll
    // in progress goes to, so fast key presses add up.

    override func scrollLineUp(_ sender: Any?) { animateScroll(toY: scrollTarget - 48) }
    override func scrollLineDown(_ sender: Any?) { animateScroll(toY: scrollTarget + 48) }
    override func scrollPageUp(_ sender: Any?) { animateScroll(toY: scrollTarget - (visibleHeight - 60)) }
    override func scrollPageDown(_ sender: Any?) { animateScroll(toY: scrollTarget + (visibleHeight - 60)) }
    override func scrollToBeginningOfDocument(_ sender: Any?) { animateScroll(toY: topScrollY) }

    override func scrollToEndOfDocument(_ sender: Any?) {
        // The end of the document, not of the part laid out so far.
        _ = mdcore_layout_more(ctx, 0)
        updatePageHeight()
        animateScroll(toY: .greatestFiniteMagnitude)
    }
}

/// The system's check box, on a task of the page. Only the cursor is its
/// own: the arrow on all of the button, also where its frame reaches the
/// start of the item's text.
private final class TaskCheckBox: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The scroll view's document view: an empty area as tall as the page. It
/// draws nothing; it gives the scroll view a size to scroll and takes the
/// pointer events of the page.
private final class PageArea: NSView {
    weak var owner: NativeRendererView?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // For the cursor (`updatePointerShape`). `.inVisibleRect` follows
        // the size of the page, so the area is added one time.
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseEntered(with event: NSEvent) { owner?.updatePointerShape() }
    override func mouseMoved(with event: NSEvent) { owner?.updatePointerShape() }

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
