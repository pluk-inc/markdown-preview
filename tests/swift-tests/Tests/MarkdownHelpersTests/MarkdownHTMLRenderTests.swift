import XCTest
import WebKit
@testable import MarkdownHelpers

final class MarkdownHTMLRenderTests: XCTestCase {
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
        XCTAssertTrue(rendered.html.contains(":where(:not(html):not(body))::-webkit-scrollbar"))
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
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1700, height: 600))
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
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(HeadingLayoutMetrics.self, from: Data(json.utf8))

        XCTAssertLessThanOrEqual(metrics.headingScrollWidth, metrics.headingClientWidth)
        XCTAssertLessThanOrEqual(metrics.codeRight, metrics.viewportRight)
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
        XCTAssertEqual(nonSelectableRules.count, 1)
        XCTAssertTrue(nonSelectableRules[0].contains(".md-code-copy"))
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
        XCTAssertTrue(rendered.html.contains("height: 22.8px;"))
        XCTAssertFalse(rendered.html.contains(".md-source-blank-line + *"))
        XCTAssertTrue(rendered.html.contains(".md-source-blank-line + h3,"))
        XCTAssertTrue(rendered.html.contains("margin-top: 22.8px;"))
    }

    func testListsAndDecoratedCodeBlocksOwnTheirOuterSpacing() {
        let rendered = MarkdownHTML.render(
            markdown: "## Heading\n\n- First\n- Second\n\n```sh\necho hello\n```",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.html.contains("li:first-child { margin-top: 0; }"))
        XCTAssertTrue(rendered.html.contains("ul { list-style-type: \"•  \"; }"))
        XCTAssertTrue(rendered.html.contains(".md-code-wrap > pre { margin: 0; }"))
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
            "padding-inline-start: 1.6em;"
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
            rendered.articleHTML.contains(#"class="mermaid-hud-width-symbol" aria-hidden="true">⤢</span>"#),
            rendered.articleHTML
        )
        // SPM helper tests lack the Mermaid vendor bundle, so the page falls
        // back to the "renderer unavailable" stub — assert the real wiring
        // string (injected by the app when Vendor/Mermaid is present).
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("kind: 'mermaidPopup'"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("naturalWidth"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("function openPopup"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("case 'popup'"))
        XCTAssertTrue(MarkdownHTML.mermaidInitWiring.contains("openPopup(figure)"))
    }

    @MainActor
    func testMermaidPopupPostsMeasuredSizeMessage() async throws {
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
        // openPopup path posts a measured mermaidPopup message.
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
        window.mermaid = {
            initialize() {},
            async run({ nodes }) {
                for (const node of nodes) {
                    node.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 200">'
                        + '<rect width="400" height="200" fill="#4a90d9"/></svg>';
                }
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

        // Wait for IntersectionObserver → mock mermaid.run → attachZoom.
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
        XCTAssertEqual(hudPayload.naturalWidth, 400, accuracy: 0.5)
        XCTAssertEqual(hudPayload.naturalHeight, 200, accuracy: 0.5)
        XCTAssertGreaterThan(hudPayload.displayWidth, 1)
        XCTAssertGreaterThan(hudPayload.displayHeight, 1)
        XCTAssertTrue(hudPayload.svg.contains("<svg"), hudPayload.svg)
        XCTAssertTrue(hudPayload.svg.contains("viewBox"), hudPayload.svg)
        // Nearest preceding heading, not the document title.
        XCTAssertEqual(hudPayload.sectionTitle, "1. System overview")
        // Clone should not carry pan/zoom transform styles from the surface.
        XCTAssertFalse(hudPayload.svg.contains("transform:"), hudPayload.svg)

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

    @MainActor
    func testMermaidNativeColorSchemeOverridesMatchMedia() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            journey
                title My working day
                section Go to work
                  Make tea: 5: Me
            ```
            """,
            vendorLoading: .lazy,
            colorScheme: .dark
        )

        let html = """
        <!DOCTYPE html>
        <html data-mdp-color-scheme="dark"><head>
        <script>
        window.__themes = [];
        window.__runs = 0;
        Object.defineProperty(window, 'matchMedia', {
            value: () => ({ matches: false }),
            configurable: true
        });
        window.IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
            unobserve() {}
        };
        window.ResizeObserver = class {
            constructor() {}
            observe() {}
        };
        window.mermaid = {
            initialize(options) { window.__themes.push(options.theme); },
            async run({ nodes }) {
                window.__runs += 1;
                const theme = window.__themes[window.__themes.length - 1];
                for (const node of nodes) {
                    node.innerHTML = '<svg viewBox="0 0 400 200" data-theme="' + theme + '"></svg>';
                }
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

        var darkRenderReady = false
        for _ in 0..<100 {
            let state = try await webView.evaluateJavaScript("""
            JSON.stringify({
                themes: window.__themes,
                runs: window.__runs,
                renderedTheme: document.querySelector('.mermaid svg')?.dataset.theme || ''
            })
            """) as? String
            if state == #"{"themes":["dark"],"runs":1,"renderedTheme":"dark"}"# {
                darkRenderReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(darkRenderReady, "native dark appearance must win when matchMedia reports light")
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
        window.mermaid = {
            initialize() {},
            async run({ nodes }) {
                window.__runs += 1;
                for (const node of nodes) {
                    node.innerHTML = '<svg viewBox="0 0 400 200"></svg>';
                }
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
    func testMermaidRenderAllRethemesForPaperPrintAndRestores() async throws {
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
        <script>
        window.__themes = [];
        window.IntersectionObserver = class {
            constructor(callback) { this.callback = callback; }
            observe(target) { this.callback([{ target, isIntersecting: true }]); }
            unobserve() {}
        };
        window.ResizeObserver = class {
            observe() {}
        };
        window.mermaid = {
            initialize(options) { window.__themes.push(options.theme); },
            async run({ nodes }) {
                const theme = window.__themes[window.__themes.length - 1];
                for (const node of nodes) {
                    node.innerHTML = '<svg viewBox="0 0 400 200" data-theme="' + theme + '"></svg>';
                }
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

        func diagramState() async throws -> String? {
            try await webView.evaluateJavaScript("""
            JSON.stringify({
                themes: window.__themes,
                mmTheme: document.querySelector('.mermaid')?.dataset.mmTheme || '',
                svgTheme: document.querySelector('.mermaid svg')?.dataset.theme || ''
            })
            """) as? String
        }

        func waitFor(_ expected: String) async throws -> Bool {
            for _ in 0..<100 {
                if try await diagramState() == expected { return true }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }

        let renderedDark = try await waitFor(
            #"{"themes":["dark"],"mmTheme":"dark","svgTheme":"dark"}"#
        )
        XCTAssertTrue(renderedDark, "initial render must use the native dark theme")

        // Paper print: pin the light theme and re-render the finished figure.
        _ = try await webView.evaluateJavaScript("""
        window.__paperDone = false;
        window.MdPreview.mermaidRenderAll('default').then(() => {
            window.__paperDone = true;
        });
        true
        """)
        let rethemed = try await waitFor(
            #"{"themes":["dark","default"],"mmTheme":"default","svgTheme":"default"}"#
        )
        XCTAssertTrue(rethemed, "a pinned theme must re-render already-finished figures")

        // Panel dismissed: restore the on-screen theme.
        _ = try await webView.evaluateJavaScript(
            "window.MdPreview.mermaidRenderAll(); true"
        )
        let restored = try await waitFor(
            #"{"themes":["dark","default","dark"],"mmTheme":"dark","svgTheme":"dark"}"#
        )
        XCTAssertTrue(restored, "a bare renderAll must restore the on-screen theme")
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
                    sectionTitle: String(msg.sectionTitle || ''),
                    naturalWidth: Number(msg.naturalWidth) || 0,
                    naturalHeight: Number(msg.naturalHeight) || 0,
                    displayWidth: Number(msg.displayWidth) || 0,
                    displayHeight: Number(msg.displayHeight) || 0
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

    @MainActor
    func testMermaidWidthToggleExpandsAndRestoresDiagram() async throws {
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
            #"data-mm-act="width" tabindex="-1" aria-label="Fill width" aria-pressed="false""#
        ))

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
        figure.style.setProperty('--mm-aspect', '1 / 4');
        figure.querySelector('.mermaid').innerHTML = '<svg viewBox="0 0 200 800"></svg>';
        document.querySelector('.mermaid-hud').addEventListener('click', (event) => {
            const button = event.target.closest('[data-mm-act="width"]');
            if (!button) return;
            const figure = button.closest('.mermaid-figure');
            const expanded = figure.classList.toggle('mermaid-width-expanded');
            button.setAttribute('aria-pressed', String(expanded));
        });
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let metricsScript = """
        (() => {
            const host = document.querySelector('.mermaid');
            const figure = document.querySelector('.mermaid-figure');
            const article = document.querySelector('.markdown-body');
            const svg = host.querySelector('svg');
            const button = figure.querySelector('[data-mm-act="width"]');
            const style = getComputedStyle(host);
            return JSON.stringify({
                articleWidth: article.clientWidth,
                articleLeft: article.getBoundingClientRect().left,
                figureWidth: figure.getBoundingClientRect().width,
                figureLeft: figure.getBoundingClientRect().left,
                availableWidth: host.clientWidth
                    - parseFloat(style.paddingLeft)
                    - parseFloat(style.paddingRight),
                svgWidth: svg.getBoundingClientRect().width,
                expanded: figure.classList.contains('mermaid-width-expanded'),
                buttonPressed: button?.getAttribute('aria-pressed') || '',
            });
        })()
        """
        let initialResult = try await webView.evaluateJavaScript(metricsScript)
        let initialJSON = try XCTUnwrap(initialResult as? String)
        let initial = try JSONDecoder().decode(MermaidLayoutMetrics.self, from: Data(initialJSON.utf8))

        XCTAssertFalse(initial.expanded)
        XCTAssertEqual(initial.buttonPressed, "false")
        XCTAssertLessThan(initial.figureWidth, initial.articleWidth)
        XCTAssertEqual(
            initial.figureLeft - initial.articleLeft,
            (initial.articleWidth - initial.figureWidth) / 2,
            accuracy: 1
        )

        try await webView.evaluateJavaScript(
            "document.querySelector('[data-mm-act=\"width\"]').click()"
        )
        let expandedResult = try await webView.evaluateJavaScript(metricsScript)
        let expandedJSON = try XCTUnwrap(expandedResult as? String)
        let expanded = try JSONDecoder().decode(MermaidLayoutMetrics.self, from: Data(expandedJSON.utf8))

        XCTAssertTrue(expanded.expanded)
        XCTAssertEqual(expanded.buttonPressed, "true")
        XCTAssertEqual(expanded.figureWidth, expanded.articleWidth, accuracy: 1)
        XCTAssertEqual(expanded.svgWidth, expanded.availableWidth, accuracy: 1)

        try await webView.evaluateJavaScript(
            "document.querySelector('[data-mm-act=\"width\"]').click()"
        )
        let restoredResult = try await webView.evaluateJavaScript(metricsScript)
        let restoredJSON = try XCTUnwrap(restoredResult as? String)
        let restored = try JSONDecoder().decode(MermaidLayoutMetrics.self, from: Data(restoredJSON.utf8))

        XCTAssertFalse(restored.expanded)
        XCTAssertEqual(restored.buttonPressed, "false")
        XCTAssertEqual(restored.figureWidth, initial.figureWidth, accuracy: 1)
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
        figure.style.width = '200px';
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

        XCTAssertGreaterThanOrEqual(metrics.hudLeft, metrics.figureLeft + 7)
        XCTAssertLessThanOrEqual(metrics.hudRight, metrics.figureRight - 7)
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
                rendered.articleHTML.contains("<code class=\"language-bash\">"),
                "\(language): \(rendered.articleHTML)"
            )
        }
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
        XCTAssertTrue(rendered.html.contains("function enableTableEditing(root = document)"))
        XCTAssertFalse(rendered.html.contains("md-table-edge-action"))
        XCTAssertTrue(rendered.html.contains("kind: 'tableContextMenu'"))
        XCTAssertTrue(rendered.html.contains("cell.dataset.placeholder = placeholder"))
        XCTAssertTrue(rendered.html.contains("function selectTablePart(cell, operation)"))
        XCTAssertTrue(rendered.html.contains("event.key === 'Backspace' || event.key === 'Delete'"))
        XCTAssertTrue(rendered.html.contains("selectTableRange(tableCellDrag.cell, cell)"))
        XCTAssertTrue(rendered.html.contains("window.getSelection()?.removeAllRanges()"))
        XCTAssertTrue(rendered.html.contains(".md-table-editor .is-table-selection-left"))
        XCTAssertTrue(rendered.html.contains("cell.hasAttribute('data-table-markdown')"))
        XCTAssertTrue(rendered.html.contains("cell.dataset.tableOriginal = cell.dataset.tableMarkdown || ''"))
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

private struct MermaidLayoutMetrics: Decodable {
    let articleWidth: CGFloat
    let articleLeft: CGFloat
    let figureWidth: CGFloat
    let figureLeft: CGFloat
    let availableWidth: CGFloat
    let svgWidth: CGFloat
    let expanded: Bool
    let buttonPressed: String
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
    let naturalWidth: CGFloat
    let naturalHeight: CGFloat
    let displayWidth: CGFloat
    let displayHeight: CGFloat
}
