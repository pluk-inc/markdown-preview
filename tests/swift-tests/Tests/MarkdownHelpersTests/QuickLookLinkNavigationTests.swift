import WebKit
import XCTest
@testable import MarkdownHelpers

final class QuickLookLinkNavigationTests: XCTestCase {
    @MainActor
    func testRenderedClicksReachQuickLookExternalOpener() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ql-links-\(UUID().uuidString).md")
        try """
        [Custom](unlisted-app://open/item)

        [Web](https://example.com)

        [Unsafe](javascript:alert(1))
        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let controller = PreviewViewController()
        var opened: [URL] = []
        controller.openExternalLink = { url, _ in opened.append(url) }
        try await controller.preparePreviewOfFile(at: file)
        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        defer { view.stopLoading() }
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)
        for (index, destination) in ["unlisted-app://open/item", "https://example.com/"].enumerated() {
            _ = try await view.evaluateJavaScript("document.querySelectorAll('article a')[\(index)].click(); true")
            let clickDeadline = Date().addingTimeInterval(3)
            while opened.count <= index && Date() < clickDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(opened.last?.absoluteString, destination)
            XCTAssertEqual(opened.count, index + 1)
            XCTAssertEqual(view.url?.absoluteString, "about:blank", "External links must not navigate the preview")
        }
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
        controller.openExternalLink = { url, _ in opened.append(url) }
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
            XCTAssertEqual(opened.last.map { ExternalLinkPolicy.decision(for: $0, defaults: nil) }, .open)
            XCTAssertEqual(view.url?.absoluteString, "about:blank")
        }
        let imageHref = try await view.evaluateJavaScript("document.querySelectorAll('article a')[2].getAttribute('href')")
        XCTAssertEqual(imageHref as? String, "diagram.png", "Non-Markdown targets stay as written")
    }
}
