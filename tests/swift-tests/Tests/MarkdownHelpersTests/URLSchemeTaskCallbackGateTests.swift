import XCTest

@testable import MarkdownHelpers

final class URLSchemeTaskCallbackGateTests: XCTestCase {
    func testStopPreventsLaterCallbacks() {
        let gate = URLSchemeTaskCallbackGate()
        gate.stop()

        var callbackRan = false
        gate.performIfActive { callbackRan = true }

        XCTAssertFalse(callbackRan)
    }

    func testStopWaitsForCurrentCallbackAndPreventsNextCallback() {
        let gate = URLSchemeTaskCallbackGate()
        let callbackStarted = DispatchSemaphore(value: 0)
        let allowCallbackToFinish = DispatchSemaphore(value: 0)
        let stopStarted = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            gate.performIfActive {
                callbackStarted.signal()
                allowCallbackToFinish.wait()
            }
        }

        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            stopStarted.signal()
            gate.stop()
            stopReturned.signal()
        }

        XCTAssertEqual(stopStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 0.05), .timedOut)
        allowCallbackToFinish.signal()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)

        var laterCallbackRan = false
        gate.performIfActive { laterCallbackRan = true }
        XCTAssertFalse(laterCallbackRan)
    }

    func testCallbackCanStopReentrantly() {
        let gate = URLSchemeTaskCallbackGate()
        var callbackCount = 0

        gate.performIfActive {
            callbackCount += 1
            gate.stop()
        }
        gate.performIfActive { callbackCount += 1 }

        XCTAssertEqual(callbackCount, 1)
    }
}
