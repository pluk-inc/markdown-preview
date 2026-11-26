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
    /// The frames when there is no display link, and the wait for them
    /// at the end.
    private let queue = DispatchQueue(label: "md-preview.native-renderer", qos: .userInteractive)

    private let lock = NSLock()
    // Under the lock.
    nonisolated(unsafe) private var scrollY = 0.0
    nonisolated(unsafe) private var wantsFrame = false
    nonisolated(unsafe) private var isRunning = false
    nonisolated(unsafe) private var idleTicks = 0
    nonisolated(unsafe) private var animation: (scroll: Int, from: Double, to: Double, start: CFTimeInterval, toFixedPlace: Bool)?
    nonisolated(unsafe) private var scrollCount = 0
    /// True from the point a frame of the link took its offset until it is
    /// drawn.
    nonisolated(unsafe) private var tickInFlight = false
    /// When the last frame was drawn.
    nonisolated(unsafe) private var lastFrameTime: CFTimeInterval = 0
    /// A frame that does not wait for the refresh is in the queue: no
    /// second one goes there before it took its frame.
    nonisolated(unsafe) private var earlyQueued = false
    /// The time of one refresh of the display that the view is on.
    nonisolated(unsafe) private var refreshPeriod: CFTimeInterval = 1.0 / 60
    /// Held for all of a frame of `tick`, from before it takes its offset:
    /// a frame of the link and a frame that did not wait for it do not
    /// draw at the same time, and the one that takes the newer offset
    /// draws last.
    private let frameLock = NSLock()
    nonisolated(unsafe) private var lastRevision = -1

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
        guard let link else { return }
        CVDisplayLinkSetCurrentCGDisplay(link, display)
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        guard period.flags & Int32(CVTimeFlags.isIndefinite.rawValue) == 0, period.timeValue > 0, period.timeScale > 0 else { return }
        lock.lock()
        refreshPeriod = Double(period.timeValue) / Double(period.timeScale)
        lock.unlock()
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

    /// Asks for a frame at this scroll offset at the next refresh. A newer
    /// request replaces one that is not drawn yet.
    ///
    /// `soon`: the frame does not wait for the refresh, for a key, which
    /// the reader then sees up to one refresh sooner. It is drawn on the
    /// queue of the loop, not on the main thread, which a wait for a
    /// drawable would stop. The layer has a few drawables, and each is
    /// free again after the refresh that showed it, so there is no more
    /// than one such frame for each refresh: when a frame was drawn less
    /// than one refresh before, or one is in progress, or a scroll has its
    /// steps from the clock, the frame waits for the refresh.
    func requestFrame(at y: Double, soon: Bool = false) {
        lock.lock()
        scrollY = y
        wantsFrame = true
        let early = soon && !earlyQueued && canDrawEarly
        if early { earlyQueued = true }
        lock.unlock()
        // The frame that does not wait needs no clock.
        if early { queue.async { [self] in tick(early: true) } } else { start() }
    }

    /// A frame can be drawn with no wait for the refresh: no frame was
    /// drawn in the last refresh, none is in progress, and no scroll has
    /// its steps from the clock. Under the lock.
    private var canDrawEarly: Bool {
        animation == nil && !tickInFlight && CACurrentMediaTime() - lastFrameTime >= refreshPeriod
    }

    /// Runs `before`, then draws a frame at this offset, or at the one that
    /// `before` returns (the layout that it made can have the reader's
    /// place at another offset). Returns the offset of the frame. On the main
    /// thread. For a frame that must be there with the window's: the first
    /// one, and one for a new size. It goes to the screen with the main
    /// thread's transaction, so it shows with the window's new size and
    /// with the views that the caller moves after it, not one step before
    /// them. The core lets one call at a time work, so this waits for a
    /// frame of the link that is in progress.
    @discardableResult
    func frameNow(at offset: Double, before: (() -> Double?)? = nil) -> Double {
        dispatchPrecondition(condition: .onQueue(.main))
        // No frame of the link between the new layout and the offset that
        // it gives: it would show that layout at the old offset. The frame
        // below replaces each request that waits.
        lock.lock()
        wantsFrame = false
        lock.unlock()
        let y = before?() ?? offset
        lock.lock()
        scrollY = y
        let olderFrameInFlight = tickInFlight
        lock.unlock()
        autoreleasepool { mdcore_draw_with_window(ctx, y) }
        lock.lock()
        lastFrameTime = CACurrentMediaTime()
        lock.unlock()
        // A frame of the link that took an older offset can be drawn after
        // this one. One more frame then makes the newest offset the last
        // one on screen.
        if olderFrameInFlight { requestFrame(at: y) }
        return y
    }

    /// Scrolls from one offset to another over a short time, as the
    /// system's views do for the keyboard. Each frame of it is reported
    /// through `didDraw`, with the number that this returns: a frame of a
    /// scroll that another one replaced can come after it.
    ///
    /// `toFixedPlace`: the scroll goes to a place of the document (its
    /// top, its end), not a distance. A part that a frame lays out on the
    /// way then leaves that place where it is (`mdcore_draw_toward`).
    func animateScroll(from: Double, to: Double, toFixedPlace: Bool) -> Int {
        lock.lock()
        scrollCount += 1
        let scroll = scrollCount
        animation = (scroll, from, to, CACurrentMediaTime(), toFixedPlace)
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

    /// One refresh of the display, on the link's thread; or a frame that
    /// does not wait for one (`early`), on the queue. The two can come at
    /// the same time: one of them takes the frame that is wanted, and the
    /// other one waits for it to be drawn first (`frameLock`).
    private func tick(early: Bool = false) {
        frameLock.lock()
        defer { frameLock.unlock() }
        lock.lock()
        if early {
            earlyQueued = false
            // A frame of the link was drawn, or a scroll started, while
            // this one was in the queue: what is wanted now waits for
            // the refresh, as a request that comes now does.
            if wantsFrame, !canDrawEarly {
                lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.start() }
                return
            }
        }
        var step: ScrollStep?
        var target: Double?
        if let animation {
            // Without a clock there are no steps: the scroll goes to its end.
            let progress = link == nil
                ? 1 : min(max((CACurrentMediaTime() - animation.start) / Self.scrollAnimationDuration, 0), 1)
            // Ease out: fast at the start, slow into the end.
            let eased = 1 - pow(1 - progress, 3)
            scrollY = animation.from + (animation.to - animation.from) * eased
            step = ScrollStep(scroll: animation.scroll, y: scrollY, isLast: progress >= 1)
            if animation.toFixedPlace { target = animation.to }
            wantsFrame = true
            if progress >= 1 { self.animation = nil }
        }
        // A frame that does not wait is wanted with no clock that runs;
        // after `stop` no frame is wanted.
        guard wantsFrame, isRunning || early else {
            if early {
                lock.unlock()
                return
            }
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

        autoreleasepool {
            if let target { mdcore_draw_toward(ctx, y, target) } else { mdcore_draw(ctx, y) }
        }
        // A draw can lay out a part of the page. Read here, where a wait
        // for the core holds nothing.
        let revision = mdcore_layout_revision(ctx)
        lock.lock()
        tickInFlight = false
        lastFrameTime = CACurrentMediaTime()
        let layoutChanged = revision != lastRevision
        lastRevision = revision
        lock.unlock()
        // The main thread has work after a frame only for a step of a
        // scroll or a layout that changed: no hop for the other frames.
        guard step != nil || layoutChanged else { return }
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
