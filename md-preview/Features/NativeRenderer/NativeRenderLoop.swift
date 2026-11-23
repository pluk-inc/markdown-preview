//
//  NativeRenderLoop.swift
//  md-preview
//
//  Draws the frames of one native renderer view, one for each refresh of
//  its display, off the main thread.
//
//  The clock is a `CVDisplayLink`. It is deprecated since macOS 15 in favor
//  of the display links that AppKit gives a view, a window, or a screen, but
//  on a 120 Hz display those fire only 60 times a second, whatever rate they
//  are asked for (measured: 64 against 130 a second). `CAMetalDisplayLink`
//  has the full rate too, but most of its frames did not reach the screen
//  for a window that is not in front, and with a transparent layer its
//  callbacks stopped.
//
//  The main thread only says what it wants: a frame at a scroll offset, or a
//  scroll to an offset over a short time. The link's thread draws the newest
//  request, so a busy main thread does not hold a frame. The link runs only
//  while something is wanted. All requests come from the main thread.
//

import AppKit
import CoreVideo
import MDCore

nonisolated final class NativeRenderLoop: @unchecked Sendable {
    /// A frame of a scroll that this loop animates: which scroll (the
    /// number from `animateScroll`), where it is now, and if this frame
    /// reached its end.
    struct ScrollStep: Sendable {
        let scroll: Int
        let y: Double
        let isLast: Bool
    }

    /// Called on the main thread after a frame that was a step of a scroll
    /// or that made the page taller.
    nonisolated(unsafe) var didDraw: (@MainActor (ScrollStep?) -> Void)?

    private static let scrollAnimationDuration: CFTimeInterval = 0.2
    /// Refreshes with nothing to draw before the link stops. A stop and a
    /// start cost more than a few empty calls, and a scroll asks for frames
    /// in a row.
    private static let idleTicksBeforeStop = 30

    nonisolated(unsafe) private let ctx: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var link: CVDisplayLink?
    /// Layout steps, and frames that the main thread waits for. The core
    /// lets one draw at a time run, so these and the link's frames do not
    /// overlap.
    private let queue = DispatchQueue(label: "md-preview.native-renderer", qos: .userInteractive)

    private let lock = NSLock()
    // Under the lock.
    nonisolated(unsafe) private var scrollY = 0.0
    nonisolated(unsafe) private var wantsFrame = false
    nonisolated(unsafe) private var isRunning = false
    nonisolated(unsafe) private var idleTicks = 0
    nonisolated(unsafe) private var animation: (scroll: Int, from: Double, to: Double, start: CFTimeInterval)?
    nonisolated(unsafe) private var scrollCount = 0
    /// True from the point a frame of the link took its offset until it is
    /// drawn.
    nonisolated(unsafe) private var tickInFlight = false
    nonisolated(unsafe) private var lastHeight = 0.0

    /// `ctx` is the core's renderer; it must live until `stop()` returned.
    init(ctx: UnsafeMutableRawPointer?) {
        self.ctx = ctx
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        self.link = link
        if let link {
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.tick()
                return kCVReturnSuccess
            }
        }
    }

    /// The display that the view is on now. The link follows its refresh.
    func setDisplay(_ display: CGDirectDisplayID) {
        if let link { CVDisplayLinkSetCurrentCGDisplay(link, display) }
    }

    /// Ends the frames and waits for the one in progress and for the work
    /// in the queue. Nothing of this loop touches the core after it
    /// returned. Not from the link's own thread.
    func stop() {
        lock.lock()
        isRunning = false
        wantsFrame = false
        animation = nil
        lock.unlock()
        // Returns when no callback runs any more.
        if let link { CVDisplayLinkStop(link) }
        queue.sync {}
    }

    /// Runs `work` off the main thread, between frames.
    func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Asks for a frame at this scroll offset at the next refresh. A newer
    /// request replaces one that is not drawn yet.
    func requestFrame(at y: Double) {
        lock.lock()
        scrollY = y
        wantsFrame = true
        lock.unlock()
        start()
    }

    /// Runs `before`, then draws a frame at this offset, and waits for it.
    /// For a frame that must be there with the window's: the first one, and
    /// one for a new size.
    func frameNow(at y: Double, before: (@Sendable () -> Void)? = nil) {
        lock.lock()
        scrollY = y
        let olderFrameInFlight = tickInFlight
        lock.unlock()
        queue.sync { [ctx] in
            before?()
            // On this thread (the queue runs a waited-for block on the
            // thread that waits), with its transaction: the frame shows
            // with the window's new size and with the views that the
            // caller moves after it, not one step before them.
            autoreleasepool { mdcore_draw_with_window(ctx, y) }
        }
        // A frame of the link that took an older offset can be drawn after
        // this one. One more frame then makes the newest offset the last
        // one on screen.
        if olderFrameInFlight { requestFrame(at: y) }
    }

    /// Scrolls from one offset to another over a short time, as the
    /// system's views do for the keyboard. Each frame of it is reported
    /// through `didDraw`, with the number that this returns: a frame of a
    /// scroll that another one replaced can come after it.
    func animateScroll(from: Double, to: Double) -> Int {
        lock.lock()
        scrollCount += 1
        let scroll = scrollCount
        animation = (scroll, from, to, CACurrentMediaTime())
        lock.unlock()
        start()
        return scroll
    }

    func cancelScrollAnimation() {
        lock.lock()
        animation = nil
        lock.unlock()
    }

    private func start() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = true
        idleTicks = 0
        lock.unlock()
        guard let link else {
            // No display link (it could not be made): draw what is wanted
            // one time, without a clock.
            queue.async { [self] in tick() }
            return
        }
        if !wasRunning { CVDisplayLinkStart(link) }
    }

    /// One refresh of the display, on the link's thread.
    private func tick() {
        lock.lock()
        var step: ScrollStep?
        if let animation {
            // Without a clock there are no steps: the scroll goes to its end.
            let progress = link == nil
                ? 1 : min(max((CACurrentMediaTime() - animation.start) / Self.scrollAnimationDuration, 0), 1)
            // Ease out: fast at the start, slow into the end.
            let eased = 1 - pow(1 - progress, 3)
            scrollY = animation.from + (animation.to - animation.from) * eased
            step = ScrollStep(scroll: animation.scroll, y: scrollY, isLast: progress >= 1)
            wantsFrame = true
            if progress >= 1 { self.animation = nil }
        }
        guard wantsFrame, isRunning else {
            idleTicks += 1
            let stops = isRunning && idleTicks == Self.idleTicksBeforeStop
            lock.unlock()
            // A stop waits for this callback, so it cannot be made in it.
            // It is made on the main thread, where the requests come from:
            // none can come between its check and the stop.
            if stops { DispatchQueue.main.async { [weak self] in self?.stopIfIdle() } }
            return
        }
        wantsFrame = false
        idleTicks = 0
        let y = scrollY
        tickInFlight = true
        lock.unlock()

        autoreleasepool { mdcore_draw(ctx, y) }
        // A draw can lay out more of the page. Read here, where a wait for
        // the core holds nothing.
        let height = mdcore_content_height(ctx)
        lock.lock()
        tickInFlight = false
        let heightChanged = height != lastHeight
        lastHeight = height
        lock.unlock()
        // The main thread has work after a frame only for a step of a
        // scroll or a page that grew: no hop for the other frames.
        guard step != nil || heightChanged else { return }
        DispatchQueue.main.async { [weak self] in
            self?.didDraw?(step)
        }
    }

    /// On the main thread.
    private func stopIfIdle() {
        lock.lock()
        let idle = isRunning && !wantsFrame && animation == nil
        if idle { isRunning = false } else { idleTicks = 0 }
        lock.unlock()
        if idle, let link { CVDisplayLinkStop(link) }
    }
}
