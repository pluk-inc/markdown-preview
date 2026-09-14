import AppKit
import ObjectiveC

/// Xcode 27's DVTWorkspaceBackgroundView colors the NSScrollPocket instances
/// in NSToolbar._containingWindow when AppKit moves the toolbar to a separate
/// full-screen window. These are private AppKit hooks, observed on macOS 26.
/// Keep the bridge optional and local to one document; never scan NSApp.windows.
@MainActor
final class FullscreenToolbarTheme {
    private struct OriginalState {
        weak var pocket: NSView?
        let solid: Bool
        let color: NSColor?
    }

    private var originals: [ObjectIdentifier: OriginalState] = [:]
    private static let containingWindow = NSSelectorFromString("_containingWindow")
    private static let captureColor = NSSelectorFromString("captureColor")
    private static let setCaptureColor = NSSelectorFromString("setCaptureColor:")
    private static let prefersSolid = NSSelectorFromString("prefersSolidColorHardPocket")
    private static let setPrefersSolid = NSSelectorFromString("setPrefersSolidColorHardPocket:")

    func update(window: NSWindow, color: NSColor?) {
        guard #available(macOS 26.0, *),
              color != nil,
              window.styleMask.contains(.fullScreen),
              window.tabGroup?.selectedWindow == nil || window.tabGroup?.selectedWindow === window,
              let toolbar = window.toolbar,
              Self.supports(toolbar, Self.containingWindow, result: "@", arguments: []),
              let host = Self.object(toolbar, Self.containingWindow) as? NSWindow,
              host !== window,
              let root = host.contentView else {
            restore()
            return
        }
        apply(to: root, color: color)
    }

    /// Also used by the AppKit tests to exercise real scroll pockets without
    /// moving a user's window into a different Space.
    func apply(to root: NSView, color: NSColor?) {
        guard #available(macOS 26.0, *), let color,
              let pocketClass = NSClassFromString("NSScrollPocket") else {
            restore()
            return
        }
        var pockets: [NSView] = []
        func visit(_ view: NSView) {
            if view.isKind(of: pocketClass) {
                if Self.supportsPocket(view) { pockets.append(view) }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        let current = Set(pockets.map(ObjectIdentifier.init))
        // A toolbar can be rebuilt or reparented during full-screen/tab changes.
        for id in Array(originals.keys) where !current.contains(id) {
            restore(id)
        }
        for pocket in pockets {
            let id = ObjectIdentifier(pocket)
            let solid = Self.bool(pocket, Self.prefersSolid)
            let existingColor = Self.object(pocket, Self.captureColor) as? NSColor
            if originals[id]?.pocket !== pocket {
                originals[id] = OriginalState(pocket: pocket, solid: solid, color: existingColor)
            }
            // windowDidUpdate can run repeatedly; avoid causing another display
            // cycle when AppKit has already kept the values we want.
            if !solid { Self.setBool(pocket, Self.setPrefersSolid, true) }
            if existingColor != color { Self.setObject(pocket, Self.setCaptureColor, color) }
        }
    }

    func restore() {
        for id in Array(originals.keys) { restore(id) }
    }

    private func restore(_ id: ObjectIdentifier) {
        guard let saved = originals.removeValue(forKey: id),
              let pocket = saved.pocket, Self.supportsPocket(pocket) else { return }
        Self.setBool(pocket, Self.setPrefersSolid, saved.solid)
        Self.setObject(pocket, Self.setCaptureColor, saved.color)
    }

    private static func supportsPocket(_ pocket: NSView) -> Bool {
        supports(pocket, captureColor, result: "@", arguments: [])
            && supports(pocket, setCaptureColor, result: "v", arguments: ["@"])
            && supports(pocket, prefersSolid, result: "B", arguments: [])
            && supports(pocket, setPrefersSolid, result: "v", arguments: ["B"])
    }

    /// A selector existing is insufficient when calling a typed IMP: decline
    /// the workaround if a future AppKit changes any of these signatures.
    private static func supports(_ target: NSObject, _ selector: Selector,
                                 result: String, arguments: [String]) -> Bool {
        guard target.responds(to: selector),
              let method = class_getInstanceMethod(type(of: target), selector),
              method_getNumberOfArguments(method) == arguments.count + 2 else { return false }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return false }
        for (index, expected) in arguments.enumerated() {
            guard let argument = method_copyArgumentType(method, UInt32(index + 2)) else { return false }
            defer { free(argument) }
            guard String(cString: argument) == expected else { return false }
        }
        return true
    }

    private static func object(_ target: NSObject, _ selector: Selector) -> AnyObject? {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        return unsafeBitCast(target.method(for: selector), to: Getter.self)(target, selector)?.takeUnretainedValue()
    }

    private static func bool(_ target: NSObject, _ selector: Selector) -> Bool {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(target.method(for: selector), to: Getter.self)(target, selector)
    }

    private static func setObject(_ target: NSObject, _ selector: Selector, _ value: NSColor?) {
        typealias Setter = @convention(c) (AnyObject, Selector, NSColor?) -> Void
        unsafeBitCast(target.method(for: selector), to: Setter.self)(target, selector, value)
    }

    private static func setBool(_ target: NSObject, _ selector: Selector, _ value: Bool) {
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(target.method(for: selector), to: Setter.self)(target, selector, value)
    }
}
