import WebKit
import XCTest
@testable import MarkdownHelpers

final class QuickLookLinkNavigationTests: XCTestCase {
    @MainActor
    func testWebLinksGoToTheAppAndCustomLinksPlayTheAlertSound() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ql-links-\(UUID().uuidString).md")
        try """
        [Custom](unlisted-app://open/item)

        [Web](https://example.com)

        [Unsafe](javascript:alert(1))
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = PreviewViewController()
        var handedOff: [URL] = []
        var rejected = 0
        controller.handOffToApp = { url in handedOff.append(url); return true }
        controller.rejectLink = { rejected += 1 }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)
        // Quick Look cannot open URLs: a custom link only gets the alert
        // sound, a web link goes to the app. Neither navigates the page.
        for (index, expectedRejections, expectedHandOffs) in [(0, 1, 0), (1, 1, 1)] {
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while rejected < expectedRejections || handedOff.count < expectedHandOffs, Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(rejected, expectedRejections)
            XCTAssertEqual(handedOff.count, expectedHandOffs)
            XCTAssertEqual(view.url?.absoluteString, "about:blank", "Links must not navigate the preview")
        }
        XCTAssertEqual(handedOff.last?.absoluteString, "https://example.com/")
        let unsafeHref = try await view.evaluateJavaScript("document.querySelectorAll('article a')[2].hasAttribute('href')")
        XCTAssertEqual(unsafeHref as? Bool, false)
    }

    @MainActor
    func testRelativeMarkdownLinksOpenInTheApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-file-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("guides"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("README.md")
        try """
        [Setup](guides/setup.md#install) <a href='../Other Notes.md'>Raw</a> [Image](diagram.png)
        """.write(to: file, atomically: true, encoding: .utf8)
        let controller = PreviewViewController()
        var opened: [URL] = []
        var appIsRunning = true
        var rejected = 0
        controller.handOffToApp = { url in
            guard appIsRunning else { return false }
            opened.append(url)
            return true
        }
        controller.rejectLink = { rejected += 1 }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)

        let folderPath = folder.standardizedFileURL.path
        let expected = [
            "md-preview://file\(folderPath)/guides/setup.md#install",
            "md-preview://file\(folder.deletingLastPathComponent().standardizedFileURL.path)/Other%20Notes.md",
        ]
        for (index, destination) in expected.enumerated() {
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while opened.count <= index && Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(opened.last?.absoluteString, destination)
            XCTAssertEqual(view.url?.absoluteString, "about:blank")
        }
        XCTAssertEqual(rejected, 0)
        let imageHref = try await view.evaluateJavaScript("document.querySelectorAll('article a')[2].getAttribute('href')")
        XCTAssertEqual(imageHref as? String, "diagram.png", "Non-Markdown targets stay as written")

        // A non-Markdown file cannot open. Without a running app or Finder host,
        // the isolated test controller rejects the remaining link.
        for (index, expectedRejections) in [(2, 1), (0, 2)] {
            if index == 0 { appIsRunning = false }
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while rejected < expectedRejections && Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(rejected, expectedRejections)
        }
        XCTAssertEqual(opened.count, expected.count)
    }

    @MainActor
    func testHeadingLinksScrollToGitHubStyleSlugs() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ql-headings-\(UUID().uuidString).md")
        let filler = String(repeating: "Filler paragraph.\n\n", count: 200)
        try """
        [Bottom](#bottom-of-this-document) [Repeat](#repeat-1) [Missing](#no-such-heading) [Top](#) [Repeat 1](#repeat-1-1)

        \(filler)

        ## Repeat

        \(filler)

        ## Repeat

        \(filler)

        ## Repeat-1

        \(filler)

        ## Bottom of this document

        \(filler)
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = PreviewViewController()
        var opened: [URL] = []
        controller.handOffToApp = { url in opened.append(url); return true }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)

        func click(_ index: Int, landsOn headingIndex: Int?) async throws {
            _ = try await view.evaluateJavaScript("window.scrollTo(0, 0); document.querySelectorAll('article a')[\(index)].click(); true")
            guard let headingIndex else {
                try await Task.sleep(for: .milliseconds(300))
                let scrollY = try await view.evaluateJavaScript("window.scrollY") as? Double
                XCTAssertEqual(scrollY, 0, "An unknown fragment must not scroll")
                return
            }
            let script = "Math.round(document.querySelectorAll('article h2')[\(headingIndex)].getBoundingClientRect().top)"
            let clickDeadline = Date().addingTimeInterval(3)
            var top = try await view.evaluateJavaScript(script) as? Double
            while (top ?? .infinity) > 1, Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
                top = try await view.evaluateJavaScript(script) as? Double
            }
            XCTAssertEqual(top ?? .infinity, 0, accuracy: 1, "Link \(index) should scroll heading \(headingIndex) to the top")
        }
        try await click(0, landsOn: 3)
        try await click(1, landsOn: 1)
        try await click(2, landsOn: nil)
        try await click(4, landsOn: 2)
        // A bare `#` goes back to the top, like in a browser.
        _ = try await view.evaluateJavaScript("window.scrollTo(0, 2000); document.querySelectorAll('article a')[3].click(); true")
        let topDeadline = Date().addingTimeInterval(3)
        var scrollY = try await view.evaluateJavaScript("window.scrollY") as? Double
        while (scrollY ?? 1) > 0, Date() < topDeadline {
            try await Task.sleep(for: .milliseconds(20))
            scrollY = try await view.evaluateJavaScript("window.scrollY") as? Double
        }
        XCTAssertEqual(scrollY, 0)
        XCTAssertTrue(opened.isEmpty, "Fragment links must stay in the preview, got \(opened)")
        XCTAssertEqual(view.url?.absoluteString, "about:blank")
    }

    func testPageFragmentAcceptsPlainAndEncodedHash() throws {
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank#intro"))), "intro")
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank%23intro"))), "intro")
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank#caf%C3%A9"))), "café")
        XCTAssertEqual(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:blank#"))), "")
        XCTAssertNil(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "about:srcdoc#intro"))))
        XCTAssertNil(PreviewViewController.pageFragment(of: try XCTUnwrap(URL(string: "https://example.com/#intro"))))
    }
}
