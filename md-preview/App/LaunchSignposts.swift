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
