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
    /// The core's number of its layout at the last look
    /// (`mdcore_page_area`). What the view has from another one (the
    /// places of the check boxes) is old.
    private var layoutRevision = 0
    /// Draws the frames off the main thread, so work that makes glyphs or
    /// breaks lines does not hold it.
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
        // The view starts in Read mode: the footnotes are a list at the end.
        mdcore_set_notes_at_end(ctx, true)
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
            // The first line that the reader sees is another one now.
            mdcore_set_top_inset(ctx, topInset)
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

    /// The offset at the top of the page. The page does not start at 0:
    /// the core moves its top when a part above the reader gets its real
    /// height, so the text that shows keeps its offset (`updatePageArea`).
    private var topScrollY: CGFloat { page.frame.minY - scrollView.contentInsets.top }

    /// The height of the part of the view that the toolbar does not cover.
    private var visibleHeight: CGFloat { scrollView.contentView.bounds.height - scrollView.contentInsets.top }

    /// An offset, kept inside the page.
    private func clamped(_ y: CGFloat) -> CGFloat {
        Self.clamped(
            y, top: page.frame.minY, height: page.frame.height,
            inset: scrollView.contentInsets.top, viewHeight: scrollView.contentView.bounds.height
        )
    }

    /// An offset, kept inside a page that is `height` tall from `top`
    /// down, in a view whose first `inset` points are covered.
    nonisolated private static func clamped(
        _ y: CGFloat, top: CGFloat, height: CGFloat, inset: CGFloat, viewHeight: CGFloat
    ) -> CGFloat {
        min(max(top - inset, y), max(top - inset, top + height - viewHeight))
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
        // The core takes the reader's place from the last offset that it
        // heard of, when the layout changes.
        mdcore_note_scroll(ctx, scrollY)
        // The window of an input method goes with the caret.
        if markedText != nil { inputContext?.invalidateCharacterCoordinates() }
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

    /// Asks for a frame at the next refresh of the display. `soon`: for
    /// a key, the frame does not wait for the refresh
    /// (`NativeRenderLoop.requestFrame`).
    private func setNeedsDraw(soon: Bool = false) {
        guard hasPageToDraw else { return }
        renderLoop.requestFrame(at: scrollY, soon: soon)
    }

    /// After a frame that was a step of a key scroll or that made the page
    /// taller, on the main thread.
    private func frameDidDraw(_ step: NativeRenderLoop.ScrollStep?) {
        // A draw lays out the parts of the page that it shows first. The
        // main thread reads the range of the page itself: one sent from
        // the render thread can come after a newer one. Before the step
        // of a scroll, which must be inside that range.
        updatePageArea()
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
    }

    /// Scrolls to an offset over a short time, as the system's views do
    /// for the keyboard. The render loop moves the page, one step for each
    /// frame, and the scroll view follows.
    /// `toFixedPlace`: to the top or the end of the document, which must
    /// be the top or the end when the scroll gets there.
    private func animateScroll(toY y: CGFloat, toFixedPlace: Bool = false) {
        let target = clamped(y)
        // The new place replaces the one a scroll in progress went to.
        endScrollAnimation()
        guard abs(target - scrollY) > 1 else { return scroll(toY: target) }
        scrollAnimation = (renderLoop.animateScroll(from: scrollY, to: target, toFixedPlace: toFixedPlace), target)
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
        hideNoteBubble()
    }

    /// Where the reader was before a click on a footnote number, by the
    /// number of the footnote: the offset that a click on the mark of its
    /// text goes back to.
    private var noteReturns: [Int: CGFloat] = [:]

    /// Scrolls to an offset, kept inside the page.
    private func scroll(toY y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped(y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Gives the scroll view's page the range that the page has in the
    /// core: its top and its height. The two change when the core lays
    /// out a part whose height was estimated. The top is not 0 then; the
    /// offsets of the text that shows stay as they are.
    private func updatePageArea() {
        var top = 0.0, height = 0.0
        let revision = mdcore_page_area(ctx, &top, &height)
        // Not wider than the visible part: a wider page could move sideways.
        // Not lower than the visible part either: the page takes the clicks,
        // and one under the text (in an empty document, under nothing) puts
        // the caret at the end of the text. As high as the view, it adds no
        // room to scroll.
        let visible = scrollView.contentView.bounds.height - scrollView.contentInsets.top - scrollView.contentInsets.bottom
        let frame = NSRect(x: 0, y: top, width: pageWidth, height: max(height, visible, 1))
        // What is at a place of the page is the same while the layout and
        // the page area are: this runs after each key, each step of a
        // scroll, and each new layout, and most of them change neither.
        let frameChanged = page.frame != frame
        let moved = revision != layoutRevision || frameChanged
        layoutRevision = revision
        if frameChanged {
            page.frame = frame
            // A height in the page area is a height of the core's page,
            // for the check boxes and the pointer.
            page.setBoundsOrigin(frame.origin)
        }
        if moved {
            updateTaskCheckBoxes()
            // After each layout and each frame that laid out more: other
            // text can be under a pointer that did not move.
            updatePointerShape()
        }
        // The caret is where the layout has its text, and it moves with
        // no new layout too. So does the text of an input method that is
        // not final, which ends at the caret: the input method asks for
        // its place again.
        if isEditable { updateCaretIndicator() }
        if markedText != nil { inputContext?.invalidateCharacterCoordinates() }
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
        // No frame may run when the core goes away.
        renderLoop.stop()
        mdcore_destroy(ctx)
    }

    /// A click on the check box of a task item: the source line of its
    /// "[ ]" (from 1) and the state it got. The view shows the new state
    /// already; the owner changes the source and saves it.
    var taskCheckboxToggled: ((_ line: Int, _ checked: Bool) -> Void)?

    // MARK: Edit mode

    /// Edit mode: a click puts a caret in the text, and the view takes
    /// the keys. The document is the one that the view shows; no second
    /// view comes in, so the reader stays at their place.
    var isEditable = false {
        didSet {
            guard isEditable != oldValue else { return }
            markedText = nil
            // The texts of the footnotes are where a reader types them in
            // Edit mode, and in a list at the end of the page that is read.
            mdcore_set_notes_at_end(ctx, !isEditable)
            relayout(force: true)
            if isEditable {
                // The system's caret shows where the core's caret is.
                mdcore_caret_show(ctx, false)
                if caretIndicator.superview == nil { page.addSubview(caretIndicator) }
            } else {
                clearCaret()
                setNeedsDraw()
            }
            updateCaretIndicator()
        }
    }

    /// Puts the caret at the start of the first text that shows, when the
    /// view has none: Edit mode starts with a place to type, with no click
    /// first. The page does not scroll for a place that shows.
    func placeCaretInView() {
        guard isEditable, !hasCaret, hasDocument else { return }
        // A view with no size has no layout to put a caret in: the caret
        // comes with the first layout (`relayout`).
        firstCaretWaits = !hasPageToDraw
        guard hasPageToDraw else { return }
        // A keyboard scroll on its way stops here: the caret goes into the
        // view that shows, and the page must not move on from it.
        endScrollAnimation()
        // With the room that a caret keeps to the edges of the view
        // (`keepCaretInView`), or the first key moves the page. Not at
        // the top of the document, where the page cannot move up.
        let shown = visiblePageRange
        let top = shown.lowerBound + (scrollY > topScrollY ? Self.caretRoom : 0)
        let bottom = max(top, shown.upperBound - Self.caretRoom)
        guard mdcore_caret_set_in(ctx, top, bottom) else { return }
        caretWasSet()
        // For a caret out of that range: no line of text is all in it
        // (one tall thing fills the view), so the page goes to the caret.
        keepCaretInView()
        updateCaretIndicator()
        setNeedsDraw()
    }

    /// A start of Edit mode found a view with no size, so its caret waits
    /// for a layout.
    private var firstCaretWaits = false

    /// The room that the caret keeps to the top and the bottom of the view.
    private static let caretRoom: CGFloat = 24

    /// The part of the page that shows under the top inset, in the space
    /// of the page.
    private var visiblePageRange: ClosedRange<CGFloat> {
        let top = scrollY + scrollView.contentInsets.top
        return top...max(top, scrollY + scrollView.contentView.bounds.height)
    }

    /// Puts the caret at the text of a point of the page. False where the
    /// source has no room for text (a table cell with no text): the caret
    /// then stays where it was.
    private func takeCaret(at point: NSPoint) -> Bool {
        guard mdcore_caret_set(ctx, point.x, point.y) else { return false }
        caretWasSet()
        return true
    }

    /// The view has a caret at a new place: text that an input method
    /// did not make final was for the place before.
    private func caretWasSet() {
        hasCaret = true
        markedText = nil
        inputContext?.discardMarkedText()
    }

    private func clearCaret() {
        hasCaret = false
        firstCaretWaits = false
        mdcore_caret_clear(ctx)
    }

    /// The reader changed the text (`DocumentEditor`).
    var contentDidChange: (() -> Void)?
    /// The reader pressed Escape in Edit mode (`DocumentEditor`).
    var cancelRequested: (() -> Void)?
    /// The view has a caret: from the start of Edit mode
    /// (`placeCaretInView`) or from a click.
    private var hasCaret = false
    /// What the core knows of the keys (`mdcore_set_focused`); it starts
    /// with true.
    fileprivate var coreHasKeys = true
    /// The text of an input method that is not final yet: where it is in
    /// the source of the document, in bytes, and the text itself, which
    /// the system's text input counts in UTF-16 units. The next form of
    /// it, or the final text, takes its place.
    /// `lead`: the bytes that the core put before the text when it went
    /// into an empty line (a line break). They go with the text when
    /// the input method takes all of it back.
    private var markedText: (start: Int, length: Int, text: String, selection: NSRange, lead: Int)?
    /// The caret that the reader sees: the system's own, which blinks as
    /// the system's settings say. It is on the page, at the place that
    /// the core gives.
    private let caretIndicator: NSTextInsertionIndicator = {
        let indicator = NSTextInsertionIndicator(frame: .zero)
        indicator.displayMode = .hidden
        return indicator
    }()

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
    /// The range of the page that has its check boxes, and the layout
    /// that the core gave them for (`layoutRevision`). Nil: ask again.
    private var taskBoxRange: (top: CGFloat, bottom: CGFloat, revision: Int)?
    private var taskBuffer = [mdcore_task](repeating: mdcore_task(), count: 256)

    /// Puts a check box on each task near the visible part of the page.
    /// A scroll step that stays in the part that has its boxes does
    /// nothing: the boxes move with the page.
    private func updateTaskCheckBoxes() {
        let viewHeight = scrollView.contentView.bounds.height
        if let range = taskBoxRange {
            // Room for a quarter of a view more in each direction.
            let covers = scrollY - viewHeight / 4 >= range.top && scrollY + viewHeight * 1.25 <= range.bottom
            // And the layout is the one that the boxes were placed in.
            if covers && range.revision == layoutRevision { return }
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
            taskBoxRange = (top, bottom, layoutRevision)
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
        if isEditable {
            // In Edit mode the core has the text: the mark changes
            // there, and the owner saves it with the other edits.
            if mdcore_set_task_checked(ctx, line, checked) { didEdit() }
            return
        }
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
        // The text changed under the text of an input method that is not
        // final: its range is of the text before.
        if markedText != nil {
            markedText = nil
            inputContext?.discardMarkedText()
        }
        var text = markdown
        text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) { mdcore_set_markdown(ctx, $0.baseAddress, $0.count) }
        }
        // Another document: Undo has no change of it, also when its text
        // is the same as the one before (two empty files).
        if !keepsScroll { mdcore_forget_history(ctx) }
        hasDocument = true
        // The text of a footnote can be another text now.
        hideNoteBubble()
        endScrollAnimation()
        // The core changed the document in place: what is the same as
        // before kept its layout, and the reader's place its height. A new
        // document starts at its top, which can be at another height now.
        if !keepsScroll {
            noteReturns.removeAll()
            mdcore_select_none(ctx)
            updatePageArea()
            scroll(toY: topScrollY)
        }
        relayout(force: true)
        // Another document in Edit mode (it started before the document
        // was here): the caret of the text before is no place of this one.
        if !keepsScroll, isEditable {
            clearCaret()
            placeCaretInView()
        }
    }

    /// Gives the core the view's size and draws. Skips a call that changes
    /// nothing, because one turn can report the same size more than once.
    ///
    /// The offset of the scroll view stays as it is. The core keeps the
    /// first text that the reader sees at its height of the page in the
    /// new layout (a new width, a new style), and the top of the page
    /// where it is for a new document.
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
        // A key scroll in progress goes to an offset of the layout before:
        // it ends where it is. The places that the reader came to a
        // footnote from are heights of that layout too: a click on the
        // mark of the footnote goes to its first reference then.
        endScrollAnimation()
        noteReturns.removeAll()
        let offset = scrollY
        let topInset = topInset
        let viewHeight = scrollView.contentView.bounds.height
        // The new size, then its frame.
        drawNow { [ctx] in
            mdcore_set_page_width(ctx, pageWidth)
            mdcore_resize(ctx, size.width, size.height, scale)
            // Not past an end of the new page, where the scroll view
            // cannot go: the frame must be the one that stays.
            var top = 0.0, height = 0.0
            _ = mdcore_page_area(ctx, &top, &height)
            return Self.clamped(offset, top: top, height: height, inset: topInset, viewHeight: viewHeight)
        }
        if firstCaretWaits { placeCaretInView() }
    }

    /// Draws a frame now and waits for it: the first frame of a document,
    /// and a frame for a new size, which must be there with the window's.
    /// `before` runs ahead of the frame, and can give the offset to draw
    /// at; the scroll view then goes there too.
    private func drawNow(before: (() -> Double?)? = nil) {
        guard hasPageToDraw else { return }
        // Also for a view that never scrolled.
        mdcore_note_scroll(ctx, scrollY)
        let drawn = renderLoop.frameNow(at: scrollY, before: before)
        // Also takes the check boxes again, when the layout is a new one.
        updatePageArea()
        if abs(drawn - scrollY) > 0.01 {
            // That frame is drawn already.
            followsRenderLoop = true
            scroll(toY: drawn)
            followsRenderLoop = false
            // The scroll view could not go there (the end of the page):
            // the frame for where it is.
            if abs(drawn - scrollY) > 0.5 { setNeedsDraw() }
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
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification, object: window
            )
            // The caret shows only in the window that takes the keys.
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification, object: window
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
        // The number of the footnote whose reference the pointer is on.
        var note = 0
        if hasDocument, shown.contains(point) {
            switch mdcore_pointer_shape(ctx, point.x, point.y, &note) {
            case MDCORE_POINTER_TEXT: cursor = .iBeam
            case MDCORE_POINTER_LINK: cursor = .pointingHand
            case MDCORE_POINTER_BUSY:
                // A frame has the core. The main thread
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
        hoverNote(note, at: point)
    }

    // MARK: - The text of a footnote beside its number

    /// The bubble with the text of a footnote, while the pointer is on
    /// the number of that footnote in the text.
    private var noteBubble: NSPopover?
    /// The number of the footnote that the bubble is for, or waits for.
    private var noteBubbleNumber = 0
    private var noteBubbleWork: DispatchWorkItem?

    /// The pointer is at `point`, on the number of footnote `number` in
    /// the text (0 for a point on none). A pointer that stays on the
    /// number of a footnote for a moment shows the text of that footnote:
    /// a reader reads it with no jump, and in Edit mode with no move of
    /// the caret.
    private func hoverNote(_ number: Int, at point: NSPoint) {
        // Not while a button is down: the reader selects text or clicks.
        guard number > 0, NSEvent.pressedMouseButtons == 0 else {
            hideNoteBubble()
            return
        }
        guard number != noteBubbleNumber else { return }
        hideNoteBubble()
        noteBubbleNumber = number
        let work = DispatchWorkItem { [weak self] in self?.showNoteBubble(number, at: point) }
        noteBubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func showNoteBubble(_ number: Int, at point: NSPoint) {
        var length = 0
        guard number == noteBubbleNumber, window != nil,
              let bytes = mdcore_note_text(ctx, number, &length), length > 0 else { return }
        let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.isSelectable = false
        // The size of the text in lines of not more than the widest
        // bubble: the bubble gets it as a frame, because a popover gives
        // a view with only constraints no width.
        let widest: CGFloat = 340
        let padding = NSSize(width: 12, height: 10)
        let fitted = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: widest, height: .greatestFiniteMagnitude))
            ?? NSSize(width: widest, height: 20)
        let textSize = NSSize(width: min(ceil(fitted.width), widest), height: ceil(fitted.height))
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
        let size = NSSize(width: textSize.width + 2 * padding.width, height: textSize.height + 2 * padding.height)
        let content = NSViewController()
        content.view = NSView(frame: NSRect(origin: .zero, size: size))
        content.view.addSubview(label)
        let bubble = NSPopover()
        bubble.contentViewController = content
        bubble.contentSize = size
        // The app closes it: it must not take the keys from the page.
        bubble.behavior = .applicationDefined
        bubble.animates = false
        bubble.show(relativeTo: NSRect(x: point.x - 4, y: point.y - 12, width: 8, height: 24), of: page, preferredEdge: .maxY)
        noteBubble = bubble
    }

    fileprivate func pointerLeftPage() { hideNoteBubble() }

    private func hideNoteBubble() {
        noteBubbleWork?.cancel()
        noteBubbleWork = nil
        noteBubbleNumber = 0
        noteBubble?.close()
        noteBubble = nil
    }

    private var pointerShapeRetryScheduled = false

    @objc private func windowDidBecomeKey() {
        updatePointerShape()
        updateCaretIndicator()
    }

    @objc private func windowDidResignKey() {
        updateCaretIndicator()
    }

    /// The footnote that a point of the view is on: the number of a
    /// reference, or (`isDefinition`) the mark of the text of a footnote.
    fileprivate func note(at point: NSPoint) -> (number: Int, isDefinition: Bool)? {
        var number = 0
        var isDefinition = false
        guard mdcore_note_at(ctx, point.x, point.y, &number, &isDefinition) else { return nil }
        return (number, isDefinition)
    }

    /// A click on the page (the button went down and up at one place). A
    /// click on the number of a footnote goes to the text of that
    /// footnote, and a click on the number mark of that text goes back to
    /// where the reader was, or to its first reference. In Edit mode only
    /// with Command, because a click there puts the caret. `note` is the
    /// footnote that the point was on when the button went down: in Edit
    /// mode the caret is there after that, and a number with the caret in
    /// it shows as its source, which is no number to find.
    fileprivate func click(on note: (number: Int, isDefinition: Bool)?, withCommand: Bool) {
        hideNoteBubble()
        // In Edit mode a click puts the caret; with Command it follows.
        guard !isEditable || withCommand, let note else { return }
        // A key scroll in progress would go on from the new place.
        endScrollAnimation()
        let number = note.number
        var target = 0.0
        if note.isDefinition {
            if let back = noteReturns.removeValue(forKey: number) {
                scroll(toY: back)
                setNeedsDraw()
                return
            }
            guard mdcore_note_top(ctx, number, 1, &target) else { return }
        } else {
            guard mdcore_note_top(ctx, number, 0, &target) else { return }
            noteReturns[number] = scrollY
        }
        // The page can have another height with that part laid out.
        updatePageArea()
        scroll(toY: target - topInset - Self.noteRoom)
        setNeedsDraw()
    }

    /// Room above the block that a click on a footnote goes to.
    private static let noteRoom: CGFloat = 24

    /// A pointer event on the page. `point` is in page coordinates, which
    /// are the core's document space. phase: 0 = down, 1 = drag.
    fileprivate func pointer(at point: NSPoint, phase: Int32) {
        if phase == 0 { window?.makeFirstResponder(self) }
        mdcore_mouse(ctx, point.x, point.y, phase)
        if isEditable, phase == 0 {
            _ = takeCaret(at: point)
            updateCaretIndicator()
        } else if isEditable, hasCaret {
            // A drag moves the caret with the end of the selection, and
            // the caret does not show while text is selected.
            updateCaretIndicator()
        }
        setNeedsDraw()
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        mdcore_select_all(ctx)
        updatePageArea()
        setNeedsDraw()
    }

    private enum Key {
        static let space: UInt16 = 49
        static let home: UInt16 = 115
        static let pageUp: UInt16 = 116
        static let escape: UInt16 = 53
        static let end: UInt16 = 119
        static let pageDown: UInt16 = 121
        static let downArrow: UInt16 = 125
        static let upArrow: UInt16 = 126
    }

    override func keyDown(with event: NSEvent) {
        hideNoteBubble()
        if isEditable {
            // Escape leaves Edit mode, also before a click gave a caret.
            // Not while an input method has text that is not final: the
            // key is the input method's, to take that text back.
            if event.keyCode == Key.escape, markedText == nil {
                cancelOperation(nil)
                return
            }
            if hasCaret {
                // Command-Shift-K takes the lines of the caret out. The
                // system's key bindings have no command for it.
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "k" {
                    deleteLines()
                    return
                }
                // Through the system's text input: an input method, the
                // dead keys, and the key bindings of the reader give
                // text and commands (`NSTextInputClient` below).
                interpretKeyEvents([event])
                return
            }
        }
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
    override func scrollToBeginningOfDocument(_ sender: Any?) {
        animateScroll(toY: topScrollY, toFixedPlace: true)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        // The end of the document at its real height, not at an estimate.
        mdcore_layout_end(ctx)
        updatePageArea()
        animateScroll(toY: .greatestFiniteMagnitude, toFixedPlace: true)
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
    /// The pointer is on no footnote of the page now.
    override func mouseExited(with event: NSEvent) { owner?.pointerLeftPage() }
    override func mouseMoved(with event: NSEvent) { owner?.updatePointerShape() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        // Before the caret goes there (see `click`).
        downNote = owner?.note(at: point)
        // A press is no wait on a number: no bubble comes up in a drag.
        owner?.pointerLeftPage()
        owner?.pointer(at: point, phase: 0)
    }

    /// Where the button went down, for a click (a mouse up at that place),
    /// and the footnote that was at that point then.
    private var downPoint: NSPoint?
    private var downNote: (number: Int, isDefinition: Bool)?

    /// The last drag event, repeated by a timer while the button is down:
    /// AppKit sends no drag events for a pointer that does not move, and a
    /// pointer held past the top or the bottom must keep the page scrolling.
    private var lastDrag: NSEvent?
    private var dragTimer: Timer?

    override func mouseDragged(with event: NSEvent) {
        // A drag that comes back to where it started is no click.
        let point = convert(event.locationInWindow, from: nil)
        if let down = downPoint, abs(point.x - down.x) + abs(point.y - down.y) >= 3 { downNote = nil }
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
        let point = convert(event.locationInWindow, from: nil)
        if let down = downPoint, abs(point.x - down.x) + abs(point.y - down.y) < 3 {
            owner?.click(on: downNote, withCommand: event.modifierFlags.contains(.command))
        }
        downPoint = nil
        downNote = nil
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

// MARK: - Edit mode: text input

extension NativeRendererView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(scrollLineUp(_:)), #selector(scrollLineDown(_:)),
             #selector(scrollToBeginningOfDocument(_:)), #selector(scrollToEndOfDocument(_:)):
            // The Go menu has the arrow keys, and takes them before
            // `keyDown`. With a caret they are the caret's: an item that
            // is off lets its key through.
            return !(isEditable && hasCaret)
        case #selector(cut(_:)):
            return isEditable && hasCaret && mdcore_has_selection(ctx)
        case #selector(paste(_:)):
            return isEditable && hasCaret
        // Also before a click in the text: a task that was set is a step.
        case #selector(undo(_:)):
            return isEditable && mdcore_can_undo(ctx)
        case #selector(redo(_:)):
            return isEditable && mdcore_can_redo(ctx)
        default:
            return true
        }
    }
}

extension NativeRendererView: DocumentEditor {
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) {
        var length = 0
        let bytes = mdcore_source(ctx, &length)
        // A document with no text has no bytes, and that is its text.
        completion(String(decoding: UnsafeRawBufferPointer(start: bytes, count: bytes == nil ? 0 : length), as: UTF8.self))
    }

    func load(markdown: String, assetBaseURL: URL?) {
        open(markdown, keepsScroll: true)
    }

    /// The core has the headings after each change, with no parse.
    func currentOutline() -> [TOCItem]? {
        MarkdownTOC.buildTree(outlineHeadings())
    }

    /// The headings of the core in order (`mdcore_outline`).
    func outlineHeadings() -> [MarkdownTOC.RawHeading] {
        var count = 0
        var titles: UnsafePointer<UInt8>?
        guard let headings = mdcore_outline(ctx, &count, &titles) else { return [] }
        return UnsafeBufferPointer(start: headings, count: count).map { heading in
            let title = titles.map {
                String(decoding: UnsafeBufferPointer(start: $0 + heading.title_start, count: heading.title_end - heading.title_start), as: UTF8.self)
            } ?? ""
            return MarkdownTOC.RawHeading(level: heading.level, title: title, sourceLine: heading.line)
        }
    }
}

extension NativeRendererView: @preconcurrency NSTextInputClient {
    /// After a change of the text by the reader.
    fileprivate func didEdit() {
        // `open` compares with the text that it showed; that is another
        // one now.
        shownMarkdown = nil
        let caretFrame = caretIndicator.frame
        caretDidMove()
        // The caret starts its blink again with each change of the text,
        // also with one that leaves it where it was (a delete of the
        // text after it).
        if caretIndicator.frame == caretFrame, caretIndicator.displayMode == .automatic {
            caretIndicator.displayMode = .automatic
        }
        contentDidChange?()
    }

    /// After the caret got another place: the view shows it there.
    private func caretDidMove() {
        // A move to a part of the page that had no layout gave it one.
        // The caret's own view gets its place with the page area.
        updatePageArea()
        keepCaretInView()
        setNeedsDraw(soon: true)
    }

    /// Puts the system's caret where the core's caret is, and shows it
    /// while the view takes the keys.
    fileprivate func updateCaretIndicator() {
        var x = 0.0, y = 0.0, height = 0.0
        let hasKeys = window?.firstResponder === self && window?.isKeyWindow == true
        let takesKeys = isEditable && hasCaret && hasKeys
        // The marks of the source at the caret show only while the view
        // takes the keys; the text of a block changes with that.
        if hasKeys != coreHasKeys {
            coreHasKeys = hasKeys
            mdcore_set_focused(ctx, hasKeys)
            setNeedsDraw()
        }
        // With text selected, the selection shows where the keys go.
        // A change of the system's caret starts its blink again and
        // makes a display pass, so only what is another value is set:
        // this runs after each key and each step of a scroll.
        guard takesKeys, !mdcore_has_selection(ctx), mdcore_caret_rect(ctx, &x, &y, &height) else {
            if caretIndicator.displayMode != .hidden { caretIndicator.displayMode = .hidden }
            return
        }
        // The page is in the space of the core's page.
        let frame = NSRect(x: x - 1, y: y, width: 2, height: height)
        if caretIndicator.frame != frame { caretIndicator.frame = frame }
        if caretIndicator.displayMode != .automatic { caretIndicator.displayMode = .automatic }
    }

    override func becomeFirstResponder() -> Bool {
        defer { updateCaretIndicator() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer {
            // The view is still first responder inside the call.
            DispatchQueue.main.async { [weak self] in self?.updateCaretIndicator() }
        }
        return super.resignFirstResponder()
    }

    /// Text from the system's text input, which gives a string or an
    /// attributed string.
    private func plainText(_ string: Any) -> String {
        (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    }

    /// Puts text in at the caret, or in the place of the text of an input
    /// method that is not final. Returns where the text starts in the
    /// source, and how many bytes the core has before it for it.
    /// `typed`: text of a key or of an input method, which goes on in
    /// one step of Undo with the text typed before it; a paste is a step
    /// of its own.
    @discardableResult
    private func put(_ text: String, typed: Bool = true) -> (start: Int, lead: Int) {
        var text = text
        let marked = markedText
        var start = marked?.start ?? mdcore_caret_offset(ctx)
        let end = start + (marked?.length ?? 0)
        markedText = nil
        guard hasCaret, start >= 0 else { return (start, 0) }
        // With all of the text of the input method taken back, the line
        // break that came with it goes too: the line is empty again.
        if text.isEmpty { start -= marked?.lead ?? 0 }
        var applied = true
        text.withUTF8 { utf8 in
            utf8.withMemoryRebound(to: CChar.self) {
                // One change of the source, also for a text that takes
                // the place of another one: of the text of the input
                // method, or of the text that is selected.
                if marked != nil {
                    // A paste in the place of the text of an input method
                    // is a step of its own, not a new form of that text.
                    if !typed { mdcore_end_undo_group(ctx) }
                    mdcore_replace_text(ctx, start, end, $0.baseAddress, $0.count)
                } else if $0.count > 0, typed {
                    applied = mdcore_insert(ctx, $0.baseAddress, $0.count)
                } else if $0.count > 0 {
                    applied = mdcore_paste(ctx, $0.baseAddress, $0.count)
                }
            }
        }
        // The core put nothing in (a selection that it has no edit for):
        // no text of an input method is in the document.
        guard applied else { return (-1, 0) }
        // The text ends at the caret. In an empty line the core put a
        // line break before it, so it starts later than `start`.
        let placed = mdcore_caret_offset(ctx) - text.utf8.count
        return (placed, marked?.lead ?? max(placed - start, 0))
    }

    /// Scrolls so that the line of the caret shows, with a little room.
    private func keepCaretInView() {
        var x = 0.0, y = 0.0, height = 0.0
        guard mdcore_caret_rect(ctx, &x, &y, &height) else { return }
        // Not against a scroll that a key started.
        endScrollAnimation()
        let room = Self.caretRoom
        let top = visiblePageRange.lowerBound, bottom = visiblePageRange.upperBound
        if y - room < top {
            scroll(toY: y - room - scrollView.contentInsets.top)
        } else if y + height + room > bottom {
            scroll(toY: y + height + room - scrollView.contentView.bounds.height)
        }
    }

    /// The text that is not final with a part of it changed: an input
    /// method can give a new form of a part of its text only. The range
    /// counts from the start of the text that is not final, in UTF-16
    /// units. With no such range, the new text is all of it.
    private func replacingMarked(_ replacementRange: NSRange, with text: String) -> String {
        guard let marked = markedText?.text, replacementRange.location != NSNotFound,
              let range = Range(replacementRange, in: marked) else { return text }
        return marked.replacingCharacters(in: range, with: text)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        put(replacingMarked(replacementRange, with: plainText(string)))
        didEdit()
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        // The text of an input method while the reader makes it: it is in
        // the document as it is typed, and each new form takes the place
        // of the one before. It has no line under it yet.
        let text = replacingMarked(replacementRange, with: plainText(string))
        // The selection that the input method has in its text counts
        // from the start of the new part.
        var selection = selectedRange
        if markedText != nil, replacementRange.location != NSNotFound {
            selection.location += replacementRange.location
        }
        let units = text.utf16.count
        selection.location = min(max(selection.location, 0), units)
        selection.length = min(max(selection.length, 0), units - selection.location)
        let (start, lead) = put(text)
        markedText = text.isEmpty || start < 0 ? nil : (start, text.utf8.count, text, selection, lead)
        didEdit()
    }

    func unmarkText() {
        markedText = nil
    }

    // The view gives the system's text input the text that is not final
    // as the only text there is: it starts at 0. The selection in it is
    // the one that the input method gave; the view's own caret shows at
    // the end of that text.

    func selectedRange() -> NSRange {
        markedText?.selection ?? NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        markedText.map { NSRange(location: 0, length: $0.text.utf16.count) } ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Where the window of an input method goes: at the caret.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var x = 0.0, y = 0.0, height = 0.0
        guard let window, mdcore_caret_rect(ctx, &x, &y, &height) else { return .zero }
        // The caret is in the space of the page; the page is the document
        // view of the scroll view.
        let inView = convert(NSRect(x: x, y: y, width: 1, height: height), from: page)
        return window.convertToScreen(convert(inView, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// The commands of the system's key bindings that move the caret,
    /// with the move of the core for each and if it selects.
    private static let caretMoves: [Selector: (move: mdcore_move, extend: Bool)] = {
        typealias R = NSResponder
        let moves: [(Selector, Selector, mdcore_move)] = [
            (#selector(R.moveLeft(_:)), #selector(R.moveLeftAndModifySelection(_:)), MDCORE_MOVE_LEFT),
            (#selector(R.moveBackward(_:)), #selector(R.moveBackwardAndModifySelection(_:)), MDCORE_MOVE_LEFT),
            (#selector(R.moveRight(_:)), #selector(R.moveRightAndModifySelection(_:)), MDCORE_MOVE_RIGHT),
            (#selector(R.moveForward(_:)), #selector(R.moveForwardAndModifySelection(_:)), MDCORE_MOVE_RIGHT),
            (#selector(R.moveWordLeft(_:)), #selector(R.moveWordLeftAndModifySelection(_:)), MDCORE_MOVE_WORD_LEFT),
            (#selector(R.moveWordBackward(_:)), #selector(R.moveWordBackwardAndModifySelection(_:)), MDCORE_MOVE_WORD_LEFT),
            (#selector(R.moveWordRight(_:)), #selector(R.moveWordRightAndModifySelection(_:)), MDCORE_MOVE_WORD_RIGHT),
            (#selector(R.moveWordForward(_:)), #selector(R.moveWordForwardAndModifySelection(_:)), MDCORE_MOVE_WORD_RIGHT),
            (#selector(R.moveUp(_:)), #selector(R.moveUpAndModifySelection(_:)), MDCORE_MOVE_UP),
            (#selector(R.moveDown(_:)), #selector(R.moveDownAndModifySelection(_:)), MDCORE_MOVE_DOWN),
            (#selector(R.moveToLeftEndOfLine(_:)), #selector(R.moveToLeftEndOfLineAndModifySelection(_:)), MDCORE_MOVE_LINE_START),
            (#selector(R.moveToBeginningOfLine(_:)), #selector(R.moveToBeginningOfLineAndModifySelection(_:)), MDCORE_MOVE_LINE_START),
            (#selector(R.moveToRightEndOfLine(_:)), #selector(R.moveToRightEndOfLineAndModifySelection(_:)), MDCORE_MOVE_LINE_END),
            (#selector(R.moveToEndOfLine(_:)), #selector(R.moveToEndOfLineAndModifySelection(_:)), MDCORE_MOVE_LINE_END),
            (#selector(R.moveToBeginningOfParagraph(_:)), #selector(R.moveToBeginningOfParagraphAndModifySelection(_:)), MDCORE_MOVE_PARAGRAPH_START),
            (#selector(R.moveToEndOfParagraph(_:)), #selector(R.moveToEndOfParagraphAndModifySelection(_:)), MDCORE_MOVE_PARAGRAPH_END),
            (#selector(R.moveToBeginningOfDocument(_:)), #selector(R.moveToBeginningOfDocumentAndModifySelection(_:)), MDCORE_MOVE_DOCUMENT_START),
            (#selector(R.moveToEndOfDocument(_:)), #selector(R.moveToEndOfDocumentAndModifySelection(_:)), MDCORE_MOVE_DOCUMENT_END),
        ]
        var table: [Selector: (move: mdcore_move, extend: Bool)] = [:]
        for (plain, selecting, move) in moves {
            table[plain] = (move, false)
            table[selecting] = (move, true)
        }
        // With Option and Shift, up and down select to the two ends of
        // the paragraph.
        table[#selector(R.moveParagraphBackwardAndModifySelection(_:))] = (MDCORE_MOVE_PARAGRAPH_START, true)
        table[#selector(R.moveParagraphForwardAndModifySelection(_:))] = (MDCORE_MOVE_PARAGRAPH_END, true)
        return table
    }()

    /// The commands of the system's key bindings that take text out,
    /// with the move of the core that says how much.
    private static let deleteMoves: [Selector: mdcore_move] = {
        typealias R = NSResponder
        return [
            #selector(R.deleteBackward(_:)): MDCORE_MOVE_LEFT,
            #selector(R.deleteBackwardByDecomposingPreviousCharacter(_:)): MDCORE_MOVE_LEFT,
            #selector(R.deleteForward(_:)): MDCORE_MOVE_RIGHT,
            #selector(R.deleteWordBackward(_:)): MDCORE_MOVE_WORD_LEFT,
            #selector(R.deleteWordForward(_:)): MDCORE_MOVE_WORD_RIGHT,
            #selector(R.deleteToBeginningOfLine(_:)): MDCORE_MOVE_LINE_START,
            #selector(R.deleteToEndOfLine(_:)): MDCORE_MOVE_LINE_END,
            #selector(R.deleteToBeginningOfParagraph(_:)): MDCORE_MOVE_PARAGRAPH_START,
            #selector(R.deleteToEndOfParagraph(_:)): MDCORE_MOVE_PARAGRAPH_END,
        ]
    }()

    /// The text that Control-K took out last, for Control-Y. One for the
    /// app, as the system's text views have it.
    private static var killed = ""

    override func doCommand(by selector: Selector) {
        if isEditable, hasCaret, let move = Self.caretMoves[selector] {
            moveCaret(move.move, extend: move.extend)
            return
        }
        if isEditable, hasCaret, let move = Self.deleteMoves[selector] {
            delete(to: move, keepsText: selector == #selector(NSResponder.deleteToEndOfParagraph(_:)))
            return
        }
        // The other commands that the view has (delete, a new line, the
        // scroll keys). Each one that it does not have does nothing.
        if responds(to: selector) {
            perform(selector, with: nil)
        }
    }

    /// Moves the caret as a key says, and keeps it in view.
    private func moveCaret(_ move: mdcore_move, extend: Bool) {
        if mdcore_caret_move(ctx, move, extend) {
            caretDidMove()
        } else if move == MDCORE_MOVE_DOWN, !extend, mdcore_paragraph_below(ctx) {
            // Down from code that ends the document: the core made an
            // empty paragraph after it, the only place below such code.
            didEdit()
        }
    }

    /// The text that is selected.
    private var selectedText: String? {
        var length = 0
        guard let bytes = mdcore_selection_text(ctx, &length), length > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
    }

    /// Takes out the text that is selected, or the text from the caret
    /// to where a move goes. `keepsText`: for Control-Y.
    private func delete(to move: mdcore_move, keepsText: Bool = false) {
        markedText = nil
        if mdcore_delete(ctx, move) {
            if keepsText {
                // For Control-Y: the bytes of the source that went, from
                // the core, which knows the marks that stayed.
                var length = 0
                if let bytes = mdcore_deleted_text(ctx, &length), length > 0 {
                    Self.killed = String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
                }
            }
            didEdit()
        } else {
            // A selection that the core takes no text out for stays.
            caretDidMove()
        }
    }

    private func deleteLines() {
        markedText = nil
        if mdcore_delete_lines(ctx) { didEdit() }
    }

    @objc func cut(_ sender: Any?) {
        // The text goes to the pasteboard only when it went out of the
        // document: the core has no edit for some selections.
        guard isEditable, hasCaret, let text = selectedText else { return }
        markedText = nil
        guard mdcore_delete(ctx, MDCORE_MOVE_LEFT) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didEdit()
    }

    override func yank(_ sender: Any?) {
        guard isEditable, hasCaret, !Self.killed.isEmpty else { return }
        markedText = nil
        put(Self.killed, typed: false)
        didEdit()
    }

    override func transpose(_ sender: Any?) {
        guard isEditable, hasCaret else { return }
        markedText = nil
        if mdcore_transpose(ctx) { didEdit() }
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable, hasCaret else { return }
        // What Return is depends on the block of the caret (a new
        // paragraph, a new list item, a new line of code): the core
        // knows it.
        markedText = nil
        mdcore_insert_break(ctx)
        didEdit()
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditable { cancelRequested?() }
    }

    @objc func paste(_ sender: Any?) {
        guard isEditable, hasCaret, let text = NSPasteboard.general.string(forType: .string) else { return }
        put(text, typed: false)
        didEdit()
    }

    // The core keeps the changes of the reader (`mdcore_undo`): the
    // view's own Undo and Redo, before the window's undo manager.

    @objc func undo(_ sender: Any?) {
        stepHistory(redo: false)
    }

    @objc func redo(_ sender: Any?) {
        stepHistory(redo: true)
    }

    private func stepHistory(redo: Bool) {
        guard isEditable else { return }
        // The text of an input method that is not final is a part of the
        // last change: the input method lets it go first, while the view
        // still knows its range (an input method can answer with the
        // text as final, which then takes the place of that range).
        if markedText != nil {
            inputContext?.discardMarkedText()
            markedText = nil
        }
        if redo ? mdcore_redo(ctx) : mdcore_undo(ctx) { didEdit() }
    }
}
