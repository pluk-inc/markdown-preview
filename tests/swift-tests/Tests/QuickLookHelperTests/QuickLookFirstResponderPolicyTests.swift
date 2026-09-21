import XCTest
@testable import QuickLookHelpers

/// The Quick Look preview must not pull keyboard focus to itself on load.
/// Doing so swallows the arrow keys the host uses for file navigation, so
/// once the Finder selection reaches a Markdown file the user can no longer
/// arrow to the next one (pluk-inc/markdown-preview#292). A prior change
/// (pluk-inc/markdown-preview#288) claimed first responder to make ⌘A/⌘C
/// work without a click. That is the trade this policy declines: those
/// chords now need a click into the preview first, because the host only
/// forwards key events to the extension while it has focus.
final class QuickLookFirstResponderPolicyTests: XCTestCase {

    func testPreviewDoesNotClaimFirstResponderOnLoad() {
        XCTAssertFalse(QuickLookFirstResponderPolicy.claimsFirstResponderOnLoad)
    }

    func testRationaleNamesTheRegression() {
        XCTAssertTrue(
            QuickLookFirstResponderPolicy.rationale.contains("#292"),
            "The rationale should cite the issue it protects against."
        )
    }
}
