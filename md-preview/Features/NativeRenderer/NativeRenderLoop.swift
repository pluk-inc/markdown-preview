//
//  NativeRenderLoop.swift
//  md-preview
//
//  The thread that draws the frames of one native renderer view.
//
//  A `CAMetalDisplayLink` on the thread's run loop calls it one time for
//  each refresh of the view's display, with the drawable for that frame.
//  That is the full rate of the display: on a 120 Hz display the links that
//  AppKit gives a view, a window, or a screen fire only 60 times a second,
//  whatever rate they are asked for. While such a link is on the layer, it is
//  the only source of drawables, so every frame is drawn in its callback.
//
//  The main thread only says what it wants: a frame at a scroll offset, or a
//  scroll to an offset over a short time. The thread draws the newest
//  request, so a busy main thread does not hold a frame, and the link is
//  paused while nothing is wanted.
//

import AppKit
import MDCore
import QuartzCore

nonisolated final class NativeRenderLoop: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    /// Called on the main thread after each frame. `animatedY` is where a
    /// scroll that this loop animates is now; `animationEnded` is true for
    /// the frame that reached its end.
    nonisolated(unsafe) var didDraw: (@MainActor (_ animatedY: Double?, _ animationEnded: Bool) -> Void)?

    private static let scrollAnimationDuration: CFTimeInterval = 0.2

    nonisolated(unsafe) private let ctx: UnsafeMutableRawPointer?
    nonisolated(unsafe) private var runLoop: CFRunLoop!
    /// Used on the render thread only.
    nonisolated(unsafe) private var link: CAMetalDisplayLink!
    private let ended = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    // Under the lock.
    nonisolated(unsafe) private var scrollY = 0.0
    nonisolated(unsafe) private var wantsFrame = false
    nonisolated(unsafe) private var isPaused = true
    nonisolated(unsafe) private var animation: (from: Double, to: Double, start: CFTimeInterval)?
    nonisolated(unsafe) private var waiters: [DispatchSemaphore] = []

    /// Starts the thread. `ctx` is the core's renderer for `layer`; it must
    /// live until `stop()` returned.
    init(layer: CAMetalLayer, ctx: UnsafeMutableRawPointer?) {
        self.ctx = ctx
        super.init()
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.isPaused = true
            link.add(to: .current, forMode: .default)
            self.link = link
            runLoop = CFRunLoopGetCurrent()
            started.signal()
            CFRunLoopRun()
            link.invalidate()
            ended.signal()
        }
        thread.name = "md-preview.native-renderer"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    /// Ends the thread and waits for it. No frame and no block runs after
    /// this returned. Any thread but the render thread.
    func stop() {
        perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
        ended.wait()
        lock.lock()
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        waiting.forEach { $0.signal() }
    }

    /// Runs `work` on the render thread, between frames.
    func perform(_ work: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Asks for a frame at this scroll offset at the next refresh. A newer
    /// request replaces one that is not drawn yet.
    func requestFrame(at y: Double) {
        lock.lock()
        scrollY = y
        wantsFrame = true
        let wake = isPaused
        isPaused = false
        lock.unlock()
        if wake { resume() }
    }

    /// Runs `before` on the render thread, then draws a frame at this
    /// offset in the next refresh, and waits for it. For a frame that must
    /// be there with the window's: the first one, and one for a new size.
    /// Returns false when no frame came in `timeout`, which is so for a
    /// window that is not on screen.
    @discardableResult
    func frameNow(at y: Double, timeout: TimeInterval = 0.1, before: (@Sendable () -> Void)? = nil) -> Bool {
        let done = DispatchSemaphore(value: 0)
        perform { [self] in
            before?()
            lock.lock()
            scrollY = y
            wantsFrame = true
            isPaused = false
            waiters.append(done)
            lock.unlock()
            link.isPaused = false
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Scrolls from one offset to another over a short time, as the
    /// system's views do for the keyboard. Each frame of it is reported
    /// through `didDraw`.
    func animateScroll(from: Double, to: Double) {
        lock.lock()
        animation = (from, to, CACurrentMediaTime())
        let wake = isPaused
        isPaused = false
        lock.unlock()
        if wake { resume() }
    }

    func cancelScrollAnimation() {
        lock.lock()
        animation = nil
        lock.unlock()
    }

    private func resume() {
        perform { [self] in link.isPaused = false }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        lock.lock()
        var animatedY: Double?
        var animationEnded = false
        if let animation {
            let progress = min(max((update.targetTimestamp - animation.start) / Self.scrollAnimationDuration, 0), 1)
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
        guard wantsFrame else {
            // Nothing to draw: no more calls until a request comes.
            isPaused = true
            link.isPaused = true
            lock.unlock()
            return
        }
        wantsFrame = false
        let y = scrollY
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()

        autoreleasepool {
            mdcore_draw(ctx, y, Unmanaged.passUnretained(update.drawable).toOpaque())
        }
        waiting.forEach { $0.signal() }
        DispatchQueue.main.async { [weak self] in
            self?.didDraw?(animatedY, animationEnded)
        }
    }
}
