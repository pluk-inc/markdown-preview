import XCTest
import WebKit
@testable import MarkdownHelpers

final class MarkdownHTMLRenderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        TestVendor.installHighlighterGrammar()
    }

    @MainActor
    func testBareURLsBecomeNavigableDOMLinksInBothRenderModes() async throws {
        for vendorLoading: MarkdownHTML.VendorLoading in [.inline, .lazy] {
            let html = MarkdownHTML.makeHTML(
                from: "* https://apple.com/\n* https://github.com/",
                vendorLoading: vendorLoading
            )
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 300))
            webView.loadHTMLString(html, baseURL: nil)
            let deadline = Date().addingTimeInterval(10)
            while webView.isLoading && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(webView.isLoading)
            let links = try await webView.evaluateJavaScript("""
                Array.from(document.querySelectorAll('article li a')).map(a => a.href)
                """) as? [String]
            XCTAssertEqual(links, ["https://apple.com/", "https://github.com/"])
        }
    }

    func testTableCellsBreakCJKPhrasesAcrossInlineFormatting() {
        let html = MarkdownHTML.render(markdown: "| A |\n| --- |\n| 第一句，**第二句**（第三句）`代码` |\n", vendorLoading: .lazy).html
        XCTAssertTrue(html.contains("第一句，<strong><wbr>第二句</strong><wbr>（第三句）<code>代码</code>"), html)
        // Paragraph text keeps its original markup.
        XCTAssertTrue(MarkdownHTML.render(markdown: "第一句，**第二句**", vendorLoading: .lazy).html.contains("第一句，<strong>第二句</strong>"))
    }

    func testLocalMarkdownImagesRemainReadOnlyInPreview() {
        let rendered = MarkdownHTML.render(
            markdown: "![1](notes-pictures/1.png)",
            assetBaseHref: "md-asset:///Users/me/notes/",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains("<img src=\"notes-pictures/1.png\""))
        XCTAssertTrue(rendered.html.contains("<base href=\"md-asset:///Users/me/notes/\">"))
        XCTAssertFalse(rendered.html.contains("kind: 'imageClick'"))
    }

    func testYamlFrontmatterRendersAsTableBeforeDocumentBody() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            name: build-validator
            description: Validate R&D < 5 & ship safely.
            ---
            You are a **build validator**.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.hasPrefix("<section class=\"md-frontmatter\""))
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"4\""
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<tr><th scope=\"row\" dir=\"auto\">name</th><td dir=\"auto\">build-validator</td></tr>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<td dir=\"auto\">Validate R&amp;D &lt; 5 &amp; ship safely.</td>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"5\">You are a <strong>build validator</strong>.</p>"
        ))
    }

    func testFrontmatterListValuesRenderAsPillsAndScalarsUnquote() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            name: "openai-docs"
            category: core features
            tags:
              - links
              - "second tag"
            empty:
            ---
            Body.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<tr><th scope=\"row\" dir=\"auto\">name</th><td dir=\"auto\">openai-docs</td></tr>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<td dir=\"auto\"><span class=\"md-fm-pill\" dir=\"auto\">links</span>"
            + "<span class=\"md-fm-pill\" dir=\"auto\">second tag</span></td>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<tr><th scope=\"row\" dir=\"auto\">empty</th>"
            + "<td dir=\"auto\"><span class=\"md-fm-empty\" aria-hidden=\"true\"></span></td></tr>"
        ))
    }

    func testTomlFrontmatterRendersAsTable() {
        let rendered = MarkdownHTML.render(
            markdown: """
            +++
            title = "Draft"
            tags = ["markdown", "frontmatter"]
            +++
            Body.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.hasPrefix("<section class=\"md-frontmatter\""))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<tr><th scope=\"row\" dir=\"auto\">title</th><td dir=\"auto\">Draft</td></tr>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<span class=\"md-fm-pill\" dir=\"auto\">markdown</span>"
            + "<span class=\"md-fm-pill\" dir=\"auto\">frontmatter</span>"
        ))
    }

    func testDocumentWithoutFrontmatterDoesNotRenderFrontmatterTable() {
        let rendered = MarkdownHTML.render(
            markdown: "# Plain document",
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.articleHTML.contains("md-frontmatter"))
    }

    func testObsidianHighlightRendersInPreviewWithDedicatedStyling() {
        let rendered = MarkdownHTML.render(
            markdown: "==Highlighted **text**==",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<mark class=\"md-highlight\">Highlighted <strong>text</strong></mark>"
        ))
        XCTAssertTrue(rendered.html.contains("mark.md-highlight"))
    }

    @MainActor
    func testScrollableLongTableKeepsWebKitViewportAndScrollsDocument() async throws {
        let rows = (1...750).map { "| \($0) | Function \($0) | 100.00% |" }
            .joined(separator: "\n")
        let rendered = MarkdownHTML.render(
            markdown: """
            | State | Function | Match |
            | --- | --- | ---: |
            \(rows)
            """,
            allowsScroll: true,
            vendorLoading: .lazy
        )
        // The scrollbar hide must never match <html>/<body>: any custom
        // ::-webkit-scrollbar style on the root replaces the native macOS
        // overlay scrollbar with WebKit's legacy one.
        XCTAssertFalse(rendered.html.contains("\n    ::-webkit-scrollbar {"))
        XCTAssertTrue(rendered.html.contains(":where(:not(html):not(body):not(pre):not([data-mdp-scroller]))::-webkit-scrollbar"))
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
            .map { "<style>\($0)</style>" }
            .joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(styleBlocks)
        </head><body><article class="markdown-body">\(rendered.articleHTML)</article></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const root = document.scrollingElement;
            window.scrollTo(0, root.scrollHeight);
            return JSON.stringify({
                viewportHeight: window.innerHeight,
                documentHeight: root.scrollHeight,
                scrollPosition: root.scrollTop,
                articleHeight: document.querySelector('article')?.getBoundingClientRect().height || 0,
                rowCount: document.querySelectorAll('tbody tr').length,
                overflowY: getComputedStyle(document.documentElement).overflowY,
                bodyOverflowY: getComputedStyle(document.body).overflowY,
                rootScrollbarDisplay: getComputedStyle(document.documentElement, '::-webkit-scrollbar').display,
                rootScrollbarWidth: getComputedStyle(document.documentElement, '::-webkit-scrollbar').width,
                tableScrollbarDisplay: getComputedStyle(document.querySelector('table'), '::-webkit-scrollbar').display,
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(
            LongDocumentScrollMetrics.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(metrics.viewportHeight, 600, accuracy: 1)
        XCTAssertEqual(metrics.rowCount, 750, json)
        XCTAssertGreaterThan(metrics.articleHeight, metrics.viewportHeight * 5, json)
        XCTAssertGreaterThan(metrics.documentHeight, metrics.viewportHeight * 5, json)
        XCTAssertGreaterThan(metrics.scrollPosition, metrics.viewportHeight, json)
        XCTAssertEqual(metrics.overflowY, "auto")
        XCTAssertEqual(metrics.bodyOverflowY, "visible")
        XCTAssertNotEqual(metrics.rootScrollbarDisplay, "none", json)
        XCTAssertNotEqual(metrics.rootScrollbarWidth, "0px", json)
        XCTAssertEqual(metrics.tableScrollbarDisplay, "none", json)
    }

    @MainActor
    func testContentWidthModesLayOutDistinctArticleGeometry() async throws {
        func articleRect(contentWidth: MarkdownHTML.ContentWidth) async throws -> (x: Double, width: Double) {
            let rendered = MarkdownHTML.render(
                markdown: "# Doc\n\n" + String(repeating: "word ", count: 400),
                allowsScroll: true,
                vendorLoading: .lazy,
                contentWidth: contentWidth
            )
            let styleBlocks = rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .compactMap { $0.components(separatedBy: "</style>").first }
                .map { "<style>\($0)</style>" }
                .joined(separator: "\n")
            let html = """
            <!DOCTYPE html>
            <html><head>\(styleBlocks)</head>
            <body><article class="markdown-body">\(rendered.articleHTML)</article></body></html>
            """
            // Tall enough that the page never scrolls: a classic scrollbar
            // (CI has no trackpad) would narrow the viewport and the centering.
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1700, height: 1200))
            webView.loadHTMLString(html, baseURL: nil)
            while webView.isLoading {
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = try await webView.evaluateJavaScript("""
            (() => {
                const r = document.querySelector('article').getBoundingClientRect();
                return JSON.stringify({ x: r.x, width: r.width });
            })()
            """)
            let json = try XCTUnwrap(result as? String)
            let rect = try JSONDecoder().decode([String: Double].self, from: Data(json.utf8))
            return (try XCTUnwrap(rect["x"]), try XCTUnwrap(rect["width"]))
        }

        // The app positions the web view so the column lands centered in
        // the window; inside the web view the column must hug the leading
        // gutter and keep the page measure.
        let hostCentered = try await articleRect(contentWidth: .hostCentered)
        XCTAssertEqual(hostCentered.x, 40, accuracy: 1)
        XCTAssertEqual(hostCentered.width, 820, accuracy: 1)

        // Quick Look centers the same measure with CSS auto margins.
        let centered = try await articleRect(contentWidth: .centered)
        XCTAssertEqual(centered.x, (1700 - 820) / 2, accuracy: 1)
        XCTAssertEqual(centered.width, 820, accuracy: 1)

        // Full width spans the viewport minus the body gutters.
        let full = try await articleRect(contentWidth: .full)
        XCTAssertEqual(full.x, 40, accuracy: 1)
        XCTAssertEqual(full.width, 1700 - 80, accuracy: 1)
    }

    func testContentWidthModesEmitExpectedArticleOverrides() {
        let centered = MarkdownHTML.render(
            markdown: "# Doc", vendorLoading: .lazy, contentWidth: .centered)
        XCTAssertFalse(centered.html.contains("article.markdown-body { margin-left: 0; }"))
        XCTAssertFalse(centered.html.contains("article.markdown-body { max-width: none; }"))

        // The app centers the column by positioning the web view, so the
        // article must stay glued to the leading gutter instead of
        // re-centering when the web view's trailing edge tracks the window.
        let hostCentered = MarkdownHTML.render(
            markdown: "# Doc", vendorLoading: .lazy, contentWidth: .hostCentered)
        XCTAssertTrue(hostCentered.html.contains("article.markdown-body { margin-left: 0; }"))

        let full = MarkdownHTML.render(
            markdown: "# Doc", vendorLoading: .lazy, contentWidth: .full)
        XCTAssertTrue(full.html.contains("article.markdown-body { max-width: none; }"))
    }

    func testThemeOverridesEmitSanitizedCodeBackgroundRules() {
        let overrides = MarkdownHTML.ThemeOverrides(
            lightCodeBackground: "#ABCDEF",
            darkCodeBackground: "#123456"
        )
        let rendered = MarkdownHTML.render(
            markdown: "# Doc", vendorLoading: .lazy, themeOverrides: overrides)
        XCTAssertTrue(rendered.html.contains(
            "<style id=\"\(MarkdownHTML.themeStyleElementID)\">"))
        XCTAssertTrue(rendered.html.contains(":root { --code-bg: #ABCDEF; }"))
        XCTAssertTrue(rendered.html.contains(
            ":root[data-mdp-color-scheme=\"dark\"] { --code-bg: #123456; }"))

        // Without overrides the element is still emitted (empty) so a live
        // theme edit has a stable node to rewrite.
        let plain = MarkdownHTML.render(markdown: "# Doc", vendorLoading: .lazy)
        XCTAssertTrue(plain.html.contains(
            "<style id=\"\(MarkdownHTML.themeStyleElementID)\"></style>"))
    }

    func testThemeOverridesEmitTextColorRules() {
        let overrides = MarkdownHTML.ThemeOverrides(
            lightText: "#101010",
            darkText: "#EFEFEF"
        )
        let rendered = MarkdownHTML.render(
            markdown: "# Doc", vendorLoading: .lazy, themeOverrides: overrides)
        XCTAssertTrue(rendered.html.contains(":root { --text: #101010; }"))
        XCTAssertTrue(rendered.html.contains(
            ":root[data-mdp-color-scheme=\"dark\"] { --text: #EFEFEF; }"))
        // The dark value also covers the system-dark media bucket.
        XCTAssertTrue(rendered.html.contains(
            ":root:not([data-mdp-color-scheme=\"light\"]) { --text: #EFEFEF; }"))
    }

    func testThemeOverridesRejectNonHexValues() {
        XCTAssertEqual(MarkdownHTML.ThemeOverrides.sanitizedHexColor("#A1B2C3"), "#A1B2C3")
        XCTAssertEqual(MarkdownHTML.ThemeOverrides.sanitizedHexColor("#A1B2C3D4"), "#A1B2C3D4")
        XCTAssertNil(MarkdownHTML.ThemeOverrides.sanitizedHexColor(nil))
        XCTAssertNil(MarkdownHTML.ThemeOverrides.sanitizedHexColor("#FFF"))
        XCTAssertNil(MarkdownHTML.ThemeOverrides.sanitizedHexColor("red"))
        XCTAssertNil(MarkdownHTML.ThemeOverrides.sanitizedHexColor(
            "#FFFFFF; } </style><script>alert(1)</script>"))

        // A malicious stored value never reaches the emitted page.
        let hostile = MarkdownHTML.ThemeOverrides(
            lightCodeBackground: "#FFFFFF}</style><script>alert(1)</script>",
            darkCodeBackground: nil
        )
        XCTAssertEqual(hostile.css, "")
    }

    @MainActor
    func testLongInlineCodeInHeadingStaysWithinViewport() async throws {
        let rendered = MarkdownHTML.render(
            markdown: "## 1. New port — `src/features/imageUpload/application/repositoryInterfaces/imageProcessedPublisherInterface.ts`",
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        </head>
        <body><article class="markdown-body">\(rendered.articleHTML)</article></body>
        </html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const heading = document.querySelector('h2');
            const code = heading.querySelector('code');
            const style = getComputedStyle(code);
            return JSON.stringify({
                headingClientWidth: heading.clientWidth,
                headingScrollWidth: heading.scrollWidth,
                codeRight: code.getBoundingClientRect().right,
                viewportRight: document.documentElement.clientWidth,
                boxDecorationBreak: style.webkitBoxDecorationBreak,
                fragmentEndDecoration: parseFloat(style.paddingRight) + parseFloat(style.borderRightWidth),
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(HeadingLayoutMetrics.self, from: Data(json.utf8))

        // Some WebKit versions size emergency break fragments without the
        // inline code's cloned end decoration (padding plus border), so a
        // fragment can overshoot the line box by that much. That sub-glyph
        // overflow is invisible and version-dependent; the assertion guards
        // against real overflow (an unwrapped path is hundreds of pixels
        // wide), so the tolerance is one fragment's end decoration.
        let fragmentPaddingTolerance = metrics.fragmentEndDecoration + 1
        XCTAssertLessThanOrEqual(
            metrics.headingScrollWidth,
            metrics.headingClientWidth + fragmentPaddingTolerance
        )
        XCTAssertLessThanOrEqual(metrics.codeRight, metrics.viewportRight + fragmentPaddingTolerance)
        XCTAssertEqual(metrics.boxDecorationBreak, "clone")
    }

    func testReadModeLeavesSelectionPaintingToWebKit() {
        let rendered = MarkdownHTML.render(
            markdown: "Select this text.",
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
        let stylesheet = styleBlocks.joined(separator: "\n").lowercased()
        let nonSelectableRules = stylesheet
            .components(separatedBy: "}")
            .filter { $0.contains("user-select: none") }

        XCTAssertFalse(stylesheet.contains("::selection"))
        XCTAssertFalse(stylesheet.contains("::-webkit-selection"))
        XCTAssertFalse(stylesheet.contains("::-moz-selection"))
        // Code UI is not document text. The generated language label and
        // card header may opt out, and so may the page while a table column
        // is being dragged, but the Markdown content must not.
        let allowedSelectors = ["pre[data-code-language]::before", ".md-code-header",
                                "html.mdp-column-resizing"]
        XCTAssertEqual(nonSelectableRules.count, allowedSelectors.count)
        for selector in allowedSelectors {
            XCTAssertTrue(nonSelectableRules.contains { $0.contains(selector) }, selector)
        }
    }

    @MainActor
    func testReadingLayoutKeepsHeadingCodeAndDirectionalAlignment() async throws {
        let markdown = """
        ## A heading with `inline code` that wraps on a narrow page

        | Left | Center | Right |
        | :--- | :---: | ---: |
        | Name | Ready | 1024 |

        <div dir="rtl">

        - العنصر الأول
        - العنصر الثاني

        </div>
        """
        let article = EscapingHTMLFormatter.format(markdown)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 600))
        webView.loadHTMLString("""
        <!doctype html><meta charset="utf-8">
        <style>\(MarkdownHTML.stylesheet)</style>
        <article class="markdown-body">\(article)</article>
        """, baseURL: nil)
        for _ in 0..<200 where webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(webView.isLoading)
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const heading = getComputedStyle(document.querySelector('h2'));
            const code = getComputedStyle(document.querySelector('h2 code'));
            const list = getComputedStyle(document.querySelector('[dir=rtl] ul'));
            return {
                headingFont: parseFloat(heading.fontSize),
                codeFont: parseFloat(code.fontSize),
                headingLineHeight: parseFloat(heading.lineHeight),
                alignments: Array.from(document.querySelectorAll('tbody td'), td => getComputedStyle(td).textAlign),
                rtlLeadingPadding: parseFloat(list.paddingRight),
                rtlTrailingPadding: parseFloat(list.paddingLeft)
            };
        })()
        """)
        let metrics = try XCTUnwrap(result as? [String: Any])
        let headingFont = try XCTUnwrap(metrics["headingFont"] as? Double)
        let codeFont = try XCTUnwrap(metrics["codeFont"] as? Double)
        let lineHeight = try XCTUnwrap(metrics["headingLineHeight"] as? Double)
        XCTAssertEqual(codeFont, headingFont, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(lineHeight / headingFont, 1.2)
        XCTAssertEqual(metrics["alignments"] as? [String], ["left", "center", "right"])
        XCTAssertGreaterThan(try XCTUnwrap(metrics["rtlLeadingPadding"] as? Double), 0)
        XCTAssertEqual(try XCTUnwrap(metrics["rtlTrailingPadding"] as? Double), 0, accuracy: 0.1)
    }

    func testTypographyFollowsTheSystemTextStyles() {
        XCTAssertEqual(MarkdownHTML.bodyFontSize, 15)
        // At 1x the editor snaps line boxes to whole pixels; a fractional
        // body line would drift from the reader line by line.
        XCTAssertEqual(MarkdownHTML.sourceLineHeight, MarkdownHTML.sourceLineHeight.rounded())
        let css = MarkdownHTML.stylesheet
        XCTAssertTrue(css.contains(MarkdownHTML.textColorCSS))
        XCTAssertTrue(css.contains("--secondary: -apple-system-secondary-label;"))
        XCTAssertTrue(css.contains("--grid: -apple-system-separator;"))
        XCTAssertTrue(css.contains("--accent: var(--link);"))
        XCTAssertTrue(css.contains("h1 { font-size: 2em; }"))
        XCTAssertTrue(css.contains("h6 { font-size: 0.846em; }"))
        // The highlighting palette is declared once and consumed by class rules.
        XCTAssertTrue(css.contains("--hl-keyword:"))
        XCTAssertTrue(MarkdownHTML.highlightThemeCSS.contains(".hljs-keyword"))
        XCTAssertTrue(MarkdownHTML.highlightThemeCSS.contains("var(--hl-keyword)"))
        XCTAssertFalse(MarkdownHTML.highlightThemeCSS.contains("#"))
    }

    @MainActor
    func testSystemColorsFollowTheForcedColorSchemeAndSelectionStaysOnText() async throws {
        let article = EscapingHTMLFormatter.format("# Title\n\nBody text.\n\n- item\n")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 400))
        webView.loadHTMLString("""
        <!doctype html><meta charset="utf-8">
        <style>\(MarkdownHTML.stylesheet)</style>
        <article class="markdown-body">\(article)</article>
        """, baseURL: nil)
        for _ in 0..<200 where webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(webView.isLoading)
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const root = document.documentElement;
            const read = () => {
                const body = getComputedStyle(document.querySelector('p'));
                const bullet = getComputedStyle(document.querySelector('li'), '::before');
                return { text: body.color, bullet: bullet.borderTopColor };
            };
            root.setAttribute('data-mdp-color-scheme', 'light');
            const light = read();
            root.setAttribute('data-mdp-color-scheme', 'dark');
            const dark = read();
            const article = getComputedStyle(document.querySelector('article'));
            return { light, dark, display: article.display, direction: article.flexDirection,
                     h1: parseFloat(getComputedStyle(document.querySelector('h1')).fontSize) };
        })()
        """)
        let metrics = try XCTUnwrap(result as? [String: Any])
        let light = try XCTUnwrap(metrics["light"] as? [String: String])
        let dark = try XCTUnwrap(metrics["dark"] as? [String: String])
        // Pure black on light; the label color (85% white) on dark.
        XCTAssertEqual(light["text"], "rgb(0, 0, 0)")
        XCTAssertTrue(dark["text"]?.hasPrefix("rgba(255, 255, 255, 0.8") == true, dark["text"] ?? "")
        XCTAssertNotEqual(light["bullet"], light["text"], "bullets use the accent color")
        XCTAssertEqual(metrics["display"] as? String, "flex")
        XCTAssertEqual(metrics["direction"] as? String, "column")
        XCTAssertEqual(try XCTUnwrap(metrics["h1"] as? Double), MarkdownHTML.bodyFontSize * 2, accuracy: 0.1)
    }

    @MainActor
    func testUnorderedListMarkersStayClearOfTextForEveryDocumentFont() async throws {
        let article = EscapingHTMLFormatter.format("""
        <details>
        <summary>Expanded details</summary>

        - [Every list marker needs visible clearance.](example.md)

        </details>
        """)

        for font in DocumentFontSetting.allCases {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 400))
            webView.loadHTMLString("""
            <!doctype html><meta charset="utf-8">
            <style>\(MarkdownHTML.stylesheet)</style>
            <style>:root { --mdp-doc-font: \(font.fontFamily); }</style>
            <article class="markdown-body">\(article)</article>
            """, baseURL: nil)
            for _ in 0..<200 where webView.isLoading {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(webView.isLoading, font.rawValue)

            let result = try await webView.evaluateJavaScript("""
            (() => {
                const details = document.querySelector('details');
                details.querySelector('summary').click();
                const item = document.querySelector('ul > li');
                const text = item.querySelector('a').firstChild;
                const firstCharacter = document.createRange();
                firstCharacter.setStart(text, 0);
                firstCharacter.setEnd(text, 1);
                const itemBox = item.getBoundingClientRect();
                const textBox = firstCharacter.getBoundingClientRect();
                const marker = getComputedStyle(item, '::before');
                const markerRight = itemBox.left + parseFloat(marker.left)
                    + parseFloat(marker.borderLeftWidth) + parseFloat(marker.width)
                    + parseFloat(marker.borderRightWidth);
                return {
                    open: details.open,
                    fontSize: parseFloat(getComputedStyle(item).fontSize),
                    gap: textBox.left - markerRight,
                    left: marker.left,
                    inlineStart: marker.insetInlineStart,
                    width: marker.width,
                    border: marker.borderLeftWidth
                };
            })()
            """)
            let metrics = try XCTUnwrap(result as? [String: Any], font.rawValue)
            XCTAssertEqual(metrics["open"] as? Bool, true, font.rawValue)
            let fontSize = try XCTUnwrap(metrics["fontSize"] as? Double, font.rawValue)
            let gap = try XCTUnwrap(metrics["gap"] as? Double, "\(font.rawValue): \(metrics)")
            XCTAssertGreaterThanOrEqual(
                gap,
                fontSize * 0.75,
                "\(font.rawValue): \(metrics)"
            )
        }
    }

    func testCodeCopyButtonFallsBackToQuickLookPasteboardHandler() {
        // Quick Look has no `mdPreviewHost` bridge and its sandbox rejects
        // `navigator.clipboard`, so the copy button must reach the extension's
        // dedicated pasteboard handler before giving up.
        let html = MarkdownHTML.render(markdown: "```sh\nls\n```", vendorLoading: .lazy)
        XCTAssertTrue(html.html.contains("messageHandlers?.mdPreviewCopyCode"))
        XCTAssertTrue(html.html.contains("document.execCommand('copy')"))
    }

    func testBlockquoteUsesItsContentDirectionForLogicalBorder() {
        let rtl = MarkdownHTML.render(
            markdown: "> هذا اقتباس بالعربية.",
            vendorLoading: .lazy
        )
        let ltr = MarkdownHTML.render(
            markdown: "> An English blockquote.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rtl.articleHTML.contains(
            #"<blockquote data-source-line="1" data-source-start="1" data-source-end="1" dir="rtl">"#
        ))
        XCTAssertFalse(ltr.articleHTML.contains(
            #"<blockquote data-source-line="1" data-source-start="1" data-source-end="1" dir="rtl">"#
        ))
        XCTAssertTrue(rtl.html.contains(
            "border-inline-start: 4px solid var(--quote-border);"
        ))
    }

    func testRTLDirectionRecognizesHebrewAndNumericCharacterReferences() {
        let samples = [
            "שלום עולם.",
            "&#1513;&#1500;&#1493;&#1501;",
            "&#x05E9;&#x05DC;&#x05D5;&#x05DD;",
            "&#X05E9;&#X05DC;&#X05D5;&#X05DD;",
        ]

        for markdown in samples {
            let rendered = MarkdownHTML.render(
                markdown: markdown,
                vendorLoading: .lazy
            )

            XCTAssertTrue(
                rendered.articleHTML.contains(#" dir="rtl">"#),
                "Expected RTL direction for \(markdown)"
            )
        }
    }

    func testReadOnlyRenderingPreservesEveryBlankSourceLine() {
        let rendered = MarkdownHTML.render(
            markdown: "First paragraph.\n\n\n## Heading\n\nSecond paragraph.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<h2 data-source-line=\"4\""
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<p data-source-line=\"6\""
        ))
        XCTAssertEqual(
            rendered.articleHTML.components(separatedBy: "md-source-blank-line").count - 1,
            3
        )
        XCTAssertTrue(rendered.html.contains(".md-source-blank-line {"))
        XCTAssertTrue(rendered.html.contains("height: 4.0px;"))
        XCTAssertTrue(rendered.html.contains(".md-source-blank-line:has(+ .md-source-blank-line)"))
        XCTAssertTrue(rendered.html.contains("height: \(MarkdownHTML.sourceLineHeight)px;"))
        XCTAssertFalse(rendered.html.contains(".md-source-blank-line + *"))
        XCTAssertTrue(rendered.html.contains(".md-source-blank-line + h3,"))
        XCTAssertTrue(rendered.html.contains("margin-top: \(MarkdownHTML.sourceLineHeight)px;"))
    }

    func testListsAndDecoratedCodeBlocksOwnTheirOuterSpacing() {
        let rendered = MarkdownHTML.render(
            markdown: "## Heading\n\n- First\n- Second\n\n```sh\necho hello\n```",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.html.contains("li:first-child { margin-top: 0; }"))
        XCTAssertTrue(rendered.html.contains("ul { list-style: none; }"))
        XCTAssertTrue(rendered.html.contains(".md-code-wrap > pre { margin: 0;"))
        XCTAssertTrue(rendered.html.contains(".md-code-wrap {"))
        XCTAssertTrue(rendered.html.contains("margin: \(MarkdownHTML.paragraphSpacing)px 0 0;"))
    }

    func testInlineTabsRemainVisibleInReadMode() {
        let rendered = MarkdownHTML.render(
            markdown: "Plain \tparagraph.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "Plain <span class=\"md-inline-tab\" aria-hidden=\"true\">&#9;</span>paragraph."
        ))
        XCTAssertTrue(rendered.html.contains(".md-inline-tab {"))
        XCTAssertTrue(rendered.html.contains("tab-size: 4;"))
    }

    @MainActor
    func testInlineTabsAdvanceToTheNextReadModeTabStop() async throws {
        let rendered = MarkdownHTML.render(
            markdown: "A\tX\n\nAA\tX\n\nAAA\tX",
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
            .map { "<style>\($0)</style>" }
            .joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html><head>
        \(styleBlocks)
        <style>.markdown-body { font-family: monospace; font-size: 16px; }</style>
        </head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => JSON.stringify(Array.from(document.querySelectorAll('p')).map((paragraph) => {
            const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
            let node = null;
            while (walker.nextNode()) {
                if (walker.currentNode.nodeValue.includes('X')) {
                    node = walker.currentNode;
                    break;
                }
            }
            const range = document.createRange();
            const index = node.nodeValue.indexOf('X');
            range.setStart(node, index);
            range.setEnd(node, index + 1);
            return range.getBoundingClientRect().x;
        })))()
        """)
        let json = try XCTUnwrap(result as? String)
        let positions = try JSONDecoder().decode([Double].self, from: Data(json.utf8))
        XCTAssertEqual(positions.count, 3)
        XCTAssertEqual(positions.max()! - positions.min()!, 0, accuracy: 1, json)
    }

    func testDeepAuthoredListIndentationRemainsVisibleInReadMode() {
        let source = """
        - Parent
            - Child
                    - Deep bullet
                    1. Deep ordered
                    - [x] Deep task
        """
        let articleHTML = EscapingHTMLFormatter.format(
            source,
            sourceMarkdown: source
        )

        XCTAssertEqual(
            articleHTML.components(separatedBy: "class=\"md-source-list-line\"").count - 1,
            3
        )
        XCTAssertEqual(
            articleHTML.components(separatedBy: "class=\"md-source-list-indent-step\"").count - 1,
            6
        )
        XCTAssertTrue(articleHTML.contains(
            "<span class=\"md-source-list-marker\" aria-hidden=\"true\">•</span>Deep bullet"
        ))
        XCTAssertTrue(articleHTML.contains(
            "<span class=\"md-source-list-marker\" aria-hidden=\"true\">1.</span>Deep ordered"
        ))
        XCTAssertTrue(articleHTML.contains(
            "class=\"task-list-item-checkbox\" disabled=\"\" checked=\"\""
        ))
        XCTAssertTrue(articleHTML.contains(" /></span>Deep task"))
        XCTAssertFalse(articleHTML.contains("<br />\n- Deep bullet"))

        let rendered = MarkdownHTML.makeHTML(from: source)
        XCTAssertTrue(rendered.contains(".md-source-list-indent-step {"))
        XCTAssertTrue(rendered.contains(".md-source-list-line {"))
        XCTAssertTrue(rendered.contains(
            "padding-inline-start: var(--mdp-list-indent);"
        ))
    }

    func testStandaloneListLikeIndentedCodeRemainsCodeInReadMode() {
        let source = "    - literal code output"
        let articleHTML = EscapingHTMLFormatter.format(
            source,
            sourceMarkdown: source
        )

        XCTAssertTrue(articleHTML.contains("<pre"))
        XCTAssertTrue(articleHTML.contains("- literal code output"))
        XCTAssertFalse(articleHTML.contains("md-source-list-line"))
    }

    @MainActor
    func testDeepAuthoredListIndentationHasExpectedReadModeGeometry() async throws {
        let source = """
        - Parent
            - Child
                    - Deep item
        """
        let rendered = MarkdownHTML.render(
            markdown: source,
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
            .map { "<style>\($0)</style>" }
            .joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html><head>\(styleBlocks)</head>
        <body><article class="markdown-body">\(rendered.articleHTML)</article></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const line = document.querySelector('.md-source-list-line');
            const paragraph = line.closest('p');
            const childRange = document.createRange();
            childRange.selectNode(paragraph.firstChild);
            const itemRange = document.createRange();
            itemRange.selectNode(line.lastChild);
            return JSON.stringify({
                childTextX: childRange.getBoundingClientRect().x,
                itemTextX: itemRange.getBoundingClientRect().x,
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let geometry = try JSONDecoder().decode(
            [String: Double].self,
            from: Data(json.utf8)
        )

        let childTextX = try XCTUnwrap(geometry["childTextX"])
        let itemTextX = try XCTUnwrap(geometry["itemTextX"])
        XCTAssertGreaterThan(itemTextX - childTextX, 40, json)
    }

    @MainActor
    func testEveryReadModeListDepthUsesTheSameIndentationStep() async throws {
        let source = """
        - Depth 1
            - Depth 2
                - Depth 3
                    - Depth 4
                        - Depth 5
        """
        let rendered = MarkdownHTML.render(
            markdown: source,
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
            .map { "<style>\($0)</style>" }
            .joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html><head>\(styleBlocks)</head>
        <body><article class="markdown-body">\(rendered.articleHTML)</article></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => JSON.stringify(Array.from({ length: 5 }, (_, offset) => {
            const label = `Depth ${offset + 1}`;
            const walker = document.createTreeWalker(
                document.querySelector('article'),
                NodeFilter.SHOW_TEXT
            );
            while (walker.nextNode()) {
                const node = walker.currentNode;
                const index = node.nodeValue.indexOf(label);
                if (index < 0) continue;
                const range = document.createRange();
                range.setStart(node, index);
                range.setEnd(node, index + label.length);
                return range.getBoundingClientRect().x;
            }
            return null;
        })))()
        """)
        let json = try XCTUnwrap(result as? String)
        let positions = try JSONDecoder().decode([Double].self, from: Data(json.utf8))
        XCTAssertEqual(positions.count, 5)
        let steps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        for step in steps.dropFirst() {
            XCTAssertEqual(step, steps[0], accuracy: 1, json)
        }
    }

    @MainActor
    func testEveryEditorListDepthUsesTheSameIndentationStep() async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repository.deleteLastPathComponent()
        }
        let bundleURL = repository
            .appendingPathComponent("md-preview/Vendor/CodeMirror/mdedit.min.js")
        let bundle = try String(contentsOf: bundleURL, encoding: .utf8)
            .replacingOccurrences(of: "</script>", with: "<\\/script>")
        let source = """
        - Depth 1
            - Depth 2
                - Depth 3
                    - Depth 4
                        - Depth 5
        """
        let encodedSource = try String(
            data: JSONEncoder().encode(source),
            encoding: .utf8
        ).map { String($0.dropFirst().dropLast()) } ?? ""
        let html = """
        <!DOCTYPE html>
        <html><head><style>
        html, body, #editor { margin: 0; height: 100%; }
        body { font-family: -apple-system; font-size: 16px; line-height: 1.43; }
        #editor .cm-scroller {
            font-family: -apple-system !important;
            font-size: 16px;
            line-height: 1.43;
        }
        #editor .cm-content { padding: 0; }
        #editor .cm-line { padding: 0; }
        #editor .cm-md-list-item {
            padding-inline-start: 1.6em;
            text-indent: -1.6em;
        }
        .cm-md-bullet {
            display: inline-block;
            width: 1.6em;
            text-indent: 0;
            text-align: end;
            padding-inline-end: 0.45em;
            box-sizing: border-box;
        }
        </style></head>
        <body><div id="editor"></div>
        <script>\(bundle)</script>
        <script>window.editor = MDEditor.create(
            document.getElementById('editor'),
            "\(encodedSource)",
            {}
        );</script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => JSON.stringify(Array.from(document.querySelectorAll('.cm-line')).map((line) => {
            const range = document.createRange();
            const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
            let node = null;
            while (walker.nextNode()) {
                if (walker.currentNode.nodeValue.includes('Depth')) {
                    node = walker.currentNode;
                    break;
                }
            }
            const index = node.nodeValue.indexOf('Depth');
            range.setStart(node, index);
            range.setEnd(node, index + 5);
            return {
                x: range.getBoundingClientRect().x,
                style: line.getAttribute('style'),
                html: line.outerHTML,
            };
        })))()
        """)
        let json = try XCTUnwrap(result as? String)
        let rows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        let positions = rows.compactMap { $0["x"] as? Double }
        XCTAssertEqual(positions.count, 5, json)
        let steps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        for step in steps.dropFirst() {
            XCTAssertEqual(step, steps[0], accuracy: 1, json)
        }
    }

    func testMermaidPostProcessingAcceptsSourceMappedPreTag() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<figure data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"4\" class=\"mermaid-figure\""
        ))
        XCTAssertFalse(rendered.articleHTML.contains("<code class=\"language-mermaid\""))
    }

    func testExplicitColorSchemeIsExposedToRendererScripts() {
        let light = MarkdownHTML.render(
            markdown: "# Light",
            colorScheme: .light
        )
        let dark = MarkdownHTML.render(
            markdown: "# Dark",
            colorScheme: .dark
        )
        let automatic = MarkdownHTML.render(markdown: "# Automatic")

        XCTAssertTrue(light.html.contains(#"<html data-mdp-color-scheme="light">"#))
        XCTAssertTrue(dark.html.contains(#"<html data-mdp-color-scheme="dark">"#))
        XCTAssertTrue(light.html.contains(#":root[data-mdp-color-scheme="light"]"#))
        XCTAssertTrue(dark.html.contains(#":root[data-mdp-color-scheme="dark"]"#))
        XCTAssertTrue(light.html.contains(#":root:not([data-mdp-color-scheme="light"])"#))
        XCTAssertTrue(light.html.contains("background: Canvas;"))
        XCTAssertTrue(automatic.html.contains("<html>"))
        XCTAssertFalse(automatic.html.contains(#"<html data-mdp-color-scheme="#))
    }

    func testMermaidPopupButtonIsEmitted() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(
            rendered.articleHTML.contains(
                #"data-mm-act="popup" tabindex="-1" aria-label="Open in Window""#
            ),
            rendered.articleHTML
        )
        XCTAssertTrue(
            rendered.articleHTML.contains(#"class="mermaid-hud-btn mermaid-hud-popup""#),
            rendered.articleHTML
        )
        XCTAssertTrue(
            rendered.articleHTML.contains(#"class="mermaid-hud-group mermaid-hud-zoom""#),
            rendered.articleHTML
        )
        XCTAssertTrue(
            rendered.articleHTML.contains(#"class="mermaid-hud-group mermaid-hud-actions""#),
            rendered.articleHTML
        )
        XCTAssertTrue(
            rendered.articleHTML.contains(#"data-mm-act="copy" tabindex="-1" aria-label="Copy" title="Copy"></button>"#),
            rendered.articleHTML
        )
        // Assert the shared production wiring as well as the emitted controls.
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("kind: 'mermaidPopup'"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("function openPopup"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("case 'popup'"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("openPopup(figure)"))
    }

    @MainActor
    func testMermaidPopupPostsSVGAndSectionTitle() async throws {
        // Headings before the figure exercise the popup's section-title
        // lookup — the real documents this ships against always have them.
        let rendered = MarkdownHTML.render(
            markdown: """
            # Architecture Notes

            ## 1. System overview

            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )

        // Drive the real mermaidInitWiring with a stub renderer + host so the
        // openPopup path posts the diagram SVG and section title.
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        <script>
        window.__posted = [];
        // The test host WKWebView isn't attached to an on-screen window, so
        // the display link never drives rAF — run callbacks synchronously.
        window.requestAnimationFrame = (callback) => callback();
        window.webkit = {
            messageHandlers: {
                mdPreviewHost: {
                    postMessage(msg) { window.__posted.push(msg); }
                }
            }
        };
        window.pele = {
            render() {
                return {
                    svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"'
                        + ' style="--_fg:var(--pele-fg,#1f1f1f)">'
                        + '<rect width="400" height="200" fill="var(--_fg)"/></svg>'
                };
            }
        };
        </script>
        </head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        // Wait for IntersectionObserver → stub pele.render → attachZoom.
        var renderedReady = false
        for _ in 0..<100 {
            let done = try await webView.evaluateJavaScript(
                "document.querySelector('.mermaid')?.dataset?.mmDone || ''"
            ) as? String
            if done == "1" {
                renderedReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(renderedReady, "mermaid figure should finish stub render")

        // Clear hover noise if any, then open via HUD.
        _ = try await webView.evaluateJavaScript("window.__posted = []; true")
        _ = try await webView.evaluateJavaScript(
            "document.querySelector('[data-mm-act=\"popup\"]').click(); true"
        )

        let hudPayload = try await waitForMermaidPopupMessage(in: webView)
        XCTAssertEqual(hudPayload.kind, "mermaidPopup")
        XCTAssertTrue(hudPayload.svg.contains("<svg"), hudPayload.svg)
        XCTAssertTrue(hudPayload.svg.contains(#"viewBox="0 0 400 200""#), hudPayload.svg)
        // Nearest preceding heading, not the document title.
        XCTAssertEqual(hudPayload.sectionTitle, "1. System overview")
        // Clone should not carry pan/zoom transform styles from the surface.
        XCTAssertFalse(hudPayload.svg.contains("transform:"), hudPayload.svg)
        // The popup has no page stylesheet: Pele's variable wiring stays and
        // the theme colours travel with the SVG as resolved values.
        XCTAssertTrue(hudPayload.svg.contains("--_fg: var(--pele-fg"), hudPayload.svg)
        XCTAssertTrue(hudPayload.svg.contains("--pele-fg: rgb"), hudPayload.svg)
        XCTAssertFalse(hudPayload.svg.contains("color-mix"), hudPayload.svg)

        // Double-click still zooms (the HUD ⛶ button is the only popup trigger).
        _ = try await webView.evaluateJavaScript("window.__posted = []; true")
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const figure = document.querySelector('.mermaid-figure');
            const rect = figure.getBoundingClientRect();
            figure.dispatchEvent(new MouseEvent('dblclick', {
                bubbles: true, cancelable: true,
                clientX: rect.left + rect.width / 2,
                clientY: rect.top + rect.height / 2
            }));
            return true;
        })()
        """)

        var zoomedIn = false
        for _ in 0..<100 {
            let level = try await webView.evaluateJavaScript(
                "document.querySelector('[data-mm-act=\"reset\"]')?.textContent || ''"
            ) as? String
            if level == "200%" {
                zoomedIn = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(zoomedIn, "double-click should zoom in, not open the popup")

        let postedPopupOnDoubleClick = try await webView.evaluateJavaScript(
            "(window.__posted || []).some((m) => m && m.kind === 'mermaidPopup')"
        ) as? Bool
        XCTAssertEqual(postedPopupOnDoubleClick, false, "double-click must not post a mermaidPopup message")
    }

    /// The app on macOS 26 draws the HUD as native glass: the page reports
    /// the hovered figure and runs the host's actions without focusing it.
    @MainActor
    func testNativeDiagramHUDReportsTheHoveredFigureAndRunsHostActions() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <style>\(stylesheet)</style>
        <script>
        document.documentElement.setAttribute('data-mdp-native-hud', '');
        // The host bridge's copy path, which the diagram wiring borrows.
        window.MdPreview = { copyText: async (value) => {
            window.__posted.push({ kind: 'copyCode', value });
            return true;
        } };
        window.__posted = [];
        window.requestAnimationFrame = (callback) => callback();
        window.webkit = { messageHandlers: { mdPreviewHost: {
            postMessage(msg) { window.__posted.push(msg); }
        } } };
        window.pele = { render() {
            return { svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200"></svg>' };
        } };
        </script>
        </head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        var renderedReady = false
        for _ in 0..<100 {
            let done = try await webView.evaluateJavaScript(
                "document.querySelector('.mermaid')?.dataset?.mmDone || ''"
            ) as? String
            if done == "1" {
                renderedReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(renderedReady, "mermaid figure should finish stub render")

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const figure = document.querySelector('.mermaid-figure');
            const last = () => window.__posted.filter((m) => m.kind === 'diagramHUD').pop();
            figure.dispatchEvent(new PointerEvent('pointerenter'));
            const shown = last();
            window.__posted = [];
            window.mdpDiagramHUDAction('in');
            const zoomed = last();
            const focused = document.activeElement === figure;
            window.__posted = [];
            window.mdpDiagramHUDAction('copy');
            const copied = window.__posted.find((m) => m.kind === 'copyCode');
            const htmlHUD = getComputedStyle(figure.querySelector('.mermaid-hud'));
            figure.dispatchEvent(new PointerEvent('pointerleave'));
            const left = last();
            // The page sees the pointer leave for the host's glass; the
            // glass's clicks still act on that figure.
            window.__posted = [];
            window.mdpDiagramHUDAction('reset');
            const afterLeave = last();
            return JSON.stringify({
                afterLeaveVisible: afterLeave?.visible, afterLeaveLevel: afterLeave?.level,
                shownVisible: shown?.visible, shownLevel: shown?.level, shownPopup: shown?.popup,
                shownWidth: shown?.width, shownID: shown?.id, zoomedLevel: zoomed?.level, focused,
                copied: copied?.value, htmlHUDOpacity: htmlHUD.opacity, htmlHUDDisplay: htmlHUD.display,
                leftVisible: left?.visible,
                levelAfterLeave: figure.querySelector('.mermaid-hud-level').textContent
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(state["shownVisible"] as? Bool, true, json)
        XCTAssertEqual(state["shownLevel"] as? String, "100%", json)
        XCTAssertEqual(state["shownPopup"] as? Bool, true, json)
        XCTAssertGreaterThan(state["shownWidth"] as? Double ?? 0, 0, json)
        XCTAssertEqual(state["zoomedLevel"] as? String, "125%", json)
        XCTAssertEqual(state["focused"] as? Bool, false, "a native click must not draw the figure's focus ring")
        XCTAssertEqual(state["copied"] as? String, "flowchart LR\n    A --> B", json)
        XCTAssertNotNil(state["shownID"] as? Int, json)
        // Unseen, but still in the page for the keyboard.
        XCTAssertEqual(state["htmlHUDOpacity"] as? String, "0", json)
        XCTAssertNotEqual(state["htmlHUDDisplay"] as? String, "none", json)
        XCTAssertEqual(state["leftVisible"] as? Bool, false, json)
        XCTAssertEqual(state["levelAfterLeave"] as? String, "100%", json)
        // ...and the glass hears the new level.
        XCTAssertEqual(state["afterLeaveVisible"] as? Bool, true, json)
        XCTAssertEqual(state["afterLeaveLevel"] as? String, "100%", json)
    }

    /// Code blocks get the same native glass HUD on hover: the page reports
    /// the block under the pointer and runs Wrap and Copy for the host.
    @MainActor
    func testNativeCodeHUDReportsTheHoveredBlockAndRunsHostActions() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```swift
            let answer = 42
            ```
            """,
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html data-mdp-native-hud><head>
        <style>\(stylesheet)</style>
        <script>
        window.__posted = [];
        window.__copied = [];
        // Off screen, the display link never drives rAF.
        window.requestAnimationFrame = (callback) => { callback(); return 0; };
        window.webkit = { messageHandlers: { mdPreviewHost: {
            postMessage(msg) { window.__posted.push(msg); }
        } } };
        </script>
        </head><body style="min-height: 3000px">
        <article class="markdown-body" style="padding-top: 200px">\(rendered.articleHTML)</article>
        <script>
        \(MarkdownHTML.codeBlockScript)
        const decorate = enableCodeBlocks(\(MarkdownHTML.codeBlockMessagesJS),
            async (text) => { window.__copied.push(text); return true; });
        decorate(document);
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await webView.evaluateJavaScript("""
        (() => {
            const code = document.querySelector('.md-code-wrap pre code');
            code.dispatchEvent(new PointerEvent('pointerover', { bubbles: true }));
            window.mdpCodeHUDAction('wrap');
            window.mdpCodeHUDAction('copy');
            return true;
        })()
        """)
        try await Task.sleep(for: .milliseconds(50))
        // Scrolling keeps reporting the block, at its new place.
        _ = try await webView.evaluateJavaScript("window.__beforeScroll = window.__posted.length; window.scrollBy(0, 100); true")
        try await Task.sleep(for: .milliseconds(200))
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const huds = window.__posted.filter((m) => m.kind === 'codeHUD');
            const actions = document.querySelector('.md-code-actions');
            const beforeScroll = window.__posted.slice(0, window.__beforeScroll).filter((m) => m.kind === 'codeHUD').pop();
            const afterScroll = window.__posted.slice(window.__beforeScroll).filter((m) => m.kind === 'codeHUD').pop();
            return JSON.stringify({
                shownVisible: huds[0]?.visible, shownWrapped: huds[0]?.wrapped, shownHeight: huds[0]?.height,
                wrappedAfter: beforeScroll?.wrapped,
                scrolledVisible: afterScroll?.visible, scrolledBy: beforeScroll && afterScroll ? beforeScroll.y - afterScroll.y : null,
                copied: window.__copied[0],
                pillOpacity: getComputedStyle(actions).opacity,
                pillVisibility: getComputedStyle(actions).visibility,
                pillWidth: actions.getBoundingClientRect().width,
                afterLeave: (() => {
                    // The page sees the pointer leave for the host's glass;
                    // the glass's clicks still act on that block.
                    document.querySelector('.md-code-wrap pre code')
                        .dispatchEvent(new PointerEvent('pointerout', { bubbles: true }));
                    window.mdpCodeHUDAction('wrap');
                    return document.querySelector('.md-code-wrap').classList.contains('is-wrapped');
                })()
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(state["shownVisible"] as? Bool, true, json)
        XCTAssertEqual(state["shownWrapped"] as? Bool, false, json)
        XCTAssertGreaterThan(state["shownHeight"] as? Double ?? 0, 0, json)
        XCTAssertEqual(state["wrappedAfter"] as? Bool, true, json)
        XCTAssertEqual(state["scrolledVisible"] as? Bool, true, "the HUD follows the block while it scrolls")
        XCTAssertEqual(state["scrolledBy"] as? Double, 100, json)
        // The same text the HTML Copy button copies.
        XCTAssertEqual(state["copied"] as? String, "let answer = 42\n", json)
        // Unseen, but still in the page for the keyboard, in its place.
        XCTAssertEqual(state["pillOpacity"] as? String, "0", json)
        XCTAssertEqual(state["pillVisibility"] as? String, "visible", json)
        XCTAssertGreaterThan(state["pillWidth"] as? Double ?? 0, 0, "the hidden pill keeps its space")
        XCTAssertEqual(state["afterLeave"] as? Bool, false, "Wrap after the leave unwraps the same block")
    }

    @MainActor
    func testMermaidColorsFollowTheThemeWithoutRerendering() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy,
            colorScheme: .dark
        )

        let html = """
        <!DOCTYPE html>
        <html data-mdp-color-scheme="dark"><head>
        <style>\(MarkdownHTML.stylesheet)</style>
        <script>
        window.__runs = 0;
        window.IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
            unobserve() {}
        };
        window.ResizeObserver = class {
            observe() {}
        };
        window.pele = {
            render() {
                window.__runs += 1;
                return { svg: '<svg viewBox="0 0 400 200"><rect width="400" height="200" fill="var(--pele-surface)"/></svg>' };
            }
        };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        func surface() async throws -> String? {
            try await webView.evaluateJavaScript("""
            (() => {
                const rect = document.querySelector('.mermaid svg rect');
                return rect ? getComputedStyle(rect).fill + '|' + window.__runs : null;
            })()
            """) as? String
        }
        var dark: String?
        for _ in 0..<100 {
            dark = try await surface()
            if dark != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let darkSurface = try XCTUnwrap(dark, "figure should finish its stub render")
        XCTAssertTrue(darkSurface.hasSuffix("|1"), darkSurface)

        _ = try await webView.evaluateJavaScript(
            "document.documentElement.dataset.mdpColorScheme = 'light'; true"
        )
        let afterChange = try await surface()
        let lightSurface = try XCTUnwrap(afterChange)
        XCTAssertTrue(lightSurface.hasSuffix("|1"), "a theme change must not re-render: \(lightSurface)")
        XCTAssertNotEqual(darkSurface, lightSurface, "diagram colours must follow the page theme")
    }

    @MainActor
    func testMermaidShowsPeleErrorAboveTheSource() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A -->
            ```
            """,
            vendorLoading: .lazy
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <script>
        window.IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
            unobserve() {}
        };
        window.ResizeObserver = class {
            observe() {}
        };
        window.pele = {
            render() {
                throw Object.assign(new Error('Expected a node <b>'), { code: 'syntax', line: 2, column: 10 });
            }
        };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        var state: String?
        for _ in 0..<100 {
            state = try await webView.evaluateJavaScript("""
            (() => {
                const figure = document.querySelector('.mermaid-figure.mermaid-error');
                if (!figure) return null;
                const node = figure.querySelector('.mermaid');
                return JSON.stringify({
                    done: node.dataset.mmDone || '',
                    tags: node.children.length,
                    text: node.textContent.trim()
                });
            })()
            """) as? String
            if state != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let json = try XCTUnwrap(state, "a failed render must mark the figure")
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["done"] as? String, "1", "a failed figure must not be parsed again")
        XCTAssertEqual(decoded["tags"] as? Int, 0, "the message must be text, never HTML")
        let text = try XCTUnwrap(decoded["text"] as? String)
        // Localized from the error's code and position, not Pele's English text.
        XCTAssertTrue(text.hasPrefix("The diagram has a syntax error. Line 2, column 10"), text)
        XCTAssertFalse(text.contains("Expected a node"), text)
        XCTAssertTrue(text.contains("flowchart LR"), text)
    }

    @MainActor
    func testMermaidRendersNewSourceAfterAnUpdateMorphsTheFigure() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <script>
        window.__sources = [];
        window.IntersectionObserver = class {
            observe() {}
            unobserve() {}
        };
        window.ResizeObserver = class {
            observe() {}
        };
        window.pele = {
            render(source) {
                window.__sources.push(source.trim());
                return { svg: '<svg viewBox="0 0 400 200"></svg>' };
            }
        };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        // What morphdom does to a drawn figure whose source changed: the
        // node is reused, its text replaced and its done flag dropped.
        let sources = try await webView.callAsyncJavaScript("""
            await window.MdPreview.mermaidRenderAll();
            const node = document.querySelector('.mermaid');
            node.textContent = 'flowchart LR\\n    C --> D';
            delete node.dataset.mmDone;
            await window.MdPreview.mermaidRenderAll();
            return JSON.stringify(window.__sources);
            """, contentWorld: .page) as? String
        XCTAssertEqual(sources, #"["flowchart LR\n    A --> B","flowchart LR\n    C --> D"]"#)
    }

    /// An export can start before a lazy page has its bundle. If the bundle
    /// never arrives, renderAll must still settle, and the figure must say the
    /// renderer is unavailable rather than pass its bare source off as drawn.
    @MainActor
    func testLazyRenderAllMarksFiguresWhenTheBundleNeverLoads() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        // No md-asset scheme handler here, so the lazy bundle request fails.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(rendered.html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try await webView.callAsyncJavaScript("""
            await window.MdPreview.mermaidRenderAll();
            const figure = document.querySelector('.mermaid-figure');
            return JSON.stringify({
                error: figure.classList.contains('mermaid-error'),
                text: figure.querySelector('.mermaid').textContent.trim()
            });
            """, contentWorld: .page) as? String
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(state).utf8)) as? [String: Any]
        )
        XCTAssertEqual(decoded["error"] as? Bool, true)
        let text = try XCTUnwrap(decoded["text"] as? String)
        XCTAssertTrue(text.hasPrefix("Mermaid renderer is unavailable."), text)
        XCTAssertTrue(text.contains("A --> B"), text)
    }

    /// A bundle that arrives after the export fallback marked a figure must
    /// still draw the original source, not the "unavailable" message.
    @MainActor
    func testLateBundleDrawsTheSourceAfterTheUnavailableFallback() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        let html = """
        <!DOCTYPE html>
        <html><head><script>
        window.IntersectionObserver = class { observe() {} unobserve() {} };
        window.ResizeObserver = class { observe() {} };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try await webView.callAsyncJavaScript("""
            \(MarkdownHTML.markUndrawnFiguresJS)
            const marked = document.querySelector('.mermaid-figure').classList.contains('mermaid-error');
            window.__sources = [];
            window.pele = {
                render(source) {
                    window.__sources.push(source.trim());
                    return { svg: '<svg viewBox="0 0 400 200"></svg>' };
                }
            };
            const wiring = \(MarkdownHTML.mermaidInitWiring);
            wiring.bootstrap();
            await window.MdPreview.mermaidRenderAll();
            const figure = document.querySelector('.mermaid-figure');
            return JSON.stringify({
                marked,
                error: figure.classList.contains('mermaid-error'),
                drawn: !!figure.querySelector('.mermaid svg'),
                sources: window.__sources
            });
            """, contentWorld: .page) as? String
        XCTAssertEqual(state, #"{"marked":true,"error":false,"drawn":true,"sources":["flowchart LR\n    A --> B"]}"#)
    }

    /// An empty block is not a renderer error: it says so, with no blank
    /// lines under the message, and never reaches the renderer.
    @MainActor
    func testEmptyMermaidBlockShowsOnlyTheEmptyMessage() async throws {
        let rendered = MarkdownHTML.render(markdown: "```mermaid\n```\n", vendorLoading: .lazy)
        let html = """
        <!DOCTYPE html>
        <html><head><script>
        window.IntersectionObserver = class { observe() {} unobserve() {} };
        window.ResizeObserver = class { observe() {} };
        window.__calls = 0;
        window.pele = { render() { window.__calls += 1; return { svg: '<svg></svg>' }; } };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try await webView.callAsyncJavaScript("""
            await window.MdPreview.mermaidRenderAll();
            const figure = document.querySelector('.mermaid-figure');
            return JSON.stringify({
                error: figure.classList.contains('mermaid-error'),
                empty: figure.classList.contains('mermaid-empty'),
                text: figure.querySelector('.mermaid').textContent,
                calls: window.__calls
            });
            """, contentWorld: .page) as? String
        XCTAssertEqual(state, #"{"error":true,"empty":true,"text":"This diagram is empty.","calls":0}"#)
    }

    /// The zoom-out button goes below 100%, and the smaller drawing stays
    /// centred in its box instead of shrinking into the top-left corner.
    @MainActor
    func testMermaidZoomsOutBelowFullSizeAndStaysCentred() async throws {
        let rendered = MarkdownHTML.render(
            markdown: "```mermaid\nflowchart LR\n    A --> B\n```\n",
            vendorLoading: .lazy
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <style>\(MarkdownHTML.stylesheet)</style>
        <script>
        window.requestAnimationFrame = (callback) => callback();
        window.IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
            unobserve() {}
        };
        window.ResizeObserver = class { observe() {} };
        window.pele = { render() { return { svg: '<svg viewBox="0 0 400 200"></svg>' }; } };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try await webView.callAsyncJavaScript("""
            const figure = document.querySelector('.mermaid-figure');
            const out = figure.querySelector('[data-mm-act="out"]');
            for (let i = 0; i < 3; i++) out.click();
            const box = figure.getBoundingClientRect();
            const match = /translate\\(([-\\d.]+)px, *([-\\d.]+)px\\) scale\\(([\\d.]+)\\)/
                .exec(figure.querySelector('.mermaid').style.transform);
            const scale = Number(match[3]);
            return JSON.stringify({
                level: figure.querySelector('.mermaid-hud-level').textContent,
                centredX: Math.abs(Number(match[1]) - box.width * (1 - scale) / 2) < 0.5,
                centredY: Math.abs(Number(match[2]) - box.height * (1 - scale) / 2) < 0.5
            });
            """, contentWorld: .page) as? String
        XCTAssertEqual(state, #"{"level":"51%","centredX":true,"centredY":true}"#)
    }

    /// A zoomed-out drawing stays centred when its box changes size, and a
    /// pan the reader made is kept.
    @MainActor
    func testZoomedOutDiagramStaysCentredWhenItsBoxResizes() async throws {
        let rendered = MarkdownHTML.render(
            markdown: "```mermaid\nflowchart LR\n    A --> B\n```\n",
            vendorLoading: .lazy
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <style>\(MarkdownHTML.stylesheet)</style>
        <script>
        window.requestAnimationFrame = (callback) => callback();
        window.IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
            unobserve() {}
        };
        window.pele = { render() { return { svg: '<svg viewBox="0 0 400 200"></svg>' }; } };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        let state = try await webView.callAsyncJavaScript("""
            const settle = () => new Promise((resolve) => setTimeout(resolve, 150));
            const figure = document.querySelector('.mermaid-figure');
            const surface = figure.querySelector('.mermaid');
            await settle();
            const out = figure.querySelector('[data-mm-act="out"]');
            out.click(); out.click();
            const offset = () => {
                const m = /translate\\(([-\\d.]+)px, *([-\\d.]+)px\\) scale\\(([\\d.]+)\\)/.exec(surface.style.transform);
                const box = figure.getBoundingClientRect(), k = Number(m[3]);
                return [Number(m[1]) - box.width * (1 - k) / 2, Number(m[2]) - box.height * (1 - k) / 2];
            };
            figure.style.width = '420px';
            await settle();
            const centred = offset().every((v) => Math.abs(v) < 0.5);
            // Pan by 30px, then resize again: the pan must survive.
            figure.dispatchEvent(new PointerEvent('pointerdown', { button: 0, clientX: 100, clientY: 100, pointerId: 1, bubbles: true }));
            figure.dispatchEvent(new PointerEvent('pointermove', { clientX: 130, clientY: 100, pointerId: 1, bubbles: true }));
            figure.dispatchEvent(new PointerEvent('pointerup', { clientX: 130, clientY: 100, pointerId: 1, bubbles: true }));
            figure.style.width = '600px';
            await settle();
            const [panX, panY] = offset();
            return JSON.stringify({ centred, panKept: Math.abs(panX - 30) < 0.5 && Math.abs(panY) < 0.5 });
            """, contentWorld: .page) as? String
        XCTAssertEqual(state, #"{"centred":true,"panKept":true}"#)
    }

    @MainActor
    func testMermaidRenderAllRendersFiguresTheObserverNeverReached() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```

            ```mermaid
            flowchart LR
                C --> D
            ```
            """,
            vendorLoading: .lazy
        )

        // The observer never fires, standing in for figures that stay far
        // outside the viewport — print/export must still render them all.
        let html = """
        <!DOCTYPE html>
        <html><head>
        <script>
        window.__runs = 0;
        window.IntersectionObserver = class {
            observe() {}
            unobserve() {}
        };
        window.ResizeObserver = class {
            observe() {}
        };
        window.pele = {
            render() {
                window.__runs += 1;
                return { svg: '<svg viewBox="0 0 400 200"></svg>' };
            }
        };
        </script></head><body>
        <article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const __mdpMermaid = \(MarkdownHTML.mermaidInitWiring);
        __mdpMermaid.bootstrap();
        window.__renderAllSettled = false;
        window.MdPreview.mermaidRenderAll().then(() => {
            window.__renderAllSettled = true;
        });
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        var allRendered = false
        for _ in 0..<100 {
            let state = try await webView.evaluateJavaScript("""
            JSON.stringify({
                settled: window.__renderAllSettled,
                runs: window.__runs,
                done: Array.from(document.querySelectorAll('.mermaid'))
                    .map((n) => n.dataset.mmDone || '')
            })
            """) as? String
            if state == #"{"settled":true,"runs":2,"done":["1","1"]}"# {
                allRendered = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(
            allRendered,
            "renderAll must render every unobserved figure and settle afterwards"
        )
    }

    @MainActor
    private func waitForMermaidPopupMessage(
        in webView: WKWebView,
        timeoutMs: Int = 2000
    ) async throws -> MermaidPopupMessage {
        let steps = max(timeoutMs / 20, 1)
        for _ in 0..<steps {
            let result = try await webView.evaluateJavaScript("""
            (() => {
                const msg = (window.__posted || []).find((m) => m && m.kind === 'mermaidPopup');
                if (!msg) return null;
                return JSON.stringify({
                    kind: String(msg.kind || ''),
                    svg: String(msg.svg || ''),
                    sectionTitle: String(msg.sectionTitle || '')
                });
            })()
            """)
            if let json = result as? String {
                return try JSONDecoder().decode(MermaidPopupMessage.self, from: Data(json.utf8))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let dump = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__posted || [])"
        ) as? String
        struct Timeout: Error {}
        XCTFail("timed out waiting for mermaidPopup; posted=\(dump ?? "nil")")
        throw Timeout()
    }

    /// The article is a flex column on screen, which stretches its children.
    /// Block content should span the column; an inline-level element left at
    /// the top level should not. A `<button>` whose `<form>` the sanitiser
    /// removed lands there, and drawn edge to edge it reads as a working
    /// control instead of the inert leftover it is.
    @MainActor
    func testTopLevelInlineElementsKeepTheirOwnWidth() async throws {
        let rendered = MarkdownHTML.render(markdown: "Paragraph.\n", vendorLoading: .lazy)
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        </head><body><article class="markdown-body">
        <p id="para">Paragraph.</p>
        <button id="control">Sign in</button>
        </article></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const article = document.querySelector('.markdown-body');
            return JSON.stringify({
                articleWidth: article.clientWidth,
                paragraphWidth: document.getElementById('para').getBoundingClientRect().width,
                buttonWidth: document.getElementById('control').getBoundingClientRect().width,
            });
        })()
        """)
        let metrics = try JSONDecoder().decode(
            TopLevelInlineMetrics.self,
            from: Data(try XCTUnwrap(result as? String).utf8)
        )

        XCTAssertEqual(metrics.paragraphWidth, metrics.articleWidth, accuracy: 1)
        XCTAssertLessThan(metrics.buttonWidth, metrics.articleWidth / 3)
    }

    @MainActor
    func testWideMermaidDiagramFillsTheColumnInTheScreenLayout() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        // On screen the article is a flex column. The figure's contents are
        // all absolutely positioned, so a figure sized by its content alone
        // lays out at 0 x 0 and the diagram draws nowhere.
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        </head><body><article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        document.querySelector('.mermaid-figure').style.setProperty('--mm-aspect', '2 / 1');
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const article = document.querySelector('.markdown-body');
            const figure = document.querySelector('.mermaid-figure').getBoundingClientRect();
            return JSON.stringify({
                display: getComputedStyle(article).display,
                articleWidth: article.clientWidth,
                figureWidth: figure.width,
                figureHeight: figure.height,
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(WideMermaidMetrics.self, from: Data(json.utf8))

        XCTAssertEqual(metrics.display, "flex")
        XCTAssertGreaterThan(metrics.articleWidth, 0)
        XCTAssertEqual(metrics.figureWidth, metrics.articleWidth, accuracy: 1)
        XCTAssertEqual(metrics.figureHeight, metrics.articleWidth / 2, accuracy: 1)
    }

    @MainActor
    func testMermaidHUDWrapsInsideNarrowDiagram() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        </head><body><article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const figure = document.querySelector('.mermaid-figure');
        figure.style.width = '150px';
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const figure = document.querySelector('.mermaid-figure').getBoundingClientRect();
            const hud = document.querySelector('.mermaid-hud').getBoundingClientRect();
            const zoom = document.querySelector('.mermaid-hud-zoom').getBoundingClientRect();
            const actions = document.querySelector('.mermaid-hud-actions').getBoundingClientRect();
            return JSON.stringify({
                figureLeft: figure.left,
                figureRight: figure.right,
                hudLeft: hud.left,
                hudRight: hud.right,
                zoomTop: zoom.top,
                actionsTop: actions.top
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(
            MermaidHUDMetrics.self,
            from: Data(json.utf8)
        )

        XCTAssertGreaterThanOrEqual(metrics.hudLeft, metrics.figureLeft + 6)
        XCTAssertLessThanOrEqual(metrics.hudRight, metrics.figureRight - 6)
        XCTAssertGreaterThan(metrics.actionsTop, metrics.zoomTop)
    }

    func testCodeBlockLayoutMatchesDeferredHighlightingFromFirstPaint() throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```swift
            let answer = 42
            ```
            """,
            vendorLoading: .lazy
        )

        let codeRuleStart = try XCTUnwrap(rendered.html.range(of: "pre code {"))
        let codeRuleEnd = try XCTUnwrap(
            rendered.html.range(of: "}", range: codeRuleStart.upperBound..<rendered.html.endIndex)
        )
        let codeRule = rendered.html[codeRuleStart.lowerBound..<codeRuleEnd.upperBound]

        XCTAssertTrue(codeRule.contains("display: block;"))
    }

    func testShellFenceAliasesUseBashReadModeGrammar() {
        for language in ["shell", "sh", "zsh", "console", "bash"] {
            let rendered = MarkdownHTML.render(
                markdown: """
                ```\(language)
                git status --short
                ```
                """,
                vendorLoading: .lazy
            )

            XCTAssertTrue(
                rendered.articleHTML.contains("<code class=\"language-bash\" data-hljs-done=\"1\">"),
                "\(language): \(rendered.articleHTML)"
            )
        }
    }

    func testUntypedCodeBlockKeepsDetectedLanguageInRenderedHTML() {
        for (source, language) in [
            ("const answer = 42", "javascript"),
            ("int main(){\nreturn 0;\n}", "c"),
        ] {
            let rendered = MarkdownHTML.render(
                markdown: "```\n\(source)\n```",
                vendorLoading: .lazy
            )

            // Highlighted at render time, so the page needs no in-page runtime.
            XCTAssertFalse(rendered.containsCode)
            XCTAssertTrue(
                rendered.articleHTML.contains(
                    "<code class=\"language-\(language)\" data-md-detected-language=\"true\" data-hljs-done=\"1\">"
                ),
                rendered.articleHTML
            )
        }
    }

    @MainActor
    func testReadModeAutoHighlightsUntypedJavaScript() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```
            const answer = 42
            ```
            """,
            vendorLoading: .lazy
        )
        let highlightJS = try TestVendor.script(
            "md-preview/Vendor/Highlight/highlight.min.js"
        )
        let html = """
        <!DOCTYPE html>
        <html><body>
        \(rendered.articleHTML)
        <script>\(highlightJS)</script>
        <script>
        const MdPreviewPerf = { log() {}, now: () => performance.now() };
        window.requestAnimationFrame = (callback) => callback();
        \(MarkdownHTML.highlightAllBody)
        highlightAll();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))
        webView.loadHTMLString(html, baseURL: TestVendor.repositoryRoot)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            let done = try await webView.evaluateJavaScript(
                "document.querySelector('code').dataset.hljsDone === '1'"
            ) as? Bool
            if done == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        JSON.stringify({
            language: Array.from(document.querySelector('code').classList)
                .find((name) => name.startsWith('language-')),
            keyword: document.querySelector('.hljs-keyword')?.textContent,
            done: document.querySelector('code').dataset.hljsDone === '1',
        })
        """)
        let json = try XCTUnwrap(result as? String)
        let values = try JSONDecoder().decode(
            AutoDetectedHighlightValues.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(values.language, "language-javascript")
        XCTAssertEqual(values.keyword, "const")
        XCTAssertTrue(values.done)
    }

    @MainActor
    func testReadModeHighlightsHCLFenceAliases() async throws {
        let hcl = """
        terraform {
          required_providers {
            random = { source = "hashicorp/random", version = "~> 3.0" }
            local  = { source = "hashicorp/local",  version = "~> 2.0" }
          }
        }

        resource "random_pet" "name" {
          length = 2
        }
        """
        let markdown = ["hcl", "terraform", "tf"]
            .map { "```\($0)\n\(hcl)\n```" }
            .joined(separator: "\n\n")
        let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy)
        let highlightJS = try TestVendor.script(
            "md-preview/Vendor/Highlight/highlight.min.js"
        )
        let html = """
        <!DOCTYPE html>
        <html><body>
        \(rendered.articleHTML)
        <script>\(highlightJS)</script>
        <script>
        const MdPreviewPerf = { log() {}, now: () => performance.now() };
        window.requestAnimationFrame = (callback) => callback();
        \(MarkdownHTML.highlightAllBody)
        highlightAll();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))

        webView.loadHTMLString(html, baseURL: TestVendor.repositoryRoot)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            let done = try await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('pre code[class*=\"language-\"]')).every((code) => code.dataset.hljsDone === '1')"
            ) as? Bool
            if done == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        JSON.stringify(Array.from(document.querySelectorAll('pre code[class*="language-"]')).map((block) => ({
            language: Array.from(block.classList).find((name) => name.startsWith('language-')),
            keywords: Array.from(block.querySelectorAll('.hljs-keyword')).map((node) => node.textContent),
            strings: Array.from(block.querySelectorAll('.hljs-string')).map((node) => node.textContent),
            numbers: Array.from(block.querySelectorAll('.hljs-number')).map((node) => node.textContent),
            done: block.dataset.hljsDone === '1',
        })))
        """)
        let json = try XCTUnwrap(result as? String)
        let values = try JSONDecoder().decode([HCLHighlightValues].self, from: Data(json.utf8))

        XCTAssertEqual(values.map(\.language), ["language-hcl", "language-terraform", "language-tf"])
        for value in values {
            XCTAssertTrue(value.done)
            let keywords = value.keywords.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            XCTAssertTrue(keywords.contains("terraform"), "\(value)")
            XCTAssertTrue(keywords.contains("resource"), "\(value)")
            XCTAssertTrue(value.strings.contains(where: {
                $0.contains("hashicorp/random")
            }), "\(value)")
            XCTAssertTrue(value.numbers.contains("2"), "\(value)")
        }
    }

    @MainActor
    func testReadModeHighlightsShellOptionsWithoutTouchingComments() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let highlightURL = repositoryRoot
            .appendingPathComponent("md-preview/Vendor/Highlight/highlight.min.js")
        let highlightJS = try String(contentsOf: highlightURL, encoding: .utf8)
            .replacingOccurrences(of: "</script", with: "<\\/script")
        let html = """
        <!DOCTYPE html>
        <html><body>
        <pre><code class="language-bash">#!/bin/bash -e
        git status --short
        git log --pretty=format:%h
        xcodebuild --derivedDataPath=/tmp/build
        npx serve-sim --list -q -a -b
        # --ignored</code></pre>
        <script>\(highlightJS)</script>
        <script>
        const MdPreviewPerf = { log() {}, now: () => performance.now() };
        window.requestAnimationFrame = (callback) => callback();
        \(MarkdownHTML.highlightAllBody)
        highlightAll();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))

        webView.loadHTMLString(html, baseURL: repositoryRoot)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            let done = try await webView.evaluateJavaScript(
                "document.querySelector('code').dataset.hljsDone === '1'"
            ) as? Bool
            if done == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        JSON.stringify({
            options: Array.from(document.querySelectorAll('code > .hljs-attr')).map((node) => node.textContent),
            commentOptions: Array.from(document.querySelectorAll('.hljs-comment .hljs-attr')).map((node) => node.textContent),
            metaOptions: Array.from(document.querySelectorAll('.hljs-meta .hljs-attr')).map((node) => node.textContent),
            html: document.querySelector('code').innerHTML,
        })
        """)
        let json = try XCTUnwrap(result as? String)
        let values = try JSONDecoder().decode(ShellHighlightValues.self, from: Data(json.utf8))

        XCTAssertEqual(
            values.options,
            ["--short", "--pretty", "--derivedDataPath", "--list", "-q", "-a", "-b"],
            values.html
        )
        XCTAssertTrue(values.commentOptions.isEmpty)
        XCTAssertTrue(values.metaOptions.isEmpty)
    }

    func testBlockMathKeepsValidWrapperAndSourceLine() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```math
            E = mc^2
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<div data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"3\" class=\"math math-display\">"
        ), rendered.articleHTML)
        XCTAssertFalse(rendered.articleHTML.contains("<p data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"3\"><div"))
    }

    func testQuotedDisplayMathDropsQuoteMarkers() {
        let rendered = MarkdownHTML.render(
            markdown: """
            > $$
            > x = \\sqrt{y}
            > $$
            >
            > After
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "class=\"math math-display\">\nx = \\sqrt{y}\n</div>"
        ), rendered.articleHTML)
        XCTAssertEqual(rendered.articleHTML.components(separatedBy: "<blockquote").count, 2, rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains("After</p>"), rendered.articleHTML)

        let comparison = MarkdownHTML.render(markdown: "> $$\n> a\n> > b\n> $$", vendorLoading: .lazy)
        XCTAssertTrue(comparison.articleHTML.contains("\na\n&gt; b\n</div>"), comparison.articleHTML)
    }

    func testEscapedDollarDoesNotCloseInlineMath() {
        let rendered = MarkdownHTML.render(
            markdown: #"Prices: $5 and $10. Escaped dollar: \$x$."#,
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.articleHTML.contains("math-inline"), rendered.articleHTML)
    }

    func testLatexDelimitersRenderAsMath() {
        let rendered = MarkdownHTML.render(
            markdown: #"""
            Inline \( E=mc^2 \) expression.

            \[
            \begin{equation}
            E=mc^2
            \end{equation}
            \]
            """#,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"<span class="math math-inline"> E=mc^2 </span>"#
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"data-source-line="3" data-source-start="3" data-source-end="7" class="math math-display""#
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"""
            \begin{equation}
            E=mc^2
            \end{equation}
            """#
        ), rendered.articleHTML)
    }

    func testMarkdownEscapedLatexDelimitersRenderAsMath() {
        let rendered = MarkdownHTML.render(
            markdown: #"""
            Inline \\(\frac{\pi}{2}\\) expression.

            \\[\int_0^1 f(t) \mathrm{d}t\\]

            \\[\sum_j \gamma_j^2/d_j\\]
            """#,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"<span class="math math-inline">\frac{\pi}{2}</span>"#
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"class="math math-display">\int_0^1 f(t) \mathrm{d}t</div>"#
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"class="math math-display">\sum_j \gamma_j^2/d_j</div>"#
        ), rendered.articleHTML)
        XCTAssertEqual(
            rendered.articleHTML.components(separatedBy: "class=\"math ").count - 1,
            3
        )
    }

    func testEscapedBracketsInLinkTextRemainLinkText() {
        let rendered = MarkdownHTML.render(
            markdown: #"""
            Citation [\[4\]][source].
            Related [see \[5\] for context](https://example.com/related).

            [source]: https://example.com
            """#,
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"Citation <a href="https://example.com">[4]</a>."#
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"Related <a href="https://example.com/related">see [5] for context</a>."#
        ), rendered.articleHTML)
        XCTAssertFalse(rendered.articleHTML.contains("class=\"math"))
    }

    func testEscapedLinkBracketsDoNotHideAdjacentDisplayMath() {
        let rendered = MarkdownHTML.render(
            markdown: #"""
            Résumé ✨ [\[4\]][source].

            \[
            x^2
            \]

            [source]: https://example.com
            """#,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"Résumé ✨ <a href="https://example.com">[4]</a>."#
        ), rendered.articleHTML)
        XCTAssertEqual(
            rendered.articleHTML.components(separatedBy: "class=\"math math-display\"").count - 1,
            1
        )
        XCTAssertTrue(rendered.articleHTML.contains("class=\"math math-display\">\nx^2\n</div>"))
    }

    func testEscapedBracketsInSeparateLinksCannotPairAsDisplayMath() {
        let rendered = MarkdownHTML.render(
            markdown: #"[open \[](https://a.example) prose [close \]](https://b.example)"#,
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains(
            #"<a href="https://a.example">open [</a> prose <a href="https://b.example">close ]</a>"#
        ), rendered.articleHTML)
        XCTAssertFalse(rendered.articleHTML.contains("class=\"math"))
    }

    func testLatexDelimitersInsideCodeRemainLiteral() {
        let rendered = MarkdownHTML.render(
            markdown: #"""
            `\(inline\)`
            `\\(markdown escaped inline\\)`

            ```latex
            \[
            \frac{a}{b}
            \]

            \\[\sum_i x_i\\]
            ```
            """#,
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains(#"<code>\(inline\)</code>"#))
        XCTAssertTrue(rendered.articleHTML.contains(#"<code>\\(markdown escaped inline\\)</code>"#))
        XCTAssertTrue(rendered.articleHTML.contains(#"\["#))
        XCTAssertTrue(rendered.articleHTML.contains(#"\\[\sum_i x_i\\]"#))
        XCTAssertFalse(rendered.articleHTML.contains("class=\"math"))
    }

    func testProtectedCodeTokensRestoreInOnePassWithoutChangingContent() {
        let codeSpans = (0..<100)
            .map { "`literal-\($0)-$not-math$`" }
            .joined(separator: " ")
        let rendered = MarkdownHTML.render(
            markdown: "MdPreviewProtectNotAToken \(codeSpans)",
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.containsMath)
        XCTAssertTrue(rendered.articleHTML.contains("MdPreviewProtectNotAToken"))
        XCTAssertTrue(rendered.articleHTML.contains("<code>literal-0-$not-math$</code>"))
        XCTAssertTrue(rendered.articleHTML.contains("<code>literal-50-$not-math$</code>"))
        XCTAssertTrue(rendered.articleHTML.contains("<code>literal-99-$not-math$</code>"))
        XCTAssertFalse(rendered.articleHTML.contains("MdPreviewProtect0Token"))
        XCTAssertFalse(rendered.articleHTML.contains("MdPreviewFootnoteProtect0Token"))
    }

    @MainActor
    func testReportedLatexStructuresRenderWithBundledKatex() async throws {
        let rendered = MarkdownHTML.render(
            markdown: #"""
            \[
            \begin{equation}
            E=mc^2
            \end{equation}
            \]

            $$
            \begin{aligned}
            a &= b+c\\
            d &= e+f
            \end{aligned}
            $$

            $$\frac{a}{b}$$
            $$\int_0^\infty e^{-x}dx$$
            $$\sum_{i=1}^{N}x_i$$
            $$A=\begin{bmatrix}1&0\\0&1\end{bmatrix}$$
            """#,
            vendorLoading: .lazy
        )
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let katexURL = repositoryRoot
            .appendingPathComponent("md-preview/Vendor/KaTeX/katex.min.js")
        let katexJS = try String(contentsOf: katexURL, encoding: .utf8)
            .replacingOccurrences(of: "</script", with: "<\\/script")
        let html = """
        <!DOCTYPE html>
        <html><body><article>\(rendered.articleHTML)</article>
        <script>\(katexJS)</script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: repositoryRoot)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await webView.evaluateJavaScript("""
        document.querySelectorAll('.math').forEach((element) => {
            katex.render(element.textContent, element, {
                displayMode: element.classList.contains('math-display'),
                throwOnError: false,
                output: 'htmlAndMathml'
            });
        });
        """)

        let mathCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.math').length"
        ) as? Int
        let renderedCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.math .katex').length"
        ) as? Int
        let errorCount = try await webView.evaluateJavaScript(
            "document.querySelectorAll('.katex-error').length"
        ) as? Int

        XCTAssertEqual(mathCount, 6)
        XCTAssertEqual(renderedCount, 6)
        XCTAssertEqual(errorCount, 0)
    }

    func testFootnoteRemovalDoesNotShiftFollowingSourceLines() {
        let rendered = MarkdownHTML.render(
            markdown: """
            Prelude.

            Reference.[^note]

            [^note]: First definition line.
                Second definition line.
                Third definition line.

            ## Target
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<h2 data-source-line=\"9\" data-source-start=\"9\" data-source-end=\"9\" id=\"md-heading-0\">Target</h2>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"7\">First definition line."
        ))
    }

    func testFootnoteSourceLinesIncludeFrontmatterOffset() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            title: Footnotes
            ---
            Prelude.

            Reference.[^note]

            [^note]: First definition line.
                Second definition line.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"8\" data-source-start=\"8\" data-source-end=\"9\">First definition line."
        ))
    }

    func testMultipleFootnoteReferencesRestoreInSourceOrder() {
        let rendered = MarkdownHTML.render(
            markdown: """
            First[^one], repeated[^one], and second[^two]. Literal `[^one]`.

            [^one]: First note.
            [^two]: Second note.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains("id=\"fnref-1\" href=\"#fn-1\""))
        XCTAssertTrue(rendered.articleHTML.contains("id=\"fnref-1-2\" href=\"#fn-1\""))
        XCTAssertTrue(rendered.articleHTML.contains("id=\"fnref-2\" href=\"#fn-2\""))
        XCTAssertTrue(rendered.articleHTML.contains("<code>[^one]</code>"))
        XCTAssertFalse(rendered.articleHTML.contains("MdPreviewFootnoteRef"))
        XCTAssertFalse(rendered.articleHTML.contains("MdPreviewFootnoteProtect"))
    }

    func testTablesExposeSourceRangeAndStableCellCoordinates() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            title: Editable table
            ---

            | Name | Score |
            | --- | ---: |
            | Ada | 10 |
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<table data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"7\">"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "<th data-table-row=\"0\" data-table-column=\"0\" data-table-markdown=\"Name\">Name</th>"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "<td data-table-row=\"1\" data-table-column=\"1\" data-table-markdown=\"10\" align=\"right\">10</td>"
        ), rendered.articleHTML)
        XCTAssertFalse(rendered.html.contains("kind: 'tableEdit'"))
        XCTAssertFalse(rendered.html.contains("kind: 'tableContextMenu'"))
    }

    func testRenderedTableCellsRetainOriginalMarkdownForSourceAwareEditing() throws {
        let markdown = """
        | Plain | Link | Emphasis | Code | Image |
        | --- | --- | --- | --- | --- |
        | Text | [Docs](https://example.com) | **Bold** | `a|b` | ![Alt](image.png) |
        """
        let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy)

        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"0\" data-table-markdown=\"Text\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"1\" data-table-markdown=\"[Docs](https://example.com)\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"2\" data-table-markdown=\"**Bold**\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"3\" data-table-markdown=\"`a|b`\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"4\" data-table-markdown=\"![Alt](image.png)\""
        ), rendered.articleHTML)

        let updated = try XCTUnwrap(MarkdownTableSource.applying(
            .setCell(row: 1, column: 1, markdown: "[Docs](https://example.com)!"),
            fromLine: 1,
            throughLine: 3,
            in: markdown
        ))
        XCTAssertTrue(updated.contains("[Docs](https://example.com)!"), updated)
        XCTAssertTrue(updated.contains("**Bold**"), updated)
        XCTAssertTrue(updated.contains("`a|b`"), updated)
        XCTAssertTrue(updated.contains("![Alt](image.png)"), updated)
    }

    func testTableCellEditTargetsExactSourceRangeAndEscapesPipes() throws {
        let markdown = """
        Before

        | Name | Value |
        | :--- | ---: |
        | Existing | `a|b` |

        After
        """
        let updated = try XCTUnwrap(MarkdownTableSource.applying(
            .setCell(row: 1, column: 0, markdown: "A | B"),
            fromLine: 3,
            throughLine: 5,
            in: markdown
        ))

        XCTAssertTrue(updated.contains("| A \\| B"), updated)
        XCTAssertTrue(updated.contains("`a|b`"), updated)
        XCTAssertTrue(updated.hasPrefix("Before\n\n"))
        XCTAssertTrue(updated.hasSuffix("\n\nAfter"))
    }

    func testTableRowsAndColumnsCanBeInsertedAndDeleted() throws {
        let markdown = """
        | Name | Value |
        | --- | --- |
        | One | 1 |
        """
        let withRow = try XCTUnwrap(MarkdownTableSource.applying(
            .insertRowAfter(1), fromLine: 1, throughLine: 3, in: markdown
        ))
        XCTAssertEqual(withRow.components(separatedBy: "\n").count, 4)

        let rowBefore = try XCTUnwrap(MarkdownTableSource.applying(
            .insertRowBefore(1), fromLine: 1, throughLine: 3, in: markdown
        ))
        XCTAssertEqual(rowBefore.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(rowBefore.components(separatedBy: "\n")[2]
            .components(separatedBy: "|")
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespaces)
            .isEmpty == true)

        let withColumn = try XCTUnwrap(MarkdownTableSource.applying(
            .insertColumnAfter(0), fromLine: 1, throughLine: 4, in: withRow
        ))
        XCTAssertTrue(withColumn.components(separatedBy: "\n").allSatisfy {
            $0.filter { $0 == "|" }.count == 4
        }, withColumn)

        let columnBefore = try XCTUnwrap(MarkdownTableSource.applying(
            .insertColumnBefore(0), fromLine: 1, throughLine: 3, in: markdown
        ))
        let headerCells = columnBefore.components(separatedBy: "\n")[0]
            .components(separatedBy: "|")
            .dropFirst()
        XCTAssertTrue(headerCells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true)
        XCTAssertEqual(headerCells.dropFirst().first?.trimmingCharacters(in: .whitespaces), "Name")

        let withoutRow = try XCTUnwrap(MarkdownTableSource.applying(
            .deleteRow(2), fromLine: 1, throughLine: 4, in: withColumn
        ))
        let withoutColumn = try XCTUnwrap(MarkdownTableSource.applying(
            .deleteColumn(1), fromLine: 1, throughLine: 3, in: withoutRow
        ))
        XCTAssertEqual(withoutColumn.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(withoutColumn.contains("| Name"))
        XCTAssertTrue(withoutColumn.contains("| One"))
    }
}

private struct HeadingLayoutMetrics: Decodable {
    let headingClientWidth: CGFloat
    let headingScrollWidth: CGFloat
    let codeRight: CGFloat
    let viewportRight: CGFloat
    let boxDecorationBreak: String
    let fragmentEndDecoration: Double
}

private struct LongDocumentScrollMetrics: Decodable {
    let viewportHeight: CGFloat
    let documentHeight: CGFloat
    let scrollPosition: CGFloat
    let articleHeight: CGFloat
    let rowCount: Int
    let overflowY: String
    let bodyOverflowY: String
    let rootScrollbarDisplay: String
    let rootScrollbarWidth: String
    let tableScrollbarDisplay: String
}

private struct ShellHighlightValues: Decodable {
    let options: [String]
    let commentOptions: [String]
    let metaOptions: [String]
    let html: String
}

private struct HCLHighlightValues: Decodable, CustomStringConvertible {
    let language: String
    let keywords: [String]
    let strings: [String]
    let numbers: [String]
    let done: Bool

    var description: String {
        "\(language): keywords=\(keywords), strings=\(strings), numbers=\(numbers), done=\(done)"
    }
}

private struct AutoDetectedHighlightValues: Decodable {
    let language: String?
    let keyword: String?
    let done: Bool
}

private struct TopLevelInlineMetrics: Decodable {
    let articleWidth: CGFloat
    let paragraphWidth: CGFloat
    let buttonWidth: CGFloat
}

private struct WideMermaidMetrics: Decodable {
    let display: String
    let articleWidth: CGFloat
    let figureWidth: CGFloat
    let figureHeight: CGFloat
}

private struct MermaidHUDMetrics: Decodable {
    let figureLeft: CGFloat
    let figureRight: CGFloat
    let hudLeft: CGFloat
    let hudRight: CGFloat
    let zoomTop: CGFloat
    let actionsTop: CGFloat
}

private struct MermaidPopupMessage: Decodable {
    let kind: String
    let svg: String
    let sectionTitle: String
}
