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
//  while something is wanted.
//

import AppKit
import CoreVideo
import MDCore

nonisolated final class NativeRenderLoop: @unchecked Sendable {
    /// Called on the main thread after each frame. `animatedY` is where a
    /// scroll that this loop animates is now; `animationEnded` is true for
    /// the frame that reached its end.
    nonisolated(unsafe) var didDraw: (@MainActor (_ animatedY: Double?, _ animationEnded: Bool) -> Void)?

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
    nonisolated(unsafe) private var animation: (from: Double, to: Double, start: CFTimeInterval)?

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
        wantsFrame = false
        lock.unlock()
        queue.sync { [ctx] in
            before?()
            autoreleasepool { mdcore_draw(ctx, y) }
        }
    }

    /// Scrolls from one offset to another over a short time, as the
    /// system's views do for the keyboard. Each frame of it is reported
    /// through `didDraw`.
    func animateScroll(from: Double, to: Double) {
        lock.lock()
        animation = (from, to, CACurrentMediaTime())
        lock.unlock()
        start()
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
        if !wasRunning, let link { CVDisplayLinkStart(link) }
    }

    /// One refresh of the display, on the link's thread.
    private func tick() {
        lock.lock()
        var animatedY: Double?
        var animationEnded = false
        if let animation {
            let progress = min(max((CACurrentMediaTime() - animation.start) / Self.scrollAnimationDuration, 0), 1)
            // Ease out: fast at the start, slow into the end.
            let eased = 1 - pow(1 - progress, 3)
            scrollY = animation.from + (animation.to - animation.from) * eased
            animatedY = scrollY
            wantsFrame = true
            if progress >= 1 {
                self.animation = nil
                animationEnded = true
            }
        }
        guard wantsFrame, isRunning else {
            idleTicks += 1
            let stops = isRunning && idleTicks >= Self.idleTicksBeforeStop
            if stops { isRunning = false }
            lock.unlock()
            // A stop waits for this callback, so it cannot be made in it.
            if stops { queue.async { [self] in stopIfIdle() } }
            return
        }
        wantsFrame = false
        idleTicks = 0
        let y = scrollY
        lock.unlock()

        autoreleasepool { mdcore_draw(ctx, y) }
        DispatchQueue.main.async { [weak self] in
            self?.didDraw?(animatedY, animationEnded)
        }
    }

    private func stopIfIdle() {
        lock.lock()
        let idle = !isRunning
        lock.unlock()
        guard idle, let link else { return }
        CVDisplayLinkStop(link)
        // A request can have come in between: it found the link "running"
        // just before the stop, or started it just before. Start it again
        // for that request.
        lock.lock()
        let wanted = isRunning || wantsFrame || animation != nil
        if wanted { isRunning = true; idleTicks = 0 }
        lock.unlock()
        if wanted { CVDisplayLinkStart(link) }
    }
}
