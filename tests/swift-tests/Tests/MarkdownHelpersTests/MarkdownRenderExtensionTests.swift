import Foundation
import WebKit
import XCTest

@testable import MarkdownHelpers

final class MarkdownRenderExtensionTests: XCTestCase {
  func testRegistryContainsBuiltInRenderExtensionsInPipelineOrder() {
    XCTAssertEqual(
      MarkdownHTML.renderExtensions.map(\.id),
      ["colorful-headings", "collapsible-headings"]
    )
  }

  func testDisabledExtensionsEmitNeitherTransformsNorAssets() {
    let rendered = MarkdownHTML.render(
      markdown: "# Heading\n\nBody text.",
      vendorLoading: .lazy,
      renderExtensionConfiguration: .init(enabledIDs: [])
    )

    XCTAssertFalse(rendered.html.contains("--mdp-heading-h1"))
    XCTAssertFalse(rendered.html.contains("id: 'collapsible-headings'"))
  }

  func testRenderExtensionPreferencesDefaultEveryRegistryIDToEnabled() throws {
    let (defaults, suiteName) = try makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let registryIDs = MarkdownHTML.renderExtensions.map(\.id)

    XCTAssertEqual(
      RenderExtensionPreferences.enabledIDs(from: defaults, registryIDs: registryIDs),
      Set(registryIDs)
    )
  }

  func testRenderExtensionPreferencesPersistOptOutWithSafeKey() throws {
    let (defaults, suiteName) = try makeDefaults()
    let registryIDs = ["math", "future/extension:日本語"]
    defer { defaults.removePersistentDomain(forName: suiteName) }

    RenderExtensionPreferences.setEnabled(false, for: registryIDs[1], in: defaults)

    XCTAssertFalse(RenderExtensionPreferences.isEnabled(registryIDs[1], in: defaults))
    XCTAssertEqual(
      RenderExtensionPreferences.enabledIDs(from: defaults, registryIDs: registryIDs),
      Set(["math"])
    )
    XCTAssertFalse(
      RenderExtensionPreferences.defaultsKey(for: registryIDs[1]).contains("/")
    )

    RenderExtensionPreferences.store(enabledIDs: Set(registryIDs), in: defaults, registryIDs: registryIDs)
    XCTAssertEqual(
      RenderExtensionPreferences.enabledIDs(from: defaults, registryIDs: registryIDs),
      Set(registryIDs)
    )
  }

  private func makeDefaults() throws -> (UserDefaults, String) {
    let suite = "doc.md-preview.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }

  func testHeadingExtensionsEmitAssetsOnlyWhenDocumentHasHeadings() {
    let headings = MarkdownHTML.render(
      markdown: "# First\n\nIntro\n\n## Nested\n\nDetails\n\n# Second",
      vendorLoading: .lazy
    )
    XCTAssertTrue(headings.html.contains("--mdp-heading-h1: #d14f6a"))
    XCTAssertTrue(headings.html.contains("id: 'collapsible-headings'"))
    XCTAssertTrue(headings.html.contains("mdp-collapsed-section"))

    let plain = MarkdownHTML.render(markdown: "Plain text.", vendorLoading: .lazy)
    XCTAssertFalse(plain.html.contains("--mdp-heading-h1: #d14f6a"))
    XCTAssertFalse(plain.html.contains("id: 'collapsible-headings'"))
  }

  func testHeadingExtensionsActivateForHeadingsOnlyInFootnoteDefinitions() {
    let rendered = MarkdownHTML.render(
      markdown: "Body text with no heading.[^1]\n\n[^1]: ## Footnote heading",
      vendorLoading: .lazy
    )
    XCTAssertTrue(rendered.html.contains("<h2"))
    XCTAssertTrue(rendered.html.contains("--mdp-heading-h1: #d14f6a"))
    XCTAssertTrue(rendered.html.contains("id: 'collapsible-headings'"))
  }

  @MainActor
  func testCollapsibleHeadingsHideSectionUntilNextEqualOrHigherHeading() async throws {
    let html = MarkdownHTML.makeHTML(
      from: "# First\n\nIntro\n\n## Nested\n\nDetails\n\n# Second\n\nVisible",
      vendorLoading: .lazy
    )
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 400))
    webView.loadHTMLString(html, baseURL: nil)
    while webView.isLoading {
      try await Task.sleep(for: .milliseconds(10))
    }

    let result = try await webView.evaluateJavaScript("""
      (() => {
        const first = document.querySelector('h1');
        first.click();
        return {
          expandedAfterHeadingClick: first.querySelector('.mdp-collapse-toggle').getAttribute('aria-expanded'),
          introHiddenAfterHeadingClick: document.querySelector('p').classList.contains('mdp-collapsed-section')
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["expandedAfterHeadingClick"] as? String, "true")
    XCTAssertEqual(result?["introHiddenAfterHeadingClick"] as? Bool, false)

    let toggled = try await webView.evaluateJavaScript("""
      (() => {
        const first = document.querySelector('h1');
        const nested = document.querySelector('h2');
        first.querySelector('.mdp-collapse-toggle').click();
        return {
          expanded: first.querySelector('.mdp-collapse-toggle').getAttribute('aria-expanded'),
          introHidden: document.querySelector('p').classList.contains('mdp-collapsed-section'),
          nestedHidden: nested.classList.contains('mdp-collapsed-section'),
          secondHidden: document.querySelectorAll('h1')[1].classList.contains('mdp-collapsed-section')
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(toggled?["expanded"] as? String, "false")
    XCTAssertEqual(toggled?["introHidden"] as? Bool, true)
    XCTAssertEqual(toggled?["nestedHidden"] as? Bool, true)
    XCTAssertEqual(toggled?["secondHidden"] as? Bool, false)
  }

  @MainActor
  func testExpandingParentPreservesNestedHeadingsOwnCollapsedState() async throws {
    let html = MarkdownHTML.makeHTML(
      from: "# First\n\nIntro\n\n## Nested\n\nDetails\n\n# Second\n\nVisible",
      vendorLoading: .lazy
    )
    let webView = WKWebView(frame: .init(x: 0, y: 0, width: 640, height: 400))
    webView.loadHTMLString(html, baseURL: nil)
    while webView.isLoading {
      try await Task.sleep(for: .milliseconds(10))
    }

    // Collapse the nested h2, then collapse and re-expand the parent h1.
    // Expanding the parent must not silently re-reveal the nested section.
    let result = try await webView.evaluateJavaScript("""
      (() => {
        const first = document.querySelector('h1');
        const nested = document.querySelector('h2');
        const details = document.querySelectorAll('p')[1];
        nested.querySelector('.mdp-collapse-toggle').click();
        first.querySelector('.mdp-collapse-toggle').click();
        first.querySelector('.mdp-collapse-toggle').click();
        return {
          firstExpanded: first.querySelector('.mdp-collapse-toggle').getAttribute('aria-expanded'),
          nestedExpanded: nested.querySelector('.mdp-collapse-toggle').getAttribute('aria-expanded'),
          detailsHidden: details.classList.contains('mdp-collapsed-section')
        };
      })()
      """) as? [String: Any]
    XCTAssertEqual(result?["firstExpanded"] as? String, "true")
    XCTAssertEqual(result?["nestedExpanded"] as? String, "false")
    XCTAssertEqual(result?["detailsHidden"] as? Bool, true)
  }

  func testCollapsedSectionsStayVisibleUnderPrintMedia() {
    // Collapsing is a screen-only viewing convenience: printed/exported
    // documents must render every section, and the toggle button must not
    // appear on paper. WKWebView doesn't emulate `@media print` in tests, so
    // this checks the generated rules are correctly scoped instead of
    // rendered behavior.
    let css = MarkdownHTML.collapsibleHeadersStylesheet
    XCTAssertTrue(css.range(
      of: #"@media screen\s*\{\s*\.markdown-body > \.mdp-collapsed-section\s*\{\s*display: none;"#,
      options: .regularExpression
    ) != nil)
    XCTAssertTrue(css.range(
      of: #"@media print\s*\{\s*\.markdown-body > \.mdp-collapsible-heading > \.mdp-collapse-toggle\s*\{\s*display: none;"#,
      options: .regularExpression
    ) != nil)
  }

  func testHostBridgeProvidesRendererAndReapplierLifecycle() {
    let bridge = MarkdownHTML.hostBridgeScript
    XCTAssertTrue(bridge.contains("window.MdPreview.registerRenderer"))
    XCTAssertTrue(bridge.contains("window.MdPreview.renderAll"))
    XCTAssertTrue(bridge.contains("window.MdPreview.registerReapplier"))
  }
}
