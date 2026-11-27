//
//  LaunchSignposts.swift
//  md-preview
//
//  os_signpost intervals for the launch path. Visible in Instruments
//  (os_signpost instrument, subsystem doc.md-preview.launch) and cheap
//  enough to stay in Release builds.
//

import Foundation
import os

nonisolated enum LaunchSignposts {
    static let signposter = OSSignposter(subsystem: "doc.md-preview.launch", category: "launch")

    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// Events that wait until the frame that is drawn now is committed to
    /// the window server, which is when it can come on screen.
    @MainActor private static var eventsAfterCommit: [StaticString] = []

    /// Emits `name` when the changes of this turn of the run loop are
    /// committed: at the end of the turn, or at `emitCommittedEvents()`
    /// when the caller commits before that.
    @MainActor
    static func eventAfterCommit(_ name: StaticString) {
        eventsAfterCommit.append(name)
        guard eventsAfterCommit.count == 1 else { return }
        // Core Animation commits the transaction of a turn from an
        // observer of order 2,000,000; this one runs right after it.
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, false, 2_000_001) { _, _ in
            MainActor.assumeIsolated { emitCommittedEvents() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// For a caller that committed the changes itself (`CATransaction.flush()`).
    @MainActor
    static func emitCommittedEvents() {
        for name in eventsAfterCommit { event(name) }
        eventsAfterCommit.removeAll()
    }

    /// An open interval for callers that cannot wrap their work in a
    /// closure (`defer` across an early return, or `init`).
    struct Token {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    static func begin(_ name: StaticString) -> Token {
        Token(name: name, state: signposter.beginInterval(name))
    }

    static func end(_ token: Token) {
        signposter.endInterval(token.name, token.state)
    }
}
