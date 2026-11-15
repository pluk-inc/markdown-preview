import Cocoa
import XCTest
@testable import MarkdownHelpers

final class LaunchReasonTests: XCTestCase {
    private func event(eventClass: AEEventClass = AEEventClass(kCoreEventClass),
                       id: AEEventID = AEEventID(kAEOpenApplication),
                       reason: OSType? = OSType(keyAELaunchedAsLogInItem)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass, eventID: id, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            event.setParam(NSAppleEventDescriptor(enumCode: reason),
                           forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    func testLoginItemLaunch() {
        XCTAssertTrue(LaunchReason.isLoginItemLaunch(event()))
    }

    func testMissingEventKeepsNormalLaunchBehavior() {
        XCTAssertFalse(LaunchReason.isLoginItemLaunch(nil))
    }

    func testMissingReasonKeepsNormalLaunchBehavior() {
        XCTAssertFalse(LaunchReason.isLoginItemLaunch(event(reason: nil)))
    }

    func testDifferentEventClassIsNotALoginLaunch() {
        XCTAssertFalse(LaunchReason.isLoginItemLaunch(event(eventClass: 0)))
    }

    func testReopenEventIsNotALoginLaunch() {
        XCTAssertFalse(LaunchReason.isLoginItemLaunch(event(id: AEEventID(kAEReopenApplication))))
    }

    func testServiceLaunchIsNotALoginLaunch() {
        XCTAssertFalse(LaunchReason.isLoginItemLaunch(event(reason: OSType(keyAELaunchedAsServiceItem))))
    }
}
