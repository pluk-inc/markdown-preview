import WebKit
import XCTest
@testable import MarkdownHelpers

final class AppLinkTests: XCTestCase {
    @MainActor
    func testAppLinksSurviveBothRenderModesAndUpdates() async throws {
        let destinations = [
            "claude://resume?session=test", "codex://new?prompt=hello",
            "cursor://file/tmp/example.md", "vscode://file/tmp/example.md",
            "obsidian://open?vault=notes", "x-devonthink-item://test",
            "md-preview://file/tmp/example.md", "OBSIDIAN://open?vault=notes",
            "https://example.com", "mailto:test@example.com", "new-app+v2://test"
        ]
        let markdown = destinations.enumerated().map { "[link\($0)](\($1))" }.joined(separator: "\n\n")
        for mode: MarkdownHTML.VendorLoading in [.lazy, .inline] {
            let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: mode)
            let view = try await load(rendered.html)
            defer { view.stopLoading() }
            for pass in 0..<2 {
                if pass == 1 {
                    _ = try await view.evaluateJavaScript("MdPreview.update(\(MarkdownHTML.javaScriptStringLiteral(rendered.articleHTML))); true")
                }
                let hrefs = try await view.evaluateJavaScript("[...document.querySelectorAll('article a')].map(a => a.getAttribute('href'))")
                XCTAssertEqual(hrefs as? [String], destinations, "\(mode), pass \(pass)")
            }
        }
    }

    @MainActor
    func testUnsafeAndPassiveDestinationsRemainBlocked() async throws {
        let html = """
        <a href="javascript:alert(1)">script</a>
        <a href="jav&#x09;ascript:alert(1)">obfuscated</a>
        <a href="data:text/html,test">data</a>
        <a href="vbscript:msgbox(1)">vbscript</a>
        <a href="blob:https://example.com/test">blob</a>
        <a href="filesystem:https://example.com/test">filesystem</a>
        <a href="about:blank">about</a>
        <a href="file:///tmp/test.md">file</a>
        <img src="obsidian://open?vault=notes">
        <svg><a href="obsidian://open?vault=notes"><text>svg</text></a></svg>
        <a href="obsidian://open?vault=notes" onclick="alert(1)">supported</a>
        """
        for mode: MarkdownHTML.VendorLoading in [.lazy, .inline] {
            let view = try await load(MarkdownHTML.render(markdown: html, vendorLoading: mode).html)
            defer { view.stopLoading() }
            for pass in 0..<2 {
                if pass == 1 {
                    _ = try await view.evaluateJavaScript("MdPreview.update(\(MarkdownHTML.javaScriptStringLiteral(html))); true")
                }
                let result = try await view.evaluateJavaScript("""
                (() => {
                    const article = document.querySelector('article');
                    return {
                        links: [...article.querySelectorAll('a[href]')].map(a => a.textContent),
                        passive: article.querySelectorAll('img[src], svg a[href], [onclick]').length
                    };
                })()
                """)
                let state = try XCTUnwrap(result as? [String: Any])
                XCTAssertEqual(state["links"] as? [String], ["supported"], "\(mode), pass \(pass)")
                XCTAssertEqual(state["passive"] as? Int, 0)
            }
        }
    }

    func testNativePolicyAndPersistedApprovals() throws {
        let suite = "AppLinkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for scheme in ["claude", "codex", "cursor", "vscode", "obsidian", "x-devonthink-item", "OBSIDIAN", "new-app+v2"] {
            let url = try XCTUnwrap(URL(string: "\(scheme)://test"))
            XCTAssertEqual(ExternalLinkPolicy.decision(for: url, defaults: defaults), .confirm)
        }
        let approved = try XCTUnwrap(URL(string: "CUSTOM://first"))
        ExternalLinkPolicy.remember(approved, defaults: defaults)
        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(ExternalLinkPolicy.decision(for: URL(string: "custom://another")!, defaults: reopenedDefaults), .open)
        XCTAssertEqual(ExternalLinkPolicy.decision(for: URL(string: "different://test")!, defaults: defaults), .confirm)
        ExternalLinkPolicy.reset(defaults: defaults)
        XCTAssertEqual(ExternalLinkPolicy.decision(for: approved, defaults: defaults), .confirm)
        for value in ["https://example.com", "http://example.com", "mailto:test@example.com", "md-preview://file/tmp/test.md", "MD-PREVIEW://file/tmp/test.md"] {
            XCTAssertEqual(ExternalLinkPolicy.decision(for: URL(string: value)!, defaults: defaults), .open)
        }
        // Persisted values can never override the unsafe-scheme boundary.
        for scheme in ExternalLinkPolicy.blockedSchemes {
            defaults.set(true, forKey: ExternalLinkPolicy.approvalKey(for: scheme, defaults: defaults))
        }
        for scheme in ExternalLinkPolicy.blockedSchemes {
            let url = try XCTUnwrap(URL(string: "\(scheme):test"))
            XCTAssertEqual(ExternalLinkPolicy.decision(for: url, defaults: defaults), .blocked)
        }
        XCTAssertEqual(ExternalLinkPolicy.decision(for: URL(string: "relative.md")!, defaults: nil), .blocked)
        XCTAssertEqual(ExternalLinkPolicy.decision(for: approved, defaults: nil), .confirm)
    }

    func testResetIgnoresAnApprovalWriteThatStartedBeforeReset() throws {
        let suite = "AppLinkRaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = URL(string: "old-app://test")!
        ExternalLinkPolicy.remember(old, defaults: defaults)
        let pendingKey = ExternalLinkPolicy.approvalKey(for: "pending-app", defaults: defaults)
        ExternalLinkPolicy.reset(defaults: defaults)
        defaults.set(true, forKey: pendingKey) // delayed extension write
        XCTAssertEqual(ExternalLinkPolicy.decision(for: old, defaults: defaults), .confirm)
        XCTAssertEqual(ExternalLinkPolicy.decision(for: URL(string: "pending-app://test")!, defaults: defaults), .confirm)
        let fresh = URL(string: "fresh-app://test")!
        ExternalLinkPolicy.remember(fresh, defaults: defaults)
        XCTAssertEqual(ExternalLinkPolicy.decision(for: fresh, defaults: defaults), .open)
    }

    @MainActor
    private func load(_ html: String) async throws -> WKWebView {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(15)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(view.isLoading)
        return view
    }
}
