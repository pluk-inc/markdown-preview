import Cocoa

enum LaunchReason {
    /// Check the launch reason, not whether the app is registered as a login
    /// item: a registered app can still be opened manually. A missing event
    /// (for example, an Xcode launch) preserves the normal prompt behavior.
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }
}
