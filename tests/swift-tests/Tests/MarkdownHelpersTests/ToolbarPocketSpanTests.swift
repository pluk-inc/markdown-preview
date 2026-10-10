import AppKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class ToolbarPocketSpanTests: XCTestCase {
    private let strip = NSRect(x: 0, y: 548, width: 700, height: 52)

    private func makePocket() throws -> NSView {
        guard #available(macOS 26.0, *),
              let cls = NSClassFromString("NSScrollPocket") as? NSView.Type else {
            throw XCTSkip("Toolbar scroll pockets require macOS 26 AppKit")
        }
        return cls.init(frame: .zero)
    }

    /// A host with a web view stand-in starting 300 points in, as the
    /// centered article does, holding the pocket WebKit would add.
    private func makeCenteredLayout() throws -> (host: NSView, webView: NSView, pocket: NSView) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let webView = NSView(frame: NSRect(x: 300, y: 0, width: 700, height: 600))
        host.addSubview(webView)
        let pocket = try makePocket()
        webView.addSubview(pocket)
        pocket.frame = strip
        return (host, webView, pocket)
    }

    func testPocketSpansTheGutterBesideTheWebView() throws {
        let layout = try makeCenteredLayout()
        let span = ToolbarPocketSpan()
        span.update(pocketIn: layout.webView, spanning: layout.host)
        XCTAssertEqual(layout.pocket.frame, NSRect(x: -300, y: 548, width: 1000, height: 52))
    }

    func testSpanSurvivesWebKitLayingThePocketOutAgain() throws {
        let layout = try makeCenteredLayout()
        let span = ToolbarPocketSpan()
        span.update(pocketIn: layout.webView, spanning: layout.host)
        layout.pocket.frame = NSRect(x: 0, y: 520, width: 700, height: 80)
        XCTAssertEqual(layout.pocket.frame, NSRect(x: -300, y: 520, width: 1000, height: 80))
    }

    func testSpanFollowsTheGutterWidth() throws {
        let layout = try makeCenteredLayout()
        let span = ToolbarPocketSpan()
        span.update(pocketIn: layout.webView, spanning: layout.host)
        layout.webView.frame = NSRect(x: 120, y: 0, width: 880, height: 600)
        layout.pocket.frame = NSRect(x: 0, y: 548, width: 880, height: 52)
        span.update(pocketIn: layout.webView, spanning: layout.host)
        XCTAssertEqual(layout.pocket.frame, NSRect(x: -120, y: 548, width: 1000, height: 52))
    }

    func testFullWidthWebViewKeepsWebKitFrame() throws {
        let layout = try makeCenteredLayout()
        layout.webView.frame = layout.host.bounds
        layout.pocket.frame = NSRect(x: 0, y: 548, width: 1000, height: 52)
        let span = ToolbarPocketSpan()
        span.update(pocketIn: layout.webView, spanning: layout.host)
        XCTAssertEqual(layout.pocket.frame, NSRect(x: 0, y: 548, width: 1000, height: 52))
    }

    func testReplacedPocketIsSpannedAndTheOldOneReleased() throws {
        let layout = try makeCenteredLayout()
        let span = ToolbarPocketSpan()
        span.update(pocketIn: layout.webView, spanning: layout.host)
        layout.pocket.removeFromSuperview()
        let replacement = try makePocket()
        layout.webView.addSubview(replacement)
        replacement.frame = strip
        span.update(pocketIn: layout.webView, spanning: layout.host)
        XCTAssertEqual(replacement.frame, NSRect(x: -300, y: 548, width: 1000, height: 52))
        layout.pocket.frame = strip
        XCTAssertEqual(layout.pocket.frame, strip)
    }

    func testOtherSubviewsAreLeftAlone() throws {
        let layout = try makeCenteredLayout()
        let content = NSView(frame: strip)
        layout.webView.addSubview(content, positioned: .below, relativeTo: layout.pocket)
        let span = ToolbarPocketSpan()
        span.update(pocketIn: layout.webView, spanning: layout.host)
        XCTAssertEqual(content.frame, strip)
    }
}
